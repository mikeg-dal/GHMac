import AppKit
import GHEKit
import GHEClientKit

/// A menu item that runs a closure and refreshes its check mark / enabled state each time its menu opens.
final class ActionItem: NSMenuItem {
    nonisolated(unsafe) var handler: @MainActor () -> Void = {}
    nonisolated(unsafe) var stateProvider: (@MainActor () -> Bool)?
    nonisolated(unsafe) var enabledProvider: (@MainActor () -> Bool)?
    nonisolated(unsafe) var titleProvider: (@MainActor () -> String)?

    override nonisolated init(title: String, action: Selector?, keyEquivalent: String) {
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    required nonisolated init(coder: NSCoder) { super.init(coder: coder) }

    convenience init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], id: String? = nil,
                     handler: @escaping @MainActor () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        self.handler = handler
        if let id { setAccessibilityIdentifier(id); identifier = NSUserInterfaceItemIdentifier(id) }
    }

    @objc func fire() { handler() }

    func refresh() {
        if let s = stateProvider { state = s() ? .on : .off }
        if let e = enabledProvider { isEnabled = e() }
        if let t = titleProvider { title = t() }
    }
}

/// Builds the menu tree. The same builders feed the main menu bar and the tray's menu strip.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let model: ClientAppModel
    let windows: WindowManager
    lazy var actions = ClientActions(model: model, windows: windows)

    init(model: ClientAppModel, windows: WindowManager) {
        self.model = model
        self.windows = windows
        super.init()
        windows.menuController = self
    }

    // MARK: Main menu

    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(AppInfo.clientName, appMenu()))
        main.addItem(submenuItem("File", fileMenu()))
        main.addItem(submenuItem("Configuration", configurationMenu()))
        main.addItem(submenuItem("Band", bandMenu()))
        let window = windowMenu()
        main.addItem(submenuItem("Window", window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenuItem("Help", help))
        NSApp.helpMenu = help
        return main
    }

    /// The four menus shown in the tray's strip (reachable while the app is inactive).
    func trayMenus() -> [(String, () -> NSMenu)] {
        [("File", fileMenu), ("Configuration", configurationMenu), ("Band", bandMenu), ("Help", helpMenu)]
    }

    private func appMenu() -> NSMenu {
        let m = menu(AppInfo.clientName)
        m.addItem(ActionItem("About \(AppInfo.clientName)", modifiers: []) { [actions] in actions.showAbout() })
        m.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let sm = NSMenu(title: "Services")
        services.submenu = sm
        NSApp.servicesMenu = sm
        m.addItem(services)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Hide \(AppInfo.clientName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        m.addItem(others)
        m.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit \(AppInfo.clientName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    func fileMenu() -> NSMenu {
        let m = menu("File")
        let lock = ActionItem("Lock Window Positions", modifiers: [], id: "menu.lockWindows") { [model] in model.windowsLocked.toggle() }
        lock.titleProvider = { [model] in model.windowsLocked ? "Unlock Window Positions" : "Lock Window Positions" }
        m.addItem(lock)
        m.addItem(ActionItem("Reset Window Positions", modifiers: []) { [windows] in windows.resetPositions() })
        m.addItem(.separator())
        // File ▸ Exit (Alt+F4); ⌘Q lives in the app menu.
        m.addItem(ActionItem("Exit", modifiers: []) { NSApp.terminate(nil) })
        return m
    }

    func configurationMenu() -> NSMenu {
        let m = menu("Configuration")
        let a = actions
        let s = model
        m.addItem(ActionItem("Servers...", modifiers: [], id: "menu.servers") { a.showServers() })

        // Rotors ▸
        let rotors = menu("Rotors")
        let display = menu("Rotor Display Configuration")
        display.addItem(ActionItem("Tray Configuration...", modifiers: [], id: "menu.trayConfig") { a.showTrayConfiguration() })
        display.addItem(ActionItem("Map Configuration...", modifiers: [], id: "menu.mapConfig") { a.showMapConfiguration() })
        rotors.addItem(submenuItem("Rotor Display Configuration", display))
        rotors.addItem(ActionItem("Set Rotor Step Size...", modifiers: []) { a.askStepSize() })
        rotors.addItem(.separator())
        rotors.addItem(ActionItem("Assign CCW keystroke...", modifiers: []) { a.assignActiveJogKey(clockwise: false) })
        rotors.addItem(ActionItem("Assign CW keystroke...", modifiers: []) { a.assignActiveJogKey(clockwise: true) })
        rotors.addItem(.separator())
        let global = ActionItem("Show Global Presets", modifiers: []) { s.settings.globalPresetsVisible.toggle() }
        global.stateProvider = { s.settings.globalPresetsVisible }
        rotors.addItem(global)
        let rsize = menu("Display Size")
        for (title, size) in [("Small", RotorDisplaySize.small), ("Medium", .medium), ("Large", .large)] {
            let i = ActionItem(title, modifiers: [], id: "menu.rotorSize.\(title)") { s.settings.rotorDisplaySize = size }
            i.stateProvider = { s.settings.rotorDisplaySize == size }
            rsize.addItem(i)
        }
        rotors.addItem(submenuItem("Display Size", rsize))
        m.addItem(submenuItem("Rotors", rotors))

        // Switches ▸
        let sw = menu("Switches")
        sw.addItem(ActionItem("Switch bands...", modifiers: []) { a.showSwitchConfiguration() })
        let drop = ActionItem("Show selection box on switches", modifiers: []) { s.settings.showDropOnSwitches.toggle() }
        drop.stateProvider = { s.settings.showDropOnSwitches }
        sw.addItem(drop)
        let hk = ActionItem("Show HOTKEYS on switches", modifiers: []) { s.settings.showHotkeysOnButtons.toggle() }
        hk.stateProvider = { s.settings.showHotkeysOnButtons }
        sw.addItem(hk)
        let ssize = menu("Display Size")
        for (title, size) in [("Small", SwitchDisplaySize.small), ("Medium", .medium), ("Large", .large)] {
            let i = ActionItem(title, modifiers: []) { s.settings.switchDisplaySize = size }
            i.stateProvider = { s.settings.switchDisplaySize == size }
            ssize.addItem(i)
        }
        sw.addItem(submenuItem("Display Size", ssize))
        let colors = menu("Global Button Color Default")
        for (title, c) in [("Green", SwitchGlobalColor.green), ("Black (Inverted)", .black), ("Red", .red), ("Cyan", .cyan)] {
            let i = ActionItem(title, modifiers: []) { s.settings.switchButtonColor = c }
            i.stateProvider = { s.settings.switchButtonColor == c }
            colors.addItem(i)
        }
        sw.addItem(submenuItem("Global Button Color Default", colors))
        m.addItem(submenuItem("Switches", sw))

        let scope = menu("Bands to Use")
        for sc in BandScope.allCases {
            let i = ActionItem(sc.title, modifiers: []) { s.settings.bandScope = sc }
            i.stateProvider = { s.settings.bandScope == sc }
            scope.addItem(i)
        }
        m.addItem(submenuItem("Bands to Use", scope))
        m.addItem(ActionItem("Set Default Background Image...", modifiers: []) { a.chooseDefaultSwitchImage() })
        m.addItem(ActionItem("Edit Presets...", modifiers: [], id: "menu.editPresets") { a.showPresetsEditor() })
        m.addItem(ActionItem("Restore Defaults...", modifiers: []) { a.restoreDefaults() })
        m.addItem(ActionItem("RSSI Test Window", modifiers: []) { a.showRSSI() })

        let soft = menu("Software Control")
        soft.addItem(ActionItem("N1MM Setup...", modifiers: []) { a.showN1MMSetup() })
        soft.addItem(ActionItem("N3FJP Setup...", modifiers: []) { a.showN3FJPSetup() })
        soft.addItem(ActionItem("Win-Test Setup...", modifiers: []) { a.showWinTestSetup() })
        soft.addItem(ActionItem("Test communication...", modifiers: []) { a.showSoftwareTest() })
        m.addItem(submenuItem("Software Control", soft))

        let hot = menu("Hotkeys")
        hot.addItem(ActionItem("View All HotKeys...", modifiers: [], id: "menu.viewHotkeys") { a.showHotkeys() })
        hot.addItem(ActionItem("Clear All Hotkeys...", modifiers: []) { a.confirmClearHotkeys() })
        hot.addItem(.separator())
        hot.addItem(ActionItem("Restart Hotkeys", modifiers: []) { s.restartHotkeys() })
        m.addItem(submenuItem("Hotkeys", hot))

        // The Sticky Port item exists only with the w2fu.txt flag file.
        if FileManager.default.fileExists(atPath: model.directories.file("w2fu.txt").path) {
            m.addItem(ActionItem("Sticky Port", modifiers: []) { a.showStickyPort() })
        }
        m.addItem(.separator())
        let top = ActionItem("Always On Top", modifiers: [], id: "menu.alwaysOnTop") { s.settings.alwaysOnTop.toggle() }
        top.stateProvider = { s.settings.alwaysOnTop }
        m.addItem(top)
        // Indicator only (SO2R second-radio instance is deferred).
        let so2r = ActionItem("2nd Radio - SO2R", modifiers: []) {}
        so2r.enabledProvider = { false }
        so2r.isEnabled = false
        m.addItem(so2r)
        return m
    }

    /// Band menu, rebuilt every time it opens (`populateBandList`).
    func bandMenu() -> NSMenu {
        let m = menu("Band")
        m.delegate = self
        m.identifier = NSUserInterfaceItemIdentifier("bandMenu")
        fillBandMenu(m)
        return m
    }

    private func fillBandMenu(_ m: NSMenu) {
        m.removeAllItems()
        let s = model
        for (title, src) in [("Auto - N1MM", LoggerSource.n1mm), ("Auto - N3FJP", .n3fjp), ("Auto - Win-Test", .wintest),
                             ("Use Manual Band Selection", .manual)] {
            let i = ActionItem(title, modifiers: [], id: "menu.band.mode.\(src.rawValue)") { s.setLoggerSource(src) }
            i.stateProvider = { s.settings.loggerSource == src }
            m.addItem(i)
        }
        m.addItem(.separator())
        for name in model.bandMenuNames {
            let i = ActionItem(name, modifiers: [], id: "menu.band.\(name)") { s.pickManualBand(name) }
            i.stateProvider = { s.settings.loggerSource == .manual && s.bands.a == name }
            i.enabledProvider = { s.settings.loggerSource == .manual }
            m.addItem(i)
        }
        refresh(m)
    }

    private func windowMenu() -> NSMenu {
        let m = menu("Window")
        m.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        m.addItem(.separator())
        m.addItem(ActionItem("Rotor Map", modifiers: [], id: "menu.rotorMap") { [windows] in windows.showMap() })
        m.addItem(ActionItem("Traffic Log", modifiers: [], id: "menu.traffic") { [actions] in actions.showTraffic() })
        m.addItem(.separator())
        return m
    }

    func helpMenu() -> NSMenu {
        let m = menu("Help")
        m.addItem(ActionItem("About", modifiers: []) { [actions] in actions.showAbout() })
        // The Help item opens the project page.
        m.addItem(ActionItem("\(AppInfo.clientName) Help", modifiers: []) {
            NSWorkspace.shared.open(AppInfo.projectURL)
        })
        return m
    }

    // MARK: Helpers

    private func menu(_ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        m.delegate = self
        return m
    }

    private func submenuItem(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    private func refresh(_ m: NSMenu) {
        for i in m.items { (i as? ActionItem)?.refresh() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "bandMenu" { fillBandMenu(menu) } else { refresh(menu) }
    }
}
