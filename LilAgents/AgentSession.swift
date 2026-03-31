import Foundation

// MARK: - Provider

enum AgentProvider: String, CaseIterable {
    case claude, codex, copilot

    private static let defaultsKey = "selectedProvider"
    private static let smartReminderPrefix = "smartReminderEnabled."
    private static let claudeSaverModeKey = "claudeSaverModeEnabled"
    private static let claudePowerModeKey = "claudePowerModeEnabled"
    private static let orchestrationEnabledPrefix = "orchestrationEnabled."
    private static let orchestrationSafeModeKey = "orchestrationSafeMode"
    private static let orchestrationKillSwitchKey = "orchestrationKillSwitch"
    private static let orchestrationDebugLogsKey = "orchestrationDebugLogs"

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
            "exceeded",
            "insufficient",
            "credit",
            "billing",
            "out of credits"
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

    var orchestrationEnabledKey: String {
        "\(Self.orchestrationEnabledPrefix)\(rawValue)"
    }

    var orchestrationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: orchestrationEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: orchestrationEnabledKey) }
    }

    static var orchestrationSafeModeEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: orchestrationSafeModeKey) == nil {
                defaults.set(true, forKey: orchestrationSafeModeKey)
                return true
            }
            return defaults.bool(forKey: orchestrationSafeModeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: orchestrationSafeModeKey) }
    }

    static var orchestrationKillSwitchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: orchestrationKillSwitchKey) }
        set { UserDefaults.standard.set(newValue, forKey: orchestrationKillSwitchKey) }
    }

    static var orchestrationDebugLogsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: orchestrationDebugLogsKey) }
        set { UserDefaults.standard.set(newValue, forKey: orchestrationDebugLogsKey) }
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

// MARK: - Orchestration Tracking

enum OrchestrationMode: String, Codable {
    case fullHistory
    case compressedHistory
    case emergency
}

enum BudgetNotice {
    case nearSoftLimit
    case nearHardLimit
}

struct UsageState: Codable {
    var totalUserChars: Int = 0
    var totalAssistantChars: Int = 0
    var turnCount: Int = 0
    var errorStreak: Int = 0
    var limitSignalsSeen: Int = 0
    var sessionStartedAt: Date = Date()
    var lastTurnAt: Date = Date()
    var maxNoticeLevel: Int = 0

    var estimatedChars: Int {
        totalUserChars + totalAssistantChars
    }

    var mode: OrchestrationMode {
        if estimatedChars >= 22000 {
            return .emergency
        }
        if estimatedChars >= 12000 {
            return .compressedHistory
        }
        return .fullHistory
    }
}

final class ConversationOrchestrator {
    private let provider: AgentProvider
    private let defaults = UserDefaults.standard
    private let softThreshold = 12000
    private let hardThreshold = 22000

    private(set) var usage: UsageState

    init(provider: AgentProvider) {
        self.provider = provider
        self.usage = Self.loadUsage(from: defaults, for: provider) ?? UsageState()
    }

    func resetSession() {
        usage = UsageState()
        save()
    }

    func recordUserMessage(_ message: String) {
        usage.turnCount += 1
        usage.totalUserChars += message.count
        usage.lastTurnAt = Date()
        save()
    }

    func recordAssistantChunk(_ text: String) {
        usage.totalAssistantChars += text.count
        usage.lastTurnAt = Date()
        save()
    }

    func recordTurnComplete() {
        usage.errorStreak = 0
        usage.lastTurnAt = Date()
        save()
    }

    func recordError(isLimitSignal: Bool) {
        usage.errorStreak += 1
        if isLimitSignal {
            usage.limitSignalsSeen += 1
        }
        usage.lastTurnAt = Date()
        save()
    }

    func consumeBudgetNotice() -> BudgetNotice? {
        if usage.estimatedChars >= hardThreshold {
            guard usage.maxNoticeLevel < 2 else { return nil }
            usage.maxNoticeLevel = 2
            save()
            return .nearHardLimit
        }

        if usage.estimatedChars >= softThreshold {
            guard usage.maxNoticeLevel < 1 else { return nil }
            usage.maxNoticeLevel = 1
            save()
            return .nearSoftLimit
        }

        return nil
    }

    private var storageKey: String {
        "usage.\(provider.rawValue).state"
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(usage) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadUsage(from defaults: UserDefaults, for provider: AgentProvider) -> UsageState? {
        let key = "usage.\(provider.rawValue).state"
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageState.self, from: data)
    }
}
