import Foundation

// MARK: - Command Handler Protocol

protocol CommandHandler {
    var command: String { get }
    var label: String { get }
    var hint: String { get }
    var characterName: String { get }
    
    /// Handle the command execution. Return true if handled, false otherwise.
    func execute(context: CommandContext) -> Bool
}

// MARK: - Command Context

struct CommandContext {
    let message: String
    let characterName: String
    let onAppend: (String) -> Void
    let onShowToast: (String) -> Void
    let onRefreshChat: () -> Void
    let onExport: () -> Void
}

// MARK: - Built-in Command Handlers

class DebugCommandHandler: CommandHandler {
    let command = "/debug"
    let label = "debug"
    let hint = "Analyze and troubleshoot code"
    let characterName = "Bruce"
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "/debug" || trimmed == "debug" else { return false }
        
        // Bruce's debug mode: structured, direct
        context.onShowToast("🔍 Debug mode: input your code or error")
        context.onAppend("DEBUG: Ready to analyze. Paste your code or describe the issue.\n")
        return true
    }
}

class RefactorCommandHandler: CommandHandler {
    let command = "/refactor"
    let label = "refactor"
    let hint = "Improve code structure"
    let characterName = "Bruce"
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "/refactor" || trimmed == "refactor" else { return false }
        
        // Bruce's refactor mode: shows improvement first
        context.onShowToast("♻️ Refactor mode: paste your code")
        context.onAppend("REFACTOR: Share the code you'd like to improve. I'll suggest cleaner patterns.\n")
        return true
    }
}

class ExploreCommandHandler: CommandHandler {
    let command = "/explore"
    let label = "explore"
    let hint = "Explore ideas and possibilities"
    let characterName = "Jazz"
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "/explore" || trimmed == "explore" else { return false }
        
        // Jazz's explore mode: open-ended, inviting
        context.onShowToast("🌌 Let's explore together")
        context.onAppend("EXPLORE: What's on your mind? We can dig into possibilities, ask questions, and discover something unexpected.\n")
        return true
    }
}

class ReflectCommandHandler: CommandHandler {
    let command = "/reflect"
    let label = "reflect"
    let hint = "Think deeper about the topic"
    let characterName = "Jazz"
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "/reflect" || trimmed == "reflect" else { return false }
        
        // Jazz's reflect mode: meditative, returns the question back
        context.onShowToast("🪞 Reflection mode")
        context.onAppend("REFLECT: What would you like to think through? I'll help you examine it from different angles.\n")
        return true
    }
}

class BrainstormCommandHandler: CommandHandler {
    let command = "/brainstorm"
    let label = "brainstorm"
    let hint = "Generate creative ideas"
    let characterName = "Jazz"
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed == "/brainstorm" || trimmed == "brainstorm" else { return false }
        
        // Jazz's brainstorm mode: generative, no judgment
        context.onShowToast("💡 Brainstorm mode: wild ideas welcome")
        context.onAppend("BRAINSTORM: What challenge or opportunity are we brainstorming? No bad ideas—let's generate freely.\n")
        return true
    }
}

// MARK: - User-Defined Command Handler

class UserDefinedCommandHandler: CommandHandler {
    let command: String
    let label: String
    let hint: String
    let characterName: String
    let responseTemplate: String
    
    init?(from dictionary: [String: Any], characterName: String) {
        guard let cmd = dictionary["command"] as? String,
              let lbl = dictionary["label"] as? String,
              let hnt = dictionary["hint"] as? String,
              let response = dictionary["response"] as? String else {
            return nil
        }
        
        self.command = cmd
        self.label = lbl
        self.hint = hnt
        self.characterName = characterName
        self.responseTemplate = response
    }
    
    func execute(context: CommandContext) -> Bool {
        let trimmed = context.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cmdLower = command.lowercased()
        guard trimmed == cmdLower || trimmed == cmdLower.dropFirst() else { return false }
        
        context.onShowToast("📌 Custom: \(label)")
        context.onAppend("\(responseTemplate)\n")
        return true
    }
}

// MARK: - Command Registry

class CommandRegistry {
    private var handlers: [CommandHandler] = []
    
    static let shared = CommandRegistry()
    
    private init() {
        registerBuiltInCommands()
        loadUserCommands()
    }
    
    private func registerBuiltInCommands() {
        handlers.append(DebugCommandHandler())
        handlers.append(RefactorCommandHandler())
        handlers.append(ExploreCommandHandler())
        handlers.append(ReflectCommandHandler())
        handlers.append(BrainstormCommandHandler())
    }
    
    private func loadUserCommands() {
        // Load from ~/lil-agents-commands.json or app support folder
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let commandsURL = appSupportURL.appendingPathComponent("lil-agents-commands.json")
        
        guard FileManager.default.fileExists(atPath: commandsURL.path) else { return }
        guard let data = try? Data(contentsOf: commandsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        
        for cmdDict in json {
            // Determine character from hint or default based on command type
            let character = (cmdDict["character"] as? String) ?? "Bruce"
            if let handler = UserDefinedCommandHandler(from: cmdDict, characterName: character) {
                handlers.append(handler)
            }
        }
    }
    
    func handleCommand(_ message: String, characterName: String, context: CommandContext) -> Bool {
        // Filter handlers by character first
        let relevantHandlers = handlers.filter { handler in
            handler.characterName.lowercased() == characterName.lowercased()
        }
        
        for handler in relevantHandlers {
            if handler.execute(context: context) {
                return true
            }
        }
        
        return false
    }
    
    func commandsForCharacter(_ characterName: String) -> [CommandHandler] {
        return handlers.filter { $0.characterName.lowercased() == characterName.lowercased() }
    }
    
    func allCommands() -> [CommandHandler] {
        return handlers
    }
}
