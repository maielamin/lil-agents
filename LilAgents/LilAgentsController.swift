import AppKit

class LilAgentsController {
    var characters: [WalkerCharacter] = []
    private var displayLink: CVDisplayLink?
    var debugWindow: NSWindow?
    private static let onboardingKey = "hasCompletedOnboarding"

    func start() {
        let char1 = WalkerCharacter(videoName: "walk-bruce-01")
        char1.characterName = "Bruce"
        char1.accelStart = 3.0
        char1.fullSpeedStart = 3.75
        char1.decelStart = 8.0
        char1.walkStop = 8.5
        char1.walkAmountRange = 0.4...0.65

        let char2 = WalkerCharacter(videoName: "walk-jazz-01")
        char2.characterName = "Jazz"
        char2.accelStart = 3.9
        char2.fullSpeedStart = 4.5
        char2.decelStart = 8.0
        char2.walkStop = 8.75
        char2.walkAmountRange = 0.35...0.6
        char1.yOffset = -3
        char2.yOffset = -7
        char1.characterColor = NSColor(red: 0.4, green: 0.72, blue: 0.55, alpha: 1.0)
        char2.characterColor = NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0)

        char1.flipXOffset = 0
        char2.flipXOffset = -9

        char1.positionProgress = 0.3
        char2.positionProgress = 0.7

        char1.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...2.0)
        char2.pauseEndTime = CACurrentMediaTime() + Double.random(in: 8.0...14.0)

        characters = [char1, char2]
        characters.forEach { $0.controller = self }
        characters.forEach { $0.setup() }

        setupDebugLine()
        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    private func triggerOnboarding() {
        guard let bruce = characters.first else { return }
        bruce.isOnboarding = true
        // Show "hi!" bubble after a short delay so the character is visible first
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            bruce.currentPhrase = "hi!"
            bruce.showingCompletion = true
            bruce.completionBubbleExpiry = CACurrentMediaTime() + 600 // stays until clicked
            bruce.showBubble(text: "hi!", isCompletion: true)
            bruce.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    // MARK: - Debug

    private func setupDebugLine() {
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 2),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.red
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        win.orderOut(nil)
        debugWindow = win
    }

    private func updateDebugLine(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        guard let win = debugWindow, win.isVisible else { return }
        win.setFrame(CGRect(x: dockX, y: dockTopY, width: dockWidth, height: 2), display: true)
    }

    // MARK: - Dock Geometry

    private func getDockIconArea(screenWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        // Each dock slot is the icon + padding. The padding scales with tile size.
        // At default 48pt: slot ≈ 58pt. At 37pt: slot ≈ 47pt. Roughly tileSize * 1.25.
        let slotWidth = tileSize * 1.25

        let persistentApps = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        let persistentOthers = dockDefaults?.array(forKey: "persistent-others")?.count ?? 0

        // Only count recent apps if show-recents is enabled
        let showRecents = dockDefaults?.bool(forKey: "show-recents") ?? true
        let recentApps = showRecents ? (dockDefaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let totalIcons = persistentApps + persistentOthers + recentApps

        var dividers = 0
        if persistentApps > 0 && (persistentOthers > 0 || recentApps > 0) { dividers += 1 }
        if persistentOthers > 0 && recentApps > 0 { dividers += 1 }
        // show-recents adds its own divider
        if showRecents && recentApps > 0 { dividers += 1 }

        let dividerWidth: CGFloat = 12.0
        var dockWidth = slotWidth * CGFloat(totalIcons) + CGFloat(dividers) * dividerWidth

        let magnificationEnabled = dockDefaults?.bool(forKey: "magnification") ?? false
        if magnificationEnabled,
           let largeSize = dockDefaults?.object(forKey: "largesize") as? CGFloat {
            // Magnification only affects the hovered area; at rest the dock is normal size.
            // Don't inflate the width — characters should stay within the at-rest bounds.
            _ = largeSize
        }

        // Small fudge factor for dock edge padding
        dockWidth *= 1.1
        let dockX = (screenWidth - dockWidth) / 2.0
        return (dockX, dockWidth)
    }

    private func dockAutohideEnabled() -> Bool {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        return dockDefaults?.bool(forKey: "autohide") ?? false
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let controller = Unmanaged<LilAgentsController>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    func dockGeometry(for screen: NSScreen) -> (dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        let (localDockX, dockWidth) = getDockIconArea(screenWidth: screen.frame.width)
        return (screen.frame.minX + localDockX, dockWidth, screen.visibleFrame.origin.y)
    }

    func screenIndex(for character: WalkerCharacter) -> Int {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return -1 }

        let preferredIndex = character.preferredScreenIndex
        if preferredIndex >= 0, preferredIndex < screens.count {
            return preferredIndex
        }

        if let mainScreen = NSScreen.main,
           let mainIndex = screens.firstIndex(where: { $0 === mainScreen }),
           let characterIndex = characters.firstIndex(where: { $0 === character }) {
            if characterIndex == 0 {
                return mainIndex
            }

            var remainingIndices = Array(screens.indices)
            remainingIndices.removeAll { $0 == mainIndex }
            if !remainingIndices.isEmpty {
                return remainingIndices[min(characterIndex - 1, remainingIndices.count - 1)]
            }

            return mainIndex
        }

        if let characterIndex = characters.firstIndex(where: { $0 === character }) {
            return min(characterIndex, screens.count - 1)
        }

        return 0
    }

    func screen(for character: WalkerCharacter) -> NSScreen? {
        let screens = NSScreen.screens
        let index = screenIndex(for: character)
        guard index >= 0, index < screens.count else { return NSScreen.main ?? screens.first }
        return screens[index]
    }

    /// The dock lives on the screen where visibleFrame.origin.y > frame.origin.y (bottom dock)
    /// On screens without the dock, visibleFrame.origin.y == frame.origin.y
    private func screenHasDock(_ screen: NSScreen) -> Bool {
        screen.visibleFrame.origin.y > screen.frame.origin.y
    }

    private func shouldShowCharacter(on screen: NSScreen) -> Bool {
        if screenHasDock(screen) {
            return true
        }

        // Allow agents to stay on secondary displays even when the Dock isn't currently
        // visible there, so each monitor can keep its own agent/session.
        if NSScreen.screens.count > 1 {
            return true
        }

        let menuBarVisible = screen.visibleFrame.maxY < screen.frame.maxY
        return dockAutohideEnabled() && screen == NSScreen.main && menuBarVisible
    }

    @discardableResult
    private func updateEnvironmentVisibility(for character: WalkerCharacter, on screen: NSScreen) -> Bool {
        let shouldShow = shouldShowCharacter(on: screen)

        if shouldShow {
            character.showForEnvironmentIfNeeded()
        } else {
            debugWindow?.orderOut(nil)
            character.hideForEnvironment()
        }

        return shouldShow
    }

    func tick() {
        let candidateChars = characters.filter { $0.isManuallyVisible }
        var visibleChars: [(character: WalkerCharacter, screen: NSScreen)] = []

        for char in candidateChars {
            guard let screen = screen(for: char) else { continue }
            guard updateEnvironmentVisibility(for: char, on: screen) else { continue }
            visibleChars.append((character: char, screen: screen))
        }

        let now = CACurrentMediaTime()
        let anyWalking = visibleChars.contains { $0.character.isWalking }
        for entry in visibleChars {
            let char = entry.character
            if char.isIdleForPopover { continue }
            if char.isPaused && now >= char.pauseEndTime && anyWalking {
                char.pauseEndTime = now + Double.random(in: 5.0...10.0)
            }
        }

        for (index, entry) in visibleChars.enumerated() {
            let geometry = dockGeometry(for: entry.screen)
            if index == 0 {
                updateDebugLine(dockX: geometry.dockX, dockWidth: geometry.dockWidth, dockTopY: geometry.dockTopY)
            }
            entry.character.update(dockX: geometry.dockX, dockWidth: geometry.dockWidth, dockTopY: geometry.dockTopY)
        }

        if visibleChars.isEmpty {
            debugWindow?.orderOut(nil)
        }

        let sorted = visibleChars.map { $0.character }.sorted { lhs, rhs in
            let lhsScreenIndex = screenIndex(for: lhs)
            let rhsScreenIndex = screenIndex(for: rhs)
            if lhsScreenIndex != rhsScreenIndex {
                return lhsScreenIndex < rhsScreenIndex
            }
            return lhs.positionProgress < rhs.positionProgress
        }

        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + i)
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
