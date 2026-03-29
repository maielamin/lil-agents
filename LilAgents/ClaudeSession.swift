import Foundation

class ClaudeSession: AgentSession {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var currentResponseText = ""
    private var pendingMessages: [String] = []
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?
    private var launchedWithMCP = false
    private var sessionGeneration = 0

    private static let gmailHint = """
        [System note: you are running on macOS and have bash tool access. \
        To compose a Gmail email, use the Bash tool to run: \
        open "https://mail.google.com/mail/?view=cm&to=EMAIL&su=SUBJECT&body=BODY" \
        URL-encode spaces as %20 and newlines as %0A. This opens a pre-filled Gmail compose window in the browser.]
        """
    private static let saverPolicy = """
        [Response policy: keep responses concise to save credits. Use short bullets, avoid repetition and long preambles, and include only necessary details. Expand only if the user explicitly asks for more detail.]
        """

    private static let emailKeywords = ["email", "gmail", "send mail", "send an email", "write an email"]
    private static let mcpConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lil-agents-mcp.json").path
    private var mcpConfigExists: Bool { FileManager.default.fileExists(atPath: Self.mcpConfigPath) }

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Process Lifecycle

    func start() {
        if let cached = Self.binaryPath {
            launchProcess(binaryPath: cached)
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "claude", fallbackPaths: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]) { [weak self] path in
            guard let self = self, let binaryPath = path else {
                let msg = "Claude CLI not found.\n\n\(AgentProvider.claude.installInstructions)"
                self?.onError?(msg)
                self?.history.appendBounded(AgentMessage(role: .error, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            self.launchProcess(binaryPath: binaryPath)
        }
    }

    private func launchProcess(binaryPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose"
        ]
        if AgentProvider.claudePowerModeEnabled {
            args.append("--dangerously-skip-permissions")
        }
        if launchedWithMCP {
            args += ["--mcp-config", Self.mcpConfigPath]
        }
        proc.arguments = args
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let generation = sessionGeneration
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.sessionGeneration == generation else { return }
                self.isRunning = false
                self.isBusy = false
                self.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.onError?(text)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            inputPipe = inPipe
            outputPipe = outPipe
            errorPipe = errPipe
            isRunning = true
            let pending = pendingMessages
            pendingMessages = []
            for msg in pending {
                send(message: msg)
            }
        } catch {
            let msg = "Failed to launch Claude CLI.\n\n\(AgentProvider.claude.installInstructions)\n\nError: \(error.localizedDescription)"
            onError?(msg)
            history.appendBounded(AgentMessage(role: .error, text: msg))
        }
    }

    func send(message: String) {
        guard isRunning, let pipe = inputPipe else {
            pendingMessages.append(message)
            return
        }

        var outgoing = message
        let lower = outgoing.lowercased()
        let isEmailRequest = Self.emailKeywords.contains(where: { lower.contains($0) })
        if isEmailRequest {
            outgoing = "\(Self.gmailHint)\n\n\(outgoing)"
        }
        if AgentProvider.claudeSaverModeEnabled {
            outgoing = "\(Self.saverPolicy)\n\nUser request:\n\(outgoing)"
        }
        writeMessage(outgoing, displayMessage: message, to: pipe)
    }

    private func writeMessage(_ message: String, displayMessage: String? = nil, to pipe: Pipe) {
        isBusy = true
        currentResponseText = ""
        history.appendBounded(AgentMessage(role: .user, text: displayMessage ?? message))

        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let line = jsonStr + "\n"
        pipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    func terminate() {
        process?.terminate()
        isRunning = false
        pendingMessages.removeAll()
    }

    // MARK: - NDJSON Parsing

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "system":
            let subtype = json["subtype"] as? String ?? ""
            if subtype == "init" {
                onSessionReady?()
            }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String {
                        currentResponseText += text
                        onText?(text)
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let summary = formatToolSummary(toolName: toolName, input: input)
                        history.appendBounded(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
                        onToolUse?(toolName, input)
                    }
                }
            }

        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_result" {
                        let isError = block["is_error"] as? Bool ?? false
                        var summary = ""
                        if let resultInfo = json["tool_use_result"] as? [String: Any] {
                            if let text = resultInfo["type"] as? String, text == "text" {
                                if let file = resultInfo["file"] as? [String: Any],
                                   let path = file["filePath"] as? String {
                                    let lines = file["totalLines"] as? Int ?? 0
                                    summary = "\(path) (\(lines) lines)"
                                }
                            }
                        } else if let resultStr = json["tool_use_result"] as? String {
                            summary = String(resultStr.prefix(80))
                        }
                        if summary.isEmpty {
                            if let contentStr = block["content"] as? String {
                                summary = String(contentStr.prefix(80))
                            }
                        }
                        history.appendBounded(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                        onToolResult?(summary, isError)
                    }
                }
            }

        case "result":
            isBusy = false
            let finalText: String
            if let result = json["result"] as? String, !result.isEmpty {
                finalText = result
            } else if !currentResponseText.isEmpty {
                finalText = currentResponseText
            } else {
                finalText = ""
            }
            if !finalText.isEmpty {
                history.appendBounded(AgentMessage(role: .assistant, text: finalText))
            }
            currentResponseText = ""
            onTurnComplete?()

        default:
            break
        }
    }

    private func formatToolSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Read":
            return input["file_path"] as? String ?? ""
        case "Edit", "Write":
            return input["file_path"] as? String ?? ""
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        default:
            if let desc = input["description"] as? String { return desc }
            return input.keys.sorted().prefix(3).joined(separator: ", ")
        }
    }
}
