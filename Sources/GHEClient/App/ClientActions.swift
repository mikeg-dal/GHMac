import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GHEKit
import GHEClientKit

/// Menu commands that open windows or ask the user something.
@MainActor
final class ClientActions {
    let model: ClientAppModel
    let windows: WindowManager

    init(model: ClientAppModel, windows: WindowManager) {
        self.model = model
        self.windows = windows
    }

    // MARK: Panels

    func showServers() {
        windows.openConfig("serversWindow", title: "Servers") { ServersView() }
    }

    func showTrayConfiguration() {
        windows.openConfig("trayConfigWindow", title: "Rotors -- Tray Display", resizable: true, recreate: true,
                            size: bandTableSize(.tray)) {
            DeviceBandTableView(kind: .tray)
        }
    }

    func showMapConfiguration() {
        windows.openConfig("mapConfigWindow", title: "Rotors -- Map Display", resizable: true, recreate: true,
                            size: bandTableSize(.map)) {
            DeviceBandTableView(kind: .map)
        }
    }

    func showSwitchConfiguration() {
        windows.openConfig("switchConfigWindow", title: "Switch Configuration", resizable: true, recreate: true,
                            size: bandTableSize(.switches)) {
            DeviceBandTableView(kind: .switches)
        }
    }

    /// Wide enough for every column of the current band scope; tall enough for the rows (capped).
    private func bandTableSize(_ kind: DeviceBandTableView.Kind) -> NSSize {
        let cols = model.settings.bandScope.columns.count + 1 + (kind == .map ? 2 : kind == .tray ? 1 : 0)
        let rows = kind == .switches ? model.connections.switches.count + model.connections.tornados.count
            : model.connections.rotors.count
        return NSSize(width: 160 + CGFloat(cols) * 58, height: min(700, 150 + CGFloat(rows + 1) * 30))
    }

    func showPresetsEditor() {
        windows.openConfig("presetsEditorWindow", title: "Preset Locations", recreate: true) { PresetsEditorView() }
    }

    func showRSSI() {
        windows.openConfig("rssiWindow", title: "Device RSSI Test", resizable: true) { RSSITestView() }
    }

    func showN1MMSetup() {
        windows.openConfig("n1mmWindow", title: "N1MM Configuration", recreate: true) { N1MMConfigView() }
    }

    func showN3FJPSetup() {
        windows.openConfig("n3fjpWindow", title: "N3FJP Configuration", recreate: true) { N3FJPConfigView() }
    }

    func showWinTestSetup() {
        windows.openConfig("wintestWindow", title: "Win-Test Configuration", recreate: true) { WinTestConfigView() }
    }

    func showSoftwareTest() {
        windows.openConfig("softwareTestWindow", title: "Communication from control software:", resizable: true) {
            SoftwareTestView()
        }
    }

    func showHotkeys() {
        windows.openConfig("hotkeysWindow", title: "Global Hotkeys", resizable: true) { HotkeysView() }
    }

    func showTraffic() {
        windows.openConfig("trafficWindow", title: "Traffic Log", resizable: true) { TrafficLogView() }
    }

    func showStickyPort() {
        windows.openConfig("stickyPortWindow", title: "Sticky Port") { StickyPortView() }
    }

    func showAbout() {
        let credits = NSAttributedString(string: "\(AppInfo.projectURL.absoluteString)\n\n\(AppInfo.disclaimer)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.clientName,
            .applicationVersion: AppInfo.version,
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: credits,
        ])
    }

    // MARK: Questions

    /// Validated 1…180; Cancel keeps the old value.
    func askStepSize() {
        let field = NSTextField(string: String(model.settings.rotorStepSize))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        while true {
            let a = NSAlert()
            a.messageText = "New Rotor Step Size:"
            a.accessoryView = field
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if let v = JavaString.parseInt(JavaString.trim(field.stringValue)), (1...180).contains(v) {
                model.settings.rotorStepSize = v
                return
            }
            let e = NSAlert()
            e.messageText = "Step size must be a whole number from 1 to 180."
            e.runModal()
        }
    }

    func confirmClearHotkeys() {
        let a = NSAlert()
        a.messageText = "Clear All Hotkeys"
        a.informativeText = "Are you sure you want to clear all hotkeys?"
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { model.clearAllHotkeys() }
    }

    /// Rotors ▸ Assign CCW/CW keystroke…: the key jogs every active rotor.
    func assignActiveJogKey(clockwise: Bool) {
        let active = model.trayRotors.filter(\.isActive)
        guard !active.isEmpty else {
            let a = NSAlert()
            a.messageText = "No active rotors"
            a.informativeText = "Tick the box of each rotor the \(clockwise ? "CW" : "CCW") keystroke should jog."
            NSApp.activate()
            a.runModal()
            return
        }
        HotkeyCaptureController.capture(model: model, panel: "Active rotors", action: clockwise ? "CW" : "CCW") { [model] key in
            for r in active {
                if let err = model.bindHotkey(key, to: .rotor(r.key, clockwise ? .jogCW : .jogCCW)) { return err }
            }
            return nil
        }
    }

    /// Configuration ▸ Set Default Background Image… (map switches' default picture).
    func chooseDefaultSwitchImage() {
        guard let url = chooseImage(title: "Select default background image", prompt: "Set as background") else { return }
        model.switchWindowConfig.lastImage = url.path
        model.switchWindowConfig.lastImageDirectory = url.deletingLastPathComponent().path
        try? SwitchWindowStore(directory: model.directories).save(model.switchWindowConfig)
    }

    func chooseImage(title: String, prompt: String = "Open") -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = prompt
        p.allowedContentTypes = [.image]
        p.directoryURL = model.imagesDirectory.root
        NSApp.activate()
        return p.runModal() == .OK ? p.url : nil
    }

    /// Restore Defaults…: confirm, delete the settings files, quit.
    func restoreDefaults() {
        let a = NSAlert()
        a.messageText = "Confirm Reset"
        a.informativeText = "This will reset client to default settings. This \nincludes server names and addresses.  It will then close \nthe program.\n \nAre you sure you wish to do this?"
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.hotkeys.clear()
        RestoreDefaults.run(directory: model.directories)
        model.skipSaveOnQuit = true
        NSApp.terminate(nil)
    }
}
