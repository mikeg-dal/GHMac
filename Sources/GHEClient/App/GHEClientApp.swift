import AppKit

/// GHMac Client. AppKit lifecycle: every window is an NSPanel/NSWindow hosting SwiftUI, and the
/// menus are built in code so the tray's own menu strip can show the same menus.
@main
enum GHEClientApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
