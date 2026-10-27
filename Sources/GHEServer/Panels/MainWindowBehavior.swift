import AppKit

/// Main-window behaviour SwiftUI doesn't offer: minimise hides the window to the menu bar extra
/// and "Minimize at Startup" starts hidden.
@MainActor
enum MainWindowBehavior {
    static let hideOnMinimizeKey = "hideOnMinimize"
    private static var appliedStartupState = false

    static var hideOnMinimize: Bool {
        get { UserDefaults.standard.object(forKey: hideOnMinimizeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hideOnMinimizeKey) }
    }

    static func install(on window: NSWindow, model: ServerAppModel) {
        window.identifier = NSUserInterfaceItemIdentifier(SceneID.main)
        if let button = window.standardWindowButton(.miniaturizeButton) {
            button.target = MinimizeTarget.shared
            button.action = #selector(MinimizeTarget.minimize(_:))
        }
        if !appliedStartupState {
            appliedStartupState = true
            if model.settings.serverMinimized { DispatchQueue.main.async { window.orderOut(nil) } }
        }
    }

    /// ⌘M and the yellow button: hide the main window, or minimise any other window normally.
    static func minimize(_ window: NSWindow?) {
        guard let window else { return }
        if window.identifier?.rawValue == SceneID.main && hideOnMinimize {
            window.orderOut(nil)
        } else {
            window.miniaturize(nil)
        }
    }
}

@MainActor
final class MinimizeTarget: NSObject {
    static let shared = MinimizeTarget()
    @objc func minimize(_ sender: NSButton) { MainWindowBehavior.minimize(sender.window) }
}
