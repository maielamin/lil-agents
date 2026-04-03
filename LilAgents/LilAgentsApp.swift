import SwiftUI
import AppKit
import Sparkle

@main
struct LilAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: LilAgentsController?
    var statusItem: NSStatusItem?
    var displayMenu: NSMenu?
    var sizeMenu: NSMenu?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = LilAgentsController()
        controller?.start()
        setupMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.characters.forEach { $0.session?.terminate() }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "lil agents")
        }

        let menu = NSMenu()

        let char1Item = NSMenuItem(title: "Bruce", action: #selector(toggleChar1), keyEquivalent: "1")
        char1Item.state = .on
        menu.addItem(char1Item)

        let char2Item = NSMenuItem(title: "Jazz", action: #selector(toggleChar2), keyEquivalent: "2")
        char2Item.state = .on
        menu.addItem(char2Item)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = .on
        menu.addItem(soundItem)

        // Provider submenu
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for (i, provider) in AgentProvider.allCases.enumerated() {
            let item = NSMenuItem(title: provider.displayName, action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = provider == AgentProvider.current ? .on : .off
            providerMenu.addItem(item)
        }
        providerMenu.addItem(NSMenuItem.separator())
        let powerMode = NSMenuItem(title: "Claude Power Mode", action: #selector(toggleClaudePowerMode(_:)), keyEquivalent: "")
        powerMode.target = self
        powerMode.tag = -1000
        powerMode.state = AgentProvider.claudePowerModeEnabled ? .on : .off
        powerMode.toolTip = "Lets Claude run tools without permission prompts. Safer to keep off unless you need full automation."
        providerMenu.addItem(powerMode)
        let saverMode = NSMenuItem(title: "Claude Saver Mode", action: #selector(toggleClaudeSaverMode(_:)), keyEquivalent: "")
        saverMode.target = self
        saverMode.tag = -1001
        saverMode.state = AgentProvider.claudeSaverModeEnabled ? .on : .off
        providerMenu.addItem(saverMode)
        providerMenu.addItem(NSMenuItem.separator())
        let resetCurrent = NSMenuItem(title: "Reset Smart Reminder (Current)", action: #selector(resetSmartReminderCurrent), keyEquivalent: "")
        resetCurrent.target = self
        resetCurrent.tag = -1002
        providerMenu.addItem(resetCurrent)
        let resetAll = NSMenuItem(title: "Reset Smart Reminder (All)", action: #selector(resetSmartReminderAll), keyEquivalent: "")
        resetAll.target = self
        resetAll.tag = -1003
        providerMenu.addItem(resetAll)
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // Theme submenu
        let themeItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for (i, theme) in PopoverTheme.allThemes.enumerated() {
            let item = NSMenuItem(title: theme.name, action: #selector(switchTheme(_:)), keyEquivalent: "")
            item.tag = i
            item.state = theme.name == PopoverTheme.current.name ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let sizeItem = NSMenuItem(title: "Agent Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.delegate = self
        self.sizeMenu = sizeMenu
        rebuildSizeMenu()
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // Display submenu
        let displayItem = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.delegate = self
        self.displayMenu = displayMenu
        rebuildDisplayMenu()
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func rebuildSizeMenu() {
        guard let sizeMenu else { return }
        sizeMenu.removeAllItems()

        let currentPreset = WalkerCharacter.sizePreset
        for preset in AgentSizePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(switchAgentSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.rawValue
            item.state = currentPreset == preset ? .on : .off
            sizeMenu.addItem(item)
        }
    }

    private func rebuildDisplayMenu() {
        guard let displayMenu else { return }
        displayMenu.removeAllItems()

        guard let controller else { return }
        let screens = NSScreen.screens

        for (charIndex, char) in controller.characters.enumerated() {
            let charItem = NSMenuItem(title: char.characterName, action: nil, keyEquivalent: "")
            let charMenu = NSMenu(title: char.characterName)

            let isAuto = char.preferredScreenIndex == -1
            let autoItem = NSMenuItem(title: "Auto", action: #selector(switchCharacterDisplay(_:)), keyEquivalent: "")
            autoItem.target = self
            autoItem.tag = -1
            autoItem.representedObject = charIndex
            autoItem.state = isAuto ? .on : .off
            charMenu.addItem(autoItem)
            charMenu.addItem(NSMenuItem.separator())

            let activeScreenIndex = controller.screenIndex(for: char)
            for (screenIndex, screen) in screens.enumerated() {
                let item = NSMenuItem(title: screen.localizedName, action: #selector(switchCharacterDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = screenIndex
                item.representedObject = charIndex
                item.state = (!isAuto && activeScreenIndex == screenIndex) ? .on : .off
                charMenu.addItem(item)
            }

            charItem.submenu = charMenu
            displayMenu.addItem(charItem)
        }

        if !controller.characters.isEmpty {
            displayMenu.addItem(NSMenuItem.separator())
        }

        let spreadItem = NSMenuItem(title: "Auto Spread Across Displays", action: #selector(autoSpreadDisplays), keyEquivalent: "")
        spreadItem.target = self
        displayMenu.addItem(spreadItem)
    }

    // MARK: - Menu Actions

    @objc func switchTheme(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < PopoverTheme.allThemes.count else { return }
        PopoverTheme.current = PopoverTheme.allThemes[idx]

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }

        controller?.characters.forEach { char in
            let wasOpen = char.isIdleForPopover
            if wasOpen { char.popoverWindow?.orderOut(nil) }
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow = nil
            if wasOpen {
                char.createPopoverWindow()
                if let session = char.session, !session.history.isEmpty {
                    char.terminalView?.replayHistory(session.history)
                }
                char.updatePopoverPosition()
                char.popoverWindow?.orderFrontRegardless()
                char.popoverWindow?.makeKey()
                if let terminal = char.terminalView {
                    char.popoverWindow?.makeFirstResponder(terminal.inputField)
                }
            }
        }
    }

    @objc func switchProvider(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allProviders = AgentProvider.allCases
        guard idx < allProviders.count else { return }
        AgentProvider.current = allProviders[idx]

        if let providerMenu = sender.menu {
            for item in providerMenu.items {
                if item.action == #selector(switchProvider(_:)) {
                    item.state = item.tag == idx ? .on : .off
                }
            }
        }

        // Terminate existing sessions and clear UI so title/placeholder update
        controller?.characters.forEach { char in
            char.session?.terminate()
            char.session = nil
            if char.isIdleForPopover {
                char.closePopover()
            }
            // Always clear popover/bubble so they rebuild with new provider title/placeholder
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }
    }

    @objc func resetSmartReminderCurrent() {
        AgentProvider.current.clearSmartReminderPreference()
        resetCharacterSessionsForPreferenceRefresh()
    }

    @objc func toggleClaudePowerMode(_ sender: NSMenuItem) {
        AgentProvider.claudePowerModeEnabled.toggle()
        sender.state = AgentProvider.claudePowerModeEnabled ? .on : .off
        resetCharacterSessionsForPreferenceRefresh()
    }

    @objc func toggleClaudeSaverMode(_ sender: NSMenuItem) {
        AgentProvider.claudeSaverModeEnabled.toggle()
        sender.state = AgentProvider.claudeSaverModeEnabled ? .on : .off
        refreshVisiblePopovers()
    }

    @objc func resetSmartReminderAll() {
        AgentProvider.clearAllSmartReminderPreferences()
        resetCharacterSessionsForPreferenceRefresh()
    }

    private func resetCharacterSessionsForPreferenceRefresh() {
        controller?.characters.forEach { char in
            char.session?.terminate()
            char.session = nil
            if char.isIdleForPopover {
                char.closePopover()
            }
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }
    }

    private func refreshVisiblePopovers() {
        controller?.characters.forEach { char in
            guard char.isIdleForPopover else { return }
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.createPopoverWindow()
            if let session = char.session, !session.history.isEmpty {
                char.terminalView?.replayHistory(session.history)
            }
            char.updatePopoverPosition()
            char.popoverWindow?.orderFrontRegardless()
            char.popoverWindow?.makeKey()
            if let terminal = char.terminalView {
                char.popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }
    }

    @objc func switchCharacterDisplay(_ sender: NSMenuItem) {
        guard let controller,
              let charIndex = sender.representedObject as? Int,
              charIndex >= 0,
              charIndex < controller.characters.count else { return }

        controller.characters[charIndex].preferredScreenIndex = sender.tag
        rebuildDisplayMenu()
    }

    @objc func autoSpreadDisplays() {
        controller?.characters.forEach { $0.preferredScreenIndex = -1 }
        rebuildDisplayMenu()
    }

    @objc func switchAgentSize(_ sender: NSMenuItem) {
        guard let preset = AgentSizePreset(rawValue: sender.tag) else { return }
        WalkerCharacter.sizePreset = preset
        rebuildSizeMenu()
        controller?.characters.forEach { $0.applyCurrentSize() }
        controller?.tick()
    }

    @objc func toggleChar1(_ sender: NSMenuItem) {
        guard let chars = controller?.characters, chars.count > 0 else { return }
        let char = chars[0]
        if char.isManuallyVisible {
            char.setManuallyVisible(false)
            sender.state = .off
        } else {
            char.setManuallyVisible(true)
            sender.state = .on
        }
    }

    @objc func toggleChar2(_ sender: NSMenuItem) {
        guard let chars = controller?.characters, chars.count > 1 else { return }
        let char = chars[1]
        if char.isManuallyVisible {
            char.setManuallyVisible(false)
            sender.state = .off
        } else {
            char.setManuallyVisible(true)
            sender.state = .on
        }
    }

    @objc func toggleDebug(_ sender: NSMenuItem) {
        guard let debugWin = controller?.debugWindow else { return }
        if debugWin.isVisible {
            debugWin.orderOut(nil)
            sender.state = .off
        } else {
            debugWin.orderFrontRegardless()
            sender.state = .on
        }
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == displayMenu {
            rebuildDisplayMenu()
        }
        if menu == sizeMenu {
            rebuildSizeMenu()
        }
    }
}
