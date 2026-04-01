import AVFoundation
import AppKit

class WalkerCharacter {
    let videoName: String
    var characterName: String = "Agent"
    var tagline: String = ""
    var window: NSWindow!
    var playerLayer: AVPlayerLayer!
    var queuePlayer: AVQueuePlayer!
    var looper: AVPlayerLooper!

    let videoWidth: CGFloat = 1080
    let videoHeight: CGFloat = 1920
    let displayHeight: CGFloat = 200
    var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }

    // Walk timing (per-character, from frame analysis)
    let videoDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    var characterColor: NSColor = .gray

    // Walk state
    var playCount = 0
    var walkStartTime: CFTimeInterval = 0
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    private var isManualDragging = false
    private var lastKnownDockX: CGFloat = 0
    private var lastKnownDockTopY: CGFloat = 0
    // Walk endpoints stored in pixels for consistent speed across screen switches
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    // Onboarding
    var isOnboarding = false

    // Popover state
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    private var userTurnCount = 0
    private var didPromptForReminderPreference = false
    private var isAwaitingReminderPreference = false
    private var isSmartReminderEnabled = false
    private var didShowProactiveLimitPrompt = false
    private var isAwaitingHandoffConfirmation = false
    private var isAgentSleeping = false
    private var sleepReason: String?
    private var orchestrator: ConversationOrchestrator?
    private var isPendingClearConfirmation = false
    private weak var modeBadgeLabel: NSTextField?
    // Active command mode: set when user triggers /debug, /refactor, etc.
    // Injected as a framing context prefix on every subsequent user message until cleared.
    private var activeCommandMode: String? // e.g. "debug", "explore"
    private var activeCommandPrompt: String? // the actual system instruction
    weak var controller: LilAgentsController?
    var themeOverride: PopoverTheme?
    var isAgentBusy: Bool { session?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    private(set) var isManuallyVisible = true
    private var environmentHiddenAt: CFTimeInterval?
    private var wasPopoverVisibleBeforeEnvironmentHide = false
    private var wasBubbleVisibleBeforeEnvironmentHide = false
    private var lastAssistantOutput = ""

    init(videoName: String) {
        self.videoName = videoName
    }

    // MARK: - Setup

    func setup() {
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            print("Video \(videoName) not found")
            return
        }

        let asset = AVAsset(url: videoURL)
        queuePlayer = AVQueuePlayer()
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: asset))

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.moveToActiveSpace, .stationary]

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(playerLayer)

        window.contentView = hostView
        window.orderFrontRegardless()
    }

    // MARK: - Visibility

    func setManuallyVisible(_ visible: Bool) {
        isManuallyVisible = visible
        if visible {
            if environmentHiddenAt == nil {
                window.orderFrontRegardless()
            }
        } else {
            queuePlayer.pause()
            window.orderOut(nil)
            popoverWindow?.orderOut(nil)
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    func hideForEnvironment() {
        guard environmentHiddenAt == nil else { return }

        environmentHiddenAt = CACurrentMediaTime()
        wasPopoverVisibleBeforeEnvironmentHide = popoverWindow?.isVisible ?? false
        wasBubbleVisibleBeforeEnvironmentHide = thinkingBubbleWindow?.isVisible ?? false

        queuePlayer.pause()
        window.orderOut(nil)
        popoverWindow?.orderOut(nil)
        thinkingBubbleWindow?.orderOut(nil)
    }

    func showForEnvironmentIfNeeded() {
        guard let hiddenAt = environmentHiddenAt else { return }

        let hiddenDuration = CACurrentMediaTime() - hiddenAt
        environmentHiddenAt = nil
        walkStartTime += hiddenDuration
        pauseEndTime += hiddenDuration
        completionBubbleExpiry += hiddenDuration
        lastPhraseUpdate += hiddenDuration

        guard isManuallyVisible else { return }

        window.orderFrontRegardless()
        if isWalking {
            queuePlayer.play()
        }

        if isIdleForPopover && wasPopoverVisibleBeforeEnvironmentHide {
            updatePopoverPosition()
            popoverWindow?.orderFrontRegardless()
            popoverWindow?.makeKey()
            if let terminal = terminalView {
                popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }

        if wasBubbleVisibleBeforeEnvironmentHide {
            updateThinkingBubble()
        }
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        if isOnboarding {
            openOnboardingPopover()
            return
        }
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)

        if popoverWindow == nil {
            createPopoverWindow()
        }

        // Show static welcome message instead of Claude terminal
        terminalView?.inputField.isEditable = false
        terminalView?.inputField.placeholderString = ""
        let welcome = """
        hey! we're bruce and jazz — your lil dock agents.

        click either of us to open a Claude AI chat. we'll walk around while you work and let you know when Claude's thinking.

        check the menu bar icon (top right) for themes, sounds, and more options.

        click anywhere outside to dismiss, then click us again to start chatting.
        """
        terminalView?.appendStreamingText(welcome)
        terminalView?.endStreaming()

        updatePopoverPosition()
        presentPopoverWithEntrance()

        // Set up click-outside to dismiss and complete onboarding
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 1.0...3.0)
        queuePlayer.seek(to: .zero)
        controller?.completeOnboarding()
    }

    func openPopover() {
        // Close any other open popover
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)

        // Always clear any bubble (thinking or completion) when popover opens
        showingCompletion = false
        hideBubble()

        let didCreateSession: Bool
        if session == nil {
            resetLimitPromptState()
            let newSession = AgentProvider.current.createSession()
            newSession.systemPrompt = AgentProvider.current.systemPrompt(for: characterName)
            session = newSession
            orchestrator = ConversationOrchestrator(provider: AgentProvider.current)
            wireSession(newSession)
            newSession.start()
            didCreateSession = true
        } else {
            didCreateSession = false
        }

        if popoverWindow == nil {
            createPopoverWindow()
        }

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        } else if didCreateSession {
            terminalView?.showSignatureIntro(characterName: characterName)
        }

        if didCreateSession {
            promptForReminderPreferenceIfNeeded()
        }

        updatePopoverPosition()
        presentPopoverWithEntrance()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
        }

        // Remove old monitors before adding new ones
        removeEventMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    func clearChat() {
        session?.terminate()
        session = nil
        orchestrator?.resetSession()
        resetLimitPromptState()
        terminalView?.textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        currentStreamingText = ""
    }

    @objc private func refreshChat() {
        clearChat()
        // Clear active command mode when starting a new chat
        activeCommandMode = nil
        activeCommandPrompt = nil
        terminalView?.activeCommandModeName = nil
        updateCommandModeBadge()
        let newSession = AgentProvider.current.createSession()
        newSession.systemPrompt = AgentProvider.current.systemPrompt(for: characterName)
        session = newSession
        orchestrator = ConversationOrchestrator(provider: AgentProvider.current)
        wireSession(newSession)
        newSession.start()
        terminalView?.showSignatureIntro(characterName: characterName)
    }

    private var characterInputPlaceholder: String {
        "Ask \(characterName)…"
    }

    private func resetLimitPromptState() {
        userTurnCount = 0
        didPromptForReminderPreference = false
        isAwaitingReminderPreference = false
        isSmartReminderEnabled = false
        didShowProactiveLimitPrompt = false
        isAwaitingHandoffConfirmation = false
        isAgentSleeping = false
        sleepReason = nil
        isPendingClearConfirmation = false
        lastAssistantOutput = ""
        terminalView?.inputField.placeholderString = characterInputPlaceholder
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        // If still waiting for a response, show thinking bubble immediately
        // If completion came while popover was open, show completion bubble
        if showingCompletion {
            // Reset expiry so user gets the full 3s from now
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            // Force a fresh phrase pick and show immediately
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    // Temporarily pause autonomous movement while the user manually repositions the character.
    func beginManualDrag() {
        isManualDragging = true
        isWalking = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + 3600
        queuePlayer.pause()
        hideBubble()
    }

    func endManualDrag() {
        guard isManualDragging else { return }

        let travelDistance = max(currentTravelDistance, 0)
        if travelDistance > 0 {
            let x = window.frame.origin.x
            let raw = (x - lastKnownDockX - currentFlipCompensation) / travelDistance
            positionProgress = min(max(raw, 0), 1)
        }

        walkStartPos = positionProgress
        walkEndPos = positionProgress
        walkStartPixel = positionProgress * max(currentTravelDistance, 0)
        walkEndPixel = walkStartPixel

        // Re-anchor to dock baseline so movement continues naturally from drop point.
        let bottomPadding = displayHeight * 0.15
        let groundedY = lastKnownDockTopY - bottomPadding + yOffset
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: groundedY))

        isManualDragging = false
        // Resume normal autonomous behavior immediately after drop.
        pauseEndTime = CACurrentMediaTime()
        if !isIdleForPopover && isManuallyVisible {
            startWalk()
        }
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let popoverWidth: CGFloat = 420
        let popoverHeight: CGFloat = 310

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBarHeight: CGFloat = 40
        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - titleBarHeight, width: popoverWidth, height: titleBarHeight))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        container.addSubview(titleBar)

        let combinedBase: String
        switch characterName.lowercased() {
        case "bruce": combinedBase = "Let's get to business"
        case "jazz": combinedBase = "Let's chit chat"
        default:
            let providerName = AgentProvider.current.displayName
            let separator = " — "
            let poweredBy = "Powered by \(providerName)"
            switch t.titleFormat {
            case .uppercase:      combinedBase = "\(characterName.uppercased())\(separator.uppercased())\(poweredBy.uppercased())"
            case .lowercaseTilde: combinedBase = "\(characterName) ~ powered by \(providerName.lowercased())"
            case .capitalized:    combinedBase = "\(characterName)\(separator)\(poweredBy)"
            }
        }
        let saverSuffix = (AgentProvider.current == .claude && AgentProvider.claudeSaverModeEnabled) ? " · Saver On" : ""
        let combined = combinedBase + saverSuffix
        let titleLabel = NSTextField(labelWithString: combined)
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.frame = NSRect(x: 12, y: (titleBarHeight - 16) / 2, width: popoverWidth - 80, height: 16)
        titleBar.addSubview(titleLabel)

        let refreshBtn = NSButton(frame: NSRect(x: popoverWidth - 28, y: (titleBarHeight - 20) / 2, width: 20, height: 20))
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        let refreshImg = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "New chat")
        refreshBtn.image = refreshImg
        refreshBtn.contentTintColor = t.titleText.withAlphaComponent(0.6)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshChat)
        titleBar.addSubview(refreshBtn)

        // Mode badge pill (A1)
        let badge = NSTextField(labelWithString: "")
        badge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        badge.textColor = t.titleText.withAlphaComponent(0.0)
        badge.frame = NSRect(x: popoverWidth - 80, y: (titleBarHeight - 14) / 2, width: 52, height: 14)
        badge.alignment = .right
        titleBar.addSubview(badge)
        modeBadgeLabel = badge
        updateModeBadge()

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - titleBarHeight - 1, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - titleBarHeight - 1))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.inputField.placeholderString = characterInputPlaceholder
        terminal.autoresizingMask = [.width, .height]
        terminal.onInterceptMessage = { [weak self] message in
            self?.handlePotentialHandoffResponse(message) ?? false
        }
        terminal.onSendMessage = { [weak self] message in
            self?.handleOutgoingUserMessage(message)
        }
        container.addSubview(terminal)

        win.contentView = container
        popoverWindow = win
        terminalView = terminal
    }

    private func wireSession(_ session: any AgentSession, providerName: String = AgentProvider.current.displayName) {
        session.onText = { [weak self] text in
            self?.orchestrator?.commitPendingUserMessageIfNeeded()
            self?.orchestrator?.recordAssistantChunk(text)
            self?.maybeShowBudgetNotice()
            self?.currentStreamingText += text
            self?.lastAssistantOutput += text
            self?.terminalView?.appendStreamingText(text)
        }

        session.onTurnComplete = { [weak self] in
            self?.orchestrator?.commitPendingUserMessageIfNeeded()
            self?.orchestrator?.recordTurnComplete()
            // C1: Flush accumulated streaming text as a single assistant turn
            if let text = self?.currentStreamingText, !text.isEmpty {
                self?.orchestrator?.recordAssistantTurn(text)
            }
            self?.logOrchestrationState(reason: "turn-complete")
            self?.updateModeBadge()
            self?.terminalView?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
        }

        session.onError = { [weak self] text in
            let isLimitSignal = AgentProvider.isLikelyLimitMessage(text)
            self?.orchestrator?.discardPendingUserMessage()
            self?.orchestrator?.recordError(isLimitSignal: isLimitSignal)
            self?.terminalView?.appendError(text)
            if isLimitSignal {
                self?.enterSleepMode(reason: "credit limit reached")
            }
        }

        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
        }

        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
        }

        session.onProcessExit = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.terminalView?.appendError("\(providerName) session ended.")
        }
    }

    private func handleOutgoingUserMessage(_ message: String) {
        if AgentProvider.orchestrationKillSwitchEnabled {
            session?.send(message: message)
            return
        }

        if isAgentSleeping {
            terminalView?.showToast("Agent is sleeping. Type /wake to resume.")
            return
        }

        if orchestrator == nil {
            orchestrator = ConversationOrchestrator(provider: AgentProvider.current)
        }

        orchestrator?.stageUserMessage(message)

        userTurnCount += 1
        maybeShowProactiveLimitPrompt()

        // Prepend active command mode instruction if set
        // This shapes how Claude responds for the duration of the mode.
        var outgoingMessage = message
        if let modePrompt = activeCommandPrompt {
            outgoingMessage = "[MODE: \(activeCommandMode?.uppercased() ?? "CUSTOM")]\n\(modePrompt)\n\nUser: \(message)"
        }

        // C1: Prompt assembly (gated behind orchestrationEnabled)
        if AgentProvider.current.orchestrationEnabled, let assembled = orchestrator?.assemblePrompt(userMessage: outgoingMessage) {
            session?.send(message: assembled)
        } else {
            session?.send(message: outgoingMessage)
        }
    }

    private func maybeShowBudgetNotice() {
        guard let notice = orchestrator?.consumeBudgetNotice() else { return }
        switch notice {
        case .nearSoftLimit:
            terminalView?.showToast("Near context budget. Responses may become shorter.")
        case .nearHardLimit:
            terminalView?.showToast("Near hard budget. Consider handoff or /wake flow soon.")
        }
        updateModeBadge()
        logOrchestrationState(reason: "budget-notice")
    }

    private func updateModeBadge() {
        guard let badge = modeBadgeLabel else { return }

        // Command mode takes priority over orchestration mode badge
        if let mode = activeCommandMode {
            badge.stringValue = "● \(mode)"
            badge.textColor = NSColor.systemCyan.withAlphaComponent(0.9)
            return
        }

        guard !AgentProvider.orchestrationKillSwitchEnabled, let usage = orchestrator?.usage else {
            badge.textColor = (badge.textColor ?? NSColor.white).withAlphaComponent(0.0)
            return
        }
        switch usage.mode {
        case .fullHistory:
            badge.stringValue = ""
            badge.textColor = (badge.textColor ?? NSColor.white).withAlphaComponent(0.0)
        case .compressedHistory:
            badge.stringValue = "● compressed"
            badge.textColor = NSColor.systemOrange.withAlphaComponent(0.85)
        case .emergency:
            badge.stringValue = "● emergency"
            badge.textColor = NSColor.systemRed
        }
    }

    private func updateCommandModeBadge() {
        updateModeBadge()
    }

    private func logOrchestrationState(reason: String) {
        guard AgentProvider.orchestrationDebugLogsEnabled else { return }
        guard let usage = orchestrator?.usage else { return }
        print("[orchestration] \(reason) provider=\(AgentProvider.current.rawValue) mode=\(usage.mode.rawValue) turns=\(usage.turnCount) estChars=\(usage.estimatedChars) errors=\(usage.errorStreak) limits=\(usage.limitSignalsSeen)")
    }

    private func enterSleepMode(reason: String) {
        guard !isAgentSleeping else { return }
        isAgentSleeping = true
        sleepReason = reason
        terminalView?.appendToolResult(summary: "Sleep mode enabled (\(reason)). Add credits, then type /wake to resume.", isError: true)
        terminalView?.showToast("Agent sleeping. Type /wake when ready.")
        terminalView?.inputField.placeholderString = "Agent sleeping. Type /wake"
    }

    private func wakeFromSleep() {
        isAgentSleeping = false
        sleepReason = nil
        terminalView?.inputField.placeholderString = characterInputPlaceholder
        terminalView?.showToast("Waking agent...")
        refreshChat()
    }

    private func maybeShowProactiveLimitPrompt() {
        guard isSmartReminderEnabled else { return }
        guard !didShowProactiveLimitPrompt, !isAwaitingHandoffConfirmation else { return }
        let threshold = AgentProvider.current.proactiveWarningTurnThreshold
        guard userTurnCount >= threshold else { return }
        didShowProactiveLimitPrompt = true
        showLimitPrompt(reason: "you are nearing your plan limit")
    }

    private func promptForReminderPreferenceIfNeeded() {
        let provider = AgentProvider.current
        if let saved = provider.loadSmartReminderPreference() {
            applySmartReminderPreferenceAcrossAgents(saved)
            didPromptForReminderPreference = true
            return
        }

        guard !didPromptForReminderPreference else { return }
        didPromptForReminderPreference = true
        isAwaitingReminderPreference = true
        terminalView?.showToast("Enable Smart reminders for \(provider.displayName)? Reply Y/N")
    }

    private func showLimitPrompt(reason: String) {
        guard !isAwaitingHandoffConfirmation else { return }
        isAwaitingHandoffConfirmation = true
        let provider = AgentProvider.current.displayName
        terminalView?.showToast("Near \(provider) limit (\(reason)). Generate handoff summary? Y/N")
    }

    private func applySmartReminderPreferenceAcrossAgents(_ enabled: Bool) {
        controller?.characters.forEach { character in
            character.isSmartReminderEnabled = enabled
            character.didPromptForReminderPreference = true
            character.isAwaitingReminderPreference = false
        }
    }

    private func handleCommandManagement(_ rawMessage: String, trimmedLower: String) -> Bool {
        if trimmedLower == "/commands" {
            let summary = CommandRegistry.shared.userCommandsSummary(for: characterName)
            let help = "\n\(summary)\n\nCreate: /command add /name | hint | response | optional system prompt\nRemove: /command remove /name\n"
            terminalView?.appendStreamingText(help)
            terminalView?.endStreaming()
            terminalView?.showToast("Command studio")
            return true
        }

        if trimmedLower.hasPrefix("/command add ") {
            let prefix = "/command add "
            let payload = String(rawMessage.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = payload.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            guard parts.count >= 3 else {
                terminalView?.showToast("Usage: /command add /name | hint | response | optional system prompt")
                return true
            }

            let modePrompt = parts.count > 3 ? parts[3] : nil
            let result = CommandRegistry.shared.addOrUpdateUserCommand(
                characterName: characterName,
                command: parts[0],
                hint: parts[1],
                response: parts[2],
                modeInstruction: modePrompt
            )
            let isError = result.hasPrefix("Failed")
            terminalView?.appendToolResult(summary: result, isError: isError)
            terminalView?.showToast(isError ? "Could not save command" : "Custom command saved")
            return true
        }

        if trimmedLower.hasPrefix("/command remove ") {
            let prefix = "/command remove "
            let commandName = String(rawMessage.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandName.isEmpty else {
                terminalView?.showToast("Usage: /command remove /name")
                return true
            }
            let result = CommandRegistry.shared.removeUserCommand(characterName: characterName, command: commandName)
            let isError = result.hasPrefix("Failed")
            terminalView?.appendToolResult(summary: result, isError: isError)
            terminalView?.showToast(isError ? "Could not remove command" : "Custom command removed")
            return true
        }

        return false
    }

    private func handlePotentialHandoffResponse(_ message: String) -> Bool {
        if isAgentSleeping {
            let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower == "/wake" || lower == "wake" || lower == "/resume" {
                wakeFromSleep()
                return true
            }
            if let reason = sleepReason {
                terminalView?.showToast("Sleeping (\(reason)). Type /wake")
            } else {
                terminalView?.showToast("Agent sleeping. Type /wake")
            }
            return true
        }

        if isAwaitingReminderPreference {
            let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower == "y" || lower == "yes" {
                isAwaitingReminderPreference = false
                applySmartReminderPreferenceAcrossAgents(true)
                AgentProvider.current.saveSmartReminderPreference(true)
                terminalView?.showToast("Smart reminders enabled")
                return true
            }
            if lower == "n" || lower == "no" {
                isAwaitingReminderPreference = false
                applySmartReminderPreferenceAcrossAgents(false)
                AgentProvider.current.saveSmartReminderPreference(false)
                terminalView?.showToast("Smart reminders disabled")
                return true
            }
            terminalView?.showToast("Reply with Y or N")
            return true
        }

        // Try character-specific command handlers first
        let trimmedOriginal = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCheck = trimmedOriginal.lowercased()
        if trimmedCheck.hasPrefix("/") {
            if handleCommandManagement(trimmedOriginal, trimmedLower: trimmedCheck) {
                return true
            }

            // /mode off — exit active mode without clearing the chat
            if trimmedCheck == "/mode off" {
                if let prevMode = activeCommandMode {
                    activeCommandMode = nil
                    activeCommandPrompt = nil
                    terminalView?.activeCommandModeName = nil
                    terminalView?.appendModePill(prevMode, active: false)
                    updateCommandModeBadge()
                    terminalView?.showToast("\(prevMode) mode off")
                } else {
                    terminalView?.showToast("No active mode")
                }
                return true
            }

            let context = CommandContext(
                message: message,
                characterName: characterName,
                onAppend: { [weak self] text in
                    self?.terminalView?.appendStreamingText(text)
                },
                onShowToast: { [weak self] toast in
                    self?.terminalView?.showToast(toast)
                },
                onRefreshChat: { [weak self] in
                    self?.refreshChat()
                },
                onExport: { [weak self] in
                    self?.exportConversation()
                },
                onActivateMode: { [weak self] modeName, instruction in
                    self?.activeCommandMode = modeName
                    self?.activeCommandPrompt = instruction
                    self?.terminalView?.activeCommandModeName = modeName
                    self?.terminalView?.appendModePill(modeName, active: true)
                    self?.updateCommandModeBadge()
                }
            )
            
            if CommandRegistry.shared.handleCommand(message, characterName: characterName, context: context) {
                return true
            }
        }

        // B2: /export command
        if trimmedCheck == "/export" || trimmedCheck == "export" {
            exportConversation()
            return true
        }

        // B1: /clear command — requires confirmation to prevent accidental data loss
        if trimmedCheck == "/clear" {
            if isPendingClearConfirmation {
                isPendingClearConfirmation = false
                refreshChat()
            } else {
                isPendingClearConfirmation = true
                terminalView?.showToast("This will clear your chat. Type /clear again to confirm.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    self?.isPendingClearConfirmation = false
                }
            }
            return true
        }

        // B1: /copilot command — send last response to VS Code Copilot chat
        if trimmedCheck == "/copilot" || trimmedCheck == "copilot" {
            guard !lastAssistantOutput.isEmpty else {
                terminalView?.showToast("No agent response to send yet")
                return true
            }
            sendToCopilotChat(lastAssistantOutput)
            return true
        }

        // B1: /handoff command (from palette)
        if trimmedCheck == "/handoff" {
            showLimitPrompt(reason: "manual handoff requested")
            return true
        }

        guard isAwaitingHandoffConfirmation else { return false }
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "y" || lower == "yes" {
            isAwaitingHandoffConfirmation = false
            let summary = generateHandoffSummary()
            terminalView?.appendStreamingText("\n\(summary)\n")
            terminalView?.endStreaming()
            copyToClipboard(summary)
            terminalView?.appendToolResult(summary: "Handoff summary copied to clipboard.", isError: false)
            return true
        }
        if lower == "n" || lower == "no" {
            isAwaitingHandoffConfirmation = false
            terminalView?.appendToolResult(summary: "Handoff summary skipped. Continuing current chat.", isError: false)
            return true
        }
        terminalView?.showToast("Reply with Y or N")
        return true
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        
        // Security: Auto-clear clipboard after 60 seconds to prevent sensitive data leakage
        // If user has copied something else in the meantime, don't clear (respect user action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if pb.string(forType: .string) == text {
                pb.clearContents()
            }
        }
    }

    private func sendToCopilotChat(_ text: String) {
        // Copy to clipboard (clipboard contents are handled via Cmd+V by AppleScript)
        copyToClipboard(text)
        
        // Use hardcoded AppleScript to open Copilot chat and paste content
        // Note: Never interpolate user input into AppleScript strings
        let script = """
        tell application "Visual Studio Code"
            activate
            delay 0.3
            tell application "System Events"
                keystroke "l" using {command down, shift down}
                delay 0.2
                keystroke "v" using {command down}
                delay 0.1
                key code 36
            end tell
        end tell
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        do {
            try task.run()
            task.waitUntilExit()
            terminalView?.showToast("Sent to Copilot chat")
        } catch {
            terminalView?.showToast("Could not send to Copilot. Make sure VS Code is running.")
        }
    }

    private func generateHandoffSummary() -> String {
        let messages = session?.history ?? []
        let firstUser = messages.first(where: { $0.role == .user })?.text ?? "Continue the current coding task."
        let assistantHighlights = messages
            .filter { $0.role == .assistant }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(3)

        var files = Set<String>()
        let filePattern = #"[A-Za-z0-9_./-]+\.(swift|md|json|js|ts|py|xcodeproj)"#
        let regex = try? NSRegularExpression(pattern: filePattern)
        for msg in messages {
            let range = NSRange(msg.text.startIndex..<msg.text.endIndex, in: msg.text)
            let matches = regex?.matches(in: msg.text, range: range) ?? []
            for m in matches {
                if let r = Range(m.range, in: msg.text) {
                    files.insert(String(msg.text[r]))
                }
            }
        }

        let riskItems = messages
            .filter { $0.role == .error || $0.text.lowercased().contains("error") }
            .map(\.text)
            .suffix(2)

        let objective = "Objective\n- \(firstUser)"

        let decisions: String
        if assistantHighlights.isEmpty {
            decisions = "Decisions made and why\n- No explicit decisions captured yet; continue from latest user direction."
        } else {
            let bullets = assistantHighlights.map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            decisions = "Decisions made and why\n\(bullets)"
        }

        let fileSection: String
        if files.isEmpty {
            fileSection = "Files touched and key changes\n- No concrete file paths captured in this session history yet."
        } else {
            let bullets = files.sorted().map { "- \($0): updated during session" }.joined(separator: "\n")
            fileSection = "Files touched and key changes\n\(bullets)"
        }

        let remaining = "Remaining tasks in priority order\n- Confirm current behavior still works end-to-end.\n- Implement the next smallest change requested by the user.\n- Run quick validation and capture any follow-up fixes."

        let risks: String
        if riskItems.isEmpty {
            risks = "Risks and test checklist\n- Risk: hidden edge cases in untested flows.\n- Test: run the main user flow and verify no regressions.\n- Test: confirm provider switching and session reset behavior."
        } else {
            let bullets = riskItems.map { "- Risk signal: \($0.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
            risks = "Risks and test checklist\n\(bullets)\n- Test: verify failures above are resolved.\n- Test: re-run core chat flow after fix."
        }

        return [
            "Please summarize this session for handoff to another coding assistant:",
            "",
            objective,
            "",
            decisions,
            "",
            fileSection,
            "",
            remaining,
            "",
            risks
        ].joined(separator: "\n")
    }

    private func exportConversation() {
        let messages = session?.history ?? []
        guard !messages.isEmpty else {
            terminalView?.showToast("Nothing to export yet.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let dateStr = formatter.string(from: Date())
        let fileName = "lil-agents-export-\(dateStr).md"

        var lines: [String] = ["# lil-agents Conversation Export", "", "**Character:** \(characterName)", "**Provider:** \(AgentProvider.current.displayName)", "**Date:** \(dateStr)", ""]
        for msg in messages {
            switch msg.role {
            case .user:
                lines.append("**You:** \(msg.text)\n")
            case .assistant:
                lines.append("**\(characterName):** \(msg.text)\n")
            case .error:
                lines.append("**Error:** \(msg.text)\n")
            case .toolUse, .toolResult:
                break
            }
        }
        let markdown = lines.joined(separator: "\n")

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = docsURL?.appendingPathComponent(fileName) {
            do {
                // Write file atomically
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                
                // Set POSIX file permissions to 0600 (owner read-write only)
                // This prevents other users on the system from reading sensitive conversation data
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: url.path
                )
            } catch {
                terminalView?.showToast("Failed to export conversation.")
                return
            }
        }
        copyToClipboard(markdown)
        terminalView?.appendToolResult(summary: "Conversation exported (file: private, readable by owner only) to ~/Documents/\(fileName) and copied to clipboard.", isError: false)
        terminalView?.showToast("Exported to ~/Documents/\(fileName) (private)")
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, visibleFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    private func presentPopoverWithEntrance() {
        guard let popover = popoverWindow else { return }
        let finalFrame = popover.frame
        let startFrame = finalFrame.offsetBy(dx: 0, dy: -10)
        popover.alphaValue = 0
        popover.setFrame(startFrame, display: false)
        popover.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            popover.animator().alphaValue = 1
            popover.animator().setFrame(finalFrame, display: true)
        }
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking..."
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * 0.88
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Walking

    func startWalk() {
        isPaused = false
        isWalking = true
        playCount = 0
        walkStartTime = CACurrentMediaTime()

        if positionProgress > 0.85 {
            goingRight = false
        } else if positionProgress < 0.15 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }

        walkStartPos = positionProgress
        // Walk a fixed pixel distance (~200-325px) regardless of screen width.
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3
        if goingRight {
            walkEndPos = min(walkStartPos + walkAmount, 1.0)
        } else {
            walkEndPos = max(walkStartPos - walkAmount, 0.0)
        }
        // Store pixel positions so walk speed stays consistent if screen changes mid-walk
        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance

        let minSeparation: CGFloat = 0.12
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self {
                let sibPos = sibling.positionProgress
                if abs(walkEndPos - sibPos) < minSeparation {
                    if goingRight {
                        walkEndPos = max(walkStartPos, sibPos - minSeparation)
                    } else {
                        walkEndPos = min(walkStartPos, sibPos + minSeparation)
                    }
                }
            }
        }

        updateFlip()
        queuePlayer.seek(to: .zero)
        queuePlayer.play()
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)
        let delay = Double.random(in: 5.0...12.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if goingRight {
            playerLayer.transform = CATransform3DIdentity
        } else {
            playerLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        CATransaction.commit()
    }

    var currentFlipCompensation: CGFloat {
        goingRight ? 0 : flipXOffset
    }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart {
            return 0.0
        } else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    // MARK: - Frame Update

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        currentTravelDistance = max(dockWidth - displayWidth, 0)
        lastKnownDockX = dockX
        lastKnownDockTopY = dockTopY

        if isManualDragging {
            let leftMouseDown = (NSEvent.pressedMouseButtons & 1) == 1
            if !leftMouseDown {
                endManualDrag()
            }
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let now = CACurrentMediaTime()

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            } else {
                let travelDistance = max(dockWidth - displayWidth, 0)
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = dockTopY - bottomPadding + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            // Interpolate in pixel space for consistent speed across screen changes
            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            // Convert pixel position back to progress for the current screen
            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }
}
