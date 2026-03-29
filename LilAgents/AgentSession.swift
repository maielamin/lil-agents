import Foundation

// MARK: - Provider

enum AgentProvider: String, CaseIterable {
    case claude, codex, copilot

    private static let defaultsKey = "selectedProvider"
    private static let smartReminderPrefix = "smartReminderEnabled."
    private static let claudeSaverModeKey = "claudeSaverModeEnabled"
    private static let claudePowerModeKey = "claudePowerModeEnabled"

    static var current: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .claude:  return "Claude"
        case .codex:   return "Codex"
        case .copilot: return "Copilot"
        }
    }

    var inputPlaceholder: String {
        "Ask \(displayName)..."
    }

    /// Returns provider name styled per theme format.
    func titleString(format: TitleFormat) -> String {
        switch format {
        case .uppercase:      return displayName.uppercased()
        case .lowercaseTilde: return "\(displayName.lowercased()) ~"
        case .capitalized:    return displayName
        }
    }

    var installInstructions: String {
        switch self {
        case .claude:
            return "To install, run this in Terminal:\n  curl -fsSL https://claude.ai/install.sh | sh\n\nOr download from https://claude.ai/download"
        case .codex:
            return "To install, run this in Terminal:\n  npm install -g @openai/codex"
        case .copilot:
            return "To install, run this in Terminal:\n  brew install copilot-cli\n\nOr: npm install -g @github/copilot-cli"
        }
    }

    func createSession() -> any AgentSession {
        switch self {
        case .claude:  return ClaudeSession()
        case .codex:   return CodexSession()
        case .copilot: return CopilotSession()
        }
    }

    var proactiveWarningTurnThreshold: Int {
        switch self {
        case .claude:  return 12
        case .codex:   return 20
        case .copilot: return 20
        }
    }

    static func isLikelyLimitMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = [
            "rate limit",
            "rate-limit",
            "quota",
            "too many requests",
            "429",
            "limit reached",
            "usage limit",
            "exceeded"
        ]
        return needles.contains { lower.contains($0) }
    }

    var smartReminderPreferenceKey: String {
        "\(Self.smartReminderPrefix)\(rawValue)"
    }

    func loadSmartReminderPreference() -> Bool? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: smartReminderPreferenceKey) != nil else { return nil }
        return defaults.bool(forKey: smartReminderPreferenceKey)
    }

    func saveSmartReminderPreference(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: smartReminderPreferenceKey)
    }

    func clearSmartReminderPreference() {
        UserDefaults.standard.removeObject(forKey: smartReminderPreferenceKey)
    }

    static func clearAllSmartReminderPreferences() {
        allCases.forEach { $0.clearSmartReminderPreference() }
    }

    static var claudeSaverModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: claudeSaverModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudeSaverModeKey) }
    }

    static var claudePowerModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: claudePowerModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: claudePowerModeKey) }
    }
}

// MARK: - Title Format

enum TitleFormat {
    case uppercase       // "CLAUDE"
    case lowercaseTilde  // "claude ~"
    case capitalized     // "Claude"
}

// MARK: - Message

struct AgentMessage {
    enum Role { case user, assistant, error, toolUse, toolResult }
    let role: Role
    let text: String
}

extension Array where Element == AgentMessage {
    mutating func appendBounded(_ message: AgentMessage, maxCount: Int = 400) {
        append(message)
        if count > maxCount {
            removeFirst(count - maxCount)
        }
    }
}

// MARK: - Session Protocol

protocol AgentSession: AnyObject {
    var isRunning: Bool { get }
    var isBusy: Bool { get }
    var history: [AgentMessage] { get }

    var onText: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onToolUse: ((String, [String: Any]) -> Void)? { get set }
    var onToolResult: ((String, Bool) -> Void)? { get set }
    var onSessionReady: (() -> Void)? { get set }
    var onTurnComplete: (() -> Void)? { get set }
    var onProcessExit: (() -> Void)? { get set }

    func start()
    func send(message: String)
    func terminate()
}
