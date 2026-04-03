import Foundation

class GeminiSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var currentResponseText = ""
    private var didReceiveJsonLine = false
    private(set) var isRunning = false
    private(set) var isBusy = false
    private var isFirstTurn = true
    private static var binaryPath: String?
    var systemPrompt: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    // MARK: - Lifecycle

    func start() {
        if Self.binaryPath != nil {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "gemini", fallbackPaths: [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "\(home)/.local/bin/gemini"
        ]) { [weak self] path in
            guard let self = self else { return }
            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.isRunning = true
                self.onSessionReady?()
            } else {
                let msg = "Gemini CLI not found.\n\n\(AgentProvider.gemini.installInstructions)"
                self.onError?(msg)
                self.history.appendBounded(AgentMessage(role: .error, text: msg))
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }

        var outgoing = message
        if let sp = systemPrompt {
            outgoing = "SYSTEM:\n\(sp)\n\n\(outgoing)"
            systemPrompt = nil
        }

        isBusy = true
        didReceiveJsonLine = false
        lineBuffer = ""
        currentResponseText = ""
        history.appendBounded(AgentMessage(role: .user, text: message))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        var args = ["--yolo", "-p", outgoing]
        if !isFirstTurn {
            args = ["--yolo", "--continue", "-p", outgoing]
        }
        proc.arguments = args

        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        ])

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var collectedText = ""

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil

                if self.currentResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let fallback = collectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !fallback.isEmpty {
                        self.currentResponseText = fallback
                        self.onText?(fallback)
                    }
                }

                if self.isBusy {
                    let finalText = self.currentResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !finalText.isEmpty {
                        self.history.appendBounded(AgentMessage(role: .assistant, text: finalText))
                    }
                    self.isBusy = false
                    self.onTurnComplete?()
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    collectedText += text
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let isProgressNoise = trimmed.hasPrefix("✓") || trimmed.hasPrefix("→") ||
                    trimmed.hasPrefix("◆") || trimmed.hasPrefix("⠋") ||
                    trimmed.hasPrefix("⠙") || trimmed.hasPrefix("⠹") ||
                    trimmed.hasPrefix("⠸") || trimmed.hasPrefix("⠼") ||
                    trimmed.hasPrefix("⠴") || trimmed.hasPrefix("⠦") ||
                    trimmed.hasPrefix("⠧") || trimmed.hasPrefix("⠇") ||
                    trimmed.hasPrefix("⠏") || trimmed.isEmpty
                if !isProgressNoise {
                    DispatchQueue.main.async {
                        self?.onError?(text)
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
            isFirstTurn = false
        } catch {
            isBusy = false
            let msg = "Failed to launch Gemini CLI: \(error.localizedDescription)"
            onError?(msg)
            history.appendBounded(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
    }

    // MARK: - Output Parsing

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
        if let rawData = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            didReceiveJsonLine = true
            handleJsonEvent(json)
            return
        }

        if !didReceiveJsonLine {
            let text = line + "\n"
            currentResponseText += text
            onText?(text)
        }
    }

    private func handleJsonEvent(_ json: [String: Any]) {
        let type = json["type"] as? String ?? json["event"] as? String ?? ""
        let data = json["data"] as? [String: Any] ?? json

        switch type {
        case "content", "text", "delta", "message":
            let text = data["text"] as? String ?? data["content"] as? String ?? json["text"] as? String ?? ""
            if !text.isEmpty {
                currentResponseText += text
                onText?(text)
            }

        case "tool_call", "function_call":
            let toolName = data["name"] as? String ?? "Tool"
            let input = data["input"] as? [String: Any] ?? data["arguments"] as? [String: Any] ?? [:]
            let summary = input["command"] as? String ?? toolName
            history.appendBounded(AgentMessage(role: .toolUse, text: "\(toolName): \(summary)"))
            onToolUse?(toolName, input)

        case "tool_result", "function_result":
            let output = data["output"] as? String ?? data["result"] as? String ?? ""
            let isError = (data["is_error"] as? Bool) ?? false
            let summary = String(output.prefix(80))
            history.appendBounded(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
            onToolResult?(summary, isError)

        case "done", "end", "complete", "turn_end":
            if isBusy {
                let finalText = currentResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalText.isEmpty {
                    history.appendBounded(AgentMessage(role: .assistant, text: finalText))
                }
                isBusy = false
                onTurnComplete?()
            }

        case "error":
            let msg = data["message"] as? String ?? data["error"] as? String ?? "Unknown Gemini error"
            onError?(msg)
            history.appendBounded(AgentMessage(role: .error, text: msg))

        default:
            if let text = json["text"] as? String ?? json["content"] as? String, !text.isEmpty {
                currentResponseText += text
                onText?(text)
            }
        }
    }
}
