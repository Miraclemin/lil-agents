import SwiftUI
import AppKit
import Sparkle
import UniformTypeIdentifiers

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
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // Per-character submenu state items (index 0 = Bruce, 1 = Jazz)
    var charVisibleItems:     [NSMenuItem] = []
    var charSizeLabelItems:   [NSMenuItem] = []
    var charOffsetLabelItems: [NSMenuItem] = []
    var charRemoveImageItems: [NSMenuItem] = []
    var charMirrorImageItems: [NSMenuItem] = []

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

        let charNames = ["Bruce", "Jazz"]
        let charKeys  = ["1", "2"]
        for idx in 0..<2 {
            let charItem = NSMenuItem(title: charNames[idx], action: nil, keyEquivalent: charKeys[idx])
            let charMenu = NSMenu()

            let visItem = NSMenuItem(title: "Visible", action: #selector(toggleCharVisibility(_:)), keyEquivalent: "")
            visItem.tag = idx
            visItem.state = .on
            charMenu.addItem(visItem)
            charVisibleItems.append(visItem)

            charMenu.addItem(.separator())

            let setImgItem = NSMenuItem(title: "Set Custom Image…", action: #selector(setCustomImage(_:)), keyEquivalent: "")
            setImgItem.tag = idx
            charMenu.addItem(setImgItem)

            let removeImgItem = NSMenuItem(title: "Remove Custom Image", action: #selector(removeCustomImage(_:)), keyEquivalent: "")
            removeImgItem.tag = idx
            removeImgItem.isEnabled = false
            charMenu.addItem(removeImgItem)
            charRemoveImageItems.append(removeImgItem)

            let mirrorItem = NSMenuItem(title: "Mirror Image (faces left by default)", action: #selector(charMirrorImage(_:)), keyEquivalent: "")
            mirrorItem.tag = idx
            mirrorItem.state = .off
            charMenu.addItem(mirrorItem)
            charMirrorImageItems.append(mirrorItem)

            charMenu.addItem(.separator())

            let sizeLabelItem = NSMenuItem(title: "Size: 0 pt", action: nil, keyEquivalent: "")
            sizeLabelItem.isEnabled = false
            charMenu.addItem(sizeLabelItem)
            charSizeLabelItems.append(sizeLabelItem)

            let largerItem = NSMenuItem(title: "Larger", action: #selector(charLarger(_:)), keyEquivalent: "")
            largerItem.tag = idx
            charMenu.addItem(largerItem)

            let smallerItem = NSMenuItem(title: "Smaller", action: #selector(charSmaller(_:)), keyEquivalent: "")
            smallerItem.tag = idx
            charMenu.addItem(smallerItem)

            charMenu.addItem(.separator())

            let offsetLabelItem = NSMenuItem(title: "Y Offset: 0 pt", action: nil, keyEquivalent: "")
            offsetLabelItem.isEnabled = false
            charMenu.addItem(offsetLabelItem)
            charOffsetLabelItems.append(offsetLabelItem)

            let moveUpItem = NSMenuItem(title: "Move Up", action: #selector(charMoveUp(_:)), keyEquivalent: "")
            moveUpItem.tag = idx
            charMenu.addItem(moveUpItem)

            let moveDownItem = NSMenuItem(title: "Move Down", action: #selector(charMoveDown(_:)), keyEquivalent: "")
            moveDownItem.tag = idx
            charMenu.addItem(moveDownItem)

            charMenu.addItem(.separator())

            let resetItem = NSMenuItem(title: "Reset Adjustments", action: #selector(charReset(_:)), keyEquivalent: "")
            resetItem.tag = idx
            charMenu.addItem(resetItem)

            charItem.submenu = charMenu
            menu.addItem(charItem)
        }

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
            item.state = provider == AgentProvider.current ? .on : .off
            providerMenu.addItem(item)
        }
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

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.delegate = self
        let autoItem = NSMenuItem(title: "Auto (Main Display)", action: #selector(switchDisplay(_:)), keyEquivalent: "")
        autoItem.tag = -1
        autoItem.state = .on
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(switchDisplay(_:)), keyEquivalent: "")
            item.tag = i
            item.state = .off
            displayMenu.addItem(item)
        }
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
                item.state = item.tag == idx ? .on : .off
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

    @objc func switchDisplay(_ sender: NSMenuItem) {
        let idx = sender.tag
        controller?.pinnedScreenIndex = idx

        if let displayMenu = sender.menu {
            for item in displayMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    // MARK: - Per-character actions

    private func character(at index: Int) -> WalkerCharacter? {
        guard let chars = controller?.characters, index < chars.count else { return nil }
        return chars[index]
    }

    @objc func toggleCharVisibility(_ sender: NSMenuItem) {
        guard let char = character(at: sender.tag) else { return }
        let nowVisible = !char.isManuallyVisible
        char.setManuallyVisible(nowVisible)
        sender.state = nowVisible ? .on : .off
    }

    @objc func setCustomImage(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a custom character image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.png, UTType.gif, UTType.jpeg]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            char.setCustomImage(url: url)
            if idx < (self?.charRemoveImageItems.count ?? 0) {
                self?.charRemoveImageItems[idx].isEnabled = true
            }
        }
    }

    @objc func removeCustomImage(_ sender: NSMenuItem) {
        guard let char = character(at: sender.tag) else { return }
        char.removeCustomImage()
        sender.isEnabled = false
    }

    @objc func charMirrorImage(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.mirrorImage.toggle()
        sender.state = char.mirrorImage ? .on : .off
        char.updateFlip()
        char.savePreferences()
    }

    @objc func charLarger(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.adjustSize(by: 10)
        if idx < charSizeLabelItems.count {
            charSizeLabelItems[idx].title = "Size: \(Int(char.sizeAdjust)) pt"
        }
    }

    @objc func charSmaller(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.adjustSize(by: -10)
        if idx < charSizeLabelItems.count {
            charSizeLabelItems[idx].title = "Size: \(Int(char.sizeAdjust)) pt"
        }
    }

    @objc func charMoveUp(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.adjustYOffsetExtra(by: 5)
        if idx < charOffsetLabelItems.count {
            charOffsetLabelItems[idx].title = "Y Offset: \(Int(char.yOffsetExtra)) pt"
        }
    }

    @objc func charMoveDown(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.adjustYOffsetExtra(by: -5)
        if idx < charOffsetLabelItems.count {
            charOffsetLabelItems[idx].title = "Y Offset: \(Int(char.yOffsetExtra)) pt"
        }
    }

    @objc func charReset(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard let char = character(at: idx) else { return }
        char.resetAdjustments()
        if idx < charSizeLabelItems.count   { charSizeLabelItems[idx].title   = "Size: 0 pt" }
        if idx < charOffsetLabelItems.count { charOffsetLabelItems[idx].title = "Y Offset: 0 pt" }
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

extension AppDelegate: NSMenuDelegate {}
