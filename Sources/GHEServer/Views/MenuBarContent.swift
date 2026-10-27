import SwiftUI
import GHEKit

/// The menu bar extra, replacing a tray icon: status, Show Window, Start/Stop,
/// the connected clients (the old click balloon) and Quit.
struct MenuBarContent: View {
    let model: ServerAppModel

    var body: some View {
        Text(model.isRunning ? "Server Running" : "Server stopped")
        Button("Show Window…") { model.showMainWindow() }
        Divider()
        Button("Start Server") { Task { await model.startServer() } }
            .disabled(model.isRunning)
        Button("Stop Server") { Task { await model.stopServer() } }
            .disabled(!model.isRunning)
        Divider()
        Text("\(model.clients.count) connection\(model.clients.count == 1 ? "" : "s")")
        ForEach(model.clients) { c in
            Text(c.user.map { "\(c.address)  (\($0))" } ?? c.address)
        }
        Divider()
        Button("Quit \(AppInfo.serverName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menu bar icon: an antenna, struck through while the server is stopped.
struct MenuBarLabel: View {
    let isRunning: Bool
    var body: some View {
        Image(systemName: isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
    }
}
