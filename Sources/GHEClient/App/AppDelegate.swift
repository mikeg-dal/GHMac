import AppKit
import GHEKit
import GHEClientKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: ClientAppModel!
    private(set) var windows: WindowManager!
    private(set) var menus: MenuController!
    private var isTerminating = false
    private var knobs: KnobBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isSimulatorLaunch && ClientAppModel.localControllerArgument == nil && anotherInstanceIsRunning {
            let a = NSAlert()
            a.messageText = "ERROR"
            a.informativeText = "\(AppInfo.clientName) is already running"
            a.alertStyle = .critical
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        model = ClientAppModel()
        windows = WindowManager(model: model)
        menus = MenuController(model: model, windows: windows)
        NSApp.mainMenu = menus.makeMainMenu()
        windows.start()
        model.start()
        knobs = KnobBridge.startIfAvailable(model: model)
        NSApp.activate()
        if model.isSimulator, let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-GHEOpenWindows"),
           i + 1 < ProcessInfo.processInfo.arguments.count {
            openForReview(ProcessInfo.processInfo.arguments[i + 1].split(separator: ",").map(String.init))
        }
    }

    /// Simulator only (`-GHEOpenWindows servers,trayConfig,…`): opens windows for layout review screenshots.
    private func openForReview(_ names: [String]) {
        let a = menus.actions
        for n in names {
            switch n {
            case "servers": a.showServers()
            case "trayConfig": a.showTrayConfiguration()
            case "mapConfig": a.showMapConfiguration()
            case "switchConfig": a.showSwitchConfiguration()
            case "presetsEditor": a.showPresetsEditor()
            case "hotkeys": a.showHotkeys()
            case "rssi": a.showRSSI()
            case "n1mm": a.showN1MMSetup()
            case "n3fjp": a.showN3FJPSetup()
            case "wintest": a.showWinTestSetup()
            case "softwareTest": a.showSoftwareTest()
            case "traffic": a.showTraffic()
            case "globalPresets": model.settings.globalPresetsVisible = true
            case "small": model.settings.rotorDisplaySize = .small
            case "large": model.settings.rotorDisplaySize = .large
            case "switchMedium": model.settings.switchDisplaySize = .medium
            default: break
            }
        }
    }

    private var isSimulatorLaunch: Bool { ProcessInfo.processInfo.arguments.contains("-GHESimulator") }

    private var anotherInstanceIsRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// Non-activating panels don't come forward with the app; raise them when the user activates it.
    func applicationDidBecomeActive(_ notification: Notification) {
        windows?.raiseOperatingPanels()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.raiseOperatingPanels()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// "Close GHMac Client?" with "DON'T ASK AGAIN!" (fastExit), then the shutdown sequence.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if isTerminating { return .terminateLater }
        if !model.settings.fastExit && !model.skipSaveOnQuit {
            let a = NSAlert()
            a.messageText = "Close GHMac Client"
            a.informativeText = "Close GHMac Client?"
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "DON'T ASK AGAIN!"
            NSApp.activate()
            let r = a.runModal()
            guard r == .alertFirstButtonReturn else { return .terminateCancel }
            if a.suppressionButton?.state == .on { model.settings.fastExit = true }
        }
        isTerminating = true
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
