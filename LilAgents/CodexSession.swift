import Foundation

class CodexSession: AgentSession {
    private static let recentMessageWindow = 14
    private static let perMessageCharLimit = 420
    private static let summaryBudgetChars = 2400

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

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
        if let cached = Self.binaryPath {
            isRunning = true
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "codex", fallbackPaths: [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]) { [weak self] path in
            guard let self = self, let binaryPath = path else {
                let msg = "Codex CLI not found.\n\n\(AgentProvider.codex.installInstructions)"
                self?.onError?(msg)
                self?.history.appendBounded(AgentMessage(role: .error, text: msg))
                return
            }
            Self.binaryPath = binaryPath
            self.isRunning = true
            self.onSessionReady?()
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        history.appendBounded(AgentMessage(role: .user, text: message))
        lineBuffer = ""

        // Current Codex CLI: only `codex exec [OPTIONS] <PROMPT>` (resume/--last removed).
        let prompt = Self.execPrompt(priorMessages: history.dropLast(), latestUserMessage: message)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)

        proc.arguments = ["exec", "--json", "--full-auto", "--skip-git-repo-check", prompt]

        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path
        ])

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                // Flush remaining buffer
                if !self.lineBuffer.isEmpty {
                    self.parseLine(self.lineBuffer)
                    self.lineBuffer = ""
                }
                if self.isBusy {
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
            outputPipe = outPipe
            errorPipe = errPipe
        } catch {
            isBusy = false
            let msg = "Failed to launch Codex CLI: \(error.localizedDescription)"
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

    // MARK: - Prompt (multi-turn without codex exec resume)

    private static func execPrompt(priorMessages: ArraySlice<AgentMessage>, latestUserMessage: String) -> String {
        guard !priorMessages.isEmpty else { return latestUserMessage }

        let all = Array(priorMessages)
        let splitIndex = max(0, all.count - recentMessageWindow)
        let older = Array(all[..<splitIndex])
        let recent = Array(all[splitIndex...])

        let recentBlock = renderMessages(recent)

        if older.isEmpty {
            return """
            Conversation so far (for context; respond only to the follow-up):

            \(recentBlock)

            ---

            User (follow-up): \(latestUserMessage)
            """
        }

        let olderSummary = summarizeMessages(older, budgetChars: summaryBudgetChars)

        return """
        Conversation context (respond only to the follow-up):

        Compressed memory of older turns:
        \(olderSummary)

        Recent turns (verbatim):
        \(recentBlock)

        Keep continuity with the context above, but prioritize correctness for the latest user request.

        ---

        User (follow-up): \(latestUserMessage)
        """
    }

    private static func renderMessages(_ messages: [AgentMessage]) -> String {
        messages.map { message in
            "\(rolePrefix(message.role)): \(compact(message.text, maxChars: perMessageCharLimit))"
        }.joined(separator: "\n\n")
    }

    private static func summarizeMessages(_ messages: [AgentMessage], budgetChars: Int) -> String {
        var bullets: [String] = []
        var used = 0

        for message in messages {
            let line = "- \(rolePrefix(message.role)): \(compact(message.text, maxChars: 180))"
            let next = line.count + 1
            if used + next > budgetChars { break }
            bullets.append(line)
            used += next
        }

        if bullets.isEmpty {
            return "- (older context omitted for brevity)"
        }
        return bullets.joined(separator: "\n")
    }

    private static func rolePrefix(_ role: AgentMessage.Role) -> String {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .toolUse: return "Tool"
        case .toolResult: return "ToolResult"
        case .error: return "Error"
        }
    }

    private static func compact(_ text: String, maxChars: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count <= maxChars { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: maxChars)
        return String(singleLine[..<end]) + "..."
    }

    // MARK: - JSONL Parsing

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
        case "thread.started":
            break // session tracking handled by codex internally

        case "item.started":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                if itemType == "command_execution" {
                    let command = item["command"] as? String ?? ""
                    history.appendBounded(AgentMessage(role: .toolUse, text: "Bash: \(command)"))
                    onToolUse?("Bash", ["command": command])
                }
            }

        case "item.completed":
            if let item = json["item"] as? [String: Any] {
                let itemType = item["type"] as? String ?? ""
                switch itemType {
                case "agent_message":
                    let text = item["text"] as? String ?? ""
                    if !text.isEmpty {
                        history.appendBounded(AgentMessage(role: .assistant, text: text))
                        onText?(text)
                    }
                case "command_execution":
                    let status = item["status"] as? String ?? ""
                    let command = item["command"] as? String ?? ""
                    let isError = status == "failed"
                    let summary = command.isEmpty ? status : String(command.prefix(80))
                    history.appendBounded(AgentMessage(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                    onToolResult?(summary, isError)
                case "file_change":
                    let path = item["file"] as? String ?? item["path"] as? String ?? "file"
                    history.appendBounded(AgentMessage(role: .toolUse, text: "FileChange: \(path)"))
                    onToolUse?("FileChange", ["file_path": path])
                    history.appendBounded(AgentMessage(role: .toolResult, text: path))
                    onToolResult?(path, false)
                default:
                    break
                }
            }

        case "turn.completed":
            isBusy = false
            onTurnComplete?()

        case "turn.failed":
            isBusy = false
            let msg = json["message"] as? String ?? "Turn failed"
            onError?(msg)
            history.appendBounded(AgentMessage(role: .error, text: msg))
            onTurnComplete?()

        case "error":
            let msg = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            onError?(msg)
            history.appendBounded(AgentMessage(role: .error, text: msg))

        default:
            break
        }
    }
}
