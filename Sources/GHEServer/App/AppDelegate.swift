import AppKit
import GHEKit
import GHESimKit

/// Single instance, the one shutdown path and the "keep running in the menu bar" behaviour.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second copy activates the first and quits.
        guard GHESimulator.requestedScenario == nil, let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let first = others.first {
            first.activate()
            exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ServerAppModel.shared.showMainWindow() }
        return true
    }

    /// Quit from the menu, the menu bar extra or the Dock all land here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        let skipConfirm = UserDefaults.standard.bool(forKey: "GHENoQuitConfirm")
        if !skipConfirm {
            let a = NSAlert()
            a.messageText = "Close Program"
            a.informativeText = "Are you sure you wish to close the Server?"
            a.addButton(withTitle: "Yes")
            a.addButton(withTitle: "No")
            NSApp.activate()
            guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminating = true
        Task {
            await ServerAppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
