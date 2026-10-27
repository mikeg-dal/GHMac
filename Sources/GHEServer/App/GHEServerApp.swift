import SwiftUI
import GHEKit
import GHEServerKit
import GHESimKit

/// GHMac Server: the log window, Device Manager, WIO Profile Editor, Users/Passwords,
/// Settings and a menu bar extra in place of a tray icon.
@main
struct GHEServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ServerAppModel.shared
    @State private var users = UserManagerModel(store: ServerAppModel.shared.credentials)
    @State private var changeMaster = ChangeMasterModel(store: ServerAppModel.shared.credentials)

    var body: some Scene {
        Window(AppInfo.serverName, id: SceneID.main) {
            MainWindowView(model: model)
        }
        .defaultSize(width: 500, height: 200)
        .commands { ServerCommands(model: model) }

        Window("Device Manager", id: SceneID.deviceManager) {
            DeviceManagerView(dm: model.deviceManager) { model.wioEditors.openNew() }
        }
        .defaultSize(width: 840, height: 600)

        Window("User Manager", id: SceneID.users) {
            UserManagerView(model: users)
        }
        .windowResizability(.contentSize)

        Window("Change Master Password", id: SceneID.changeMaster) {
            ChangeMasterPasswordView(model: changeMaster)
        }
        .windowResizability(.contentSize)

        Settings {
            ServerSettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(isRunning: model.isRunning)
        }
    }
}

/// Menus in their Mac places: About in the app menu, logging in File, a Server menu
/// for the old Settings menu, and the Device Manager's Edit items.
struct ServerCommands: Commands {
    let model: ServerAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.serverName)") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: AppInfo.serverName,
                    .applicationVersion: AppInfo.version,
                    .credits: NSAttributedString(
                        string: "\(AppInfo.projectURL.absoluteString)\n\n\(AppInfo.disclaimer)",
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]),
                ])
            }
        }
        CommandGroup(replacing: .newItem) {
            Toggle("Server Logging", isOn: Binding(get: { model.settings.serverLogging },
                                                   set: { model.settings.serverLogging = $0 }))
            Toggle("Minimize at Startup", isOn: Binding(get: { model.settings.serverMinimized },
                                                        set: { model.settings.serverMinimized = $0 }))
            Divider()
            Button("Save Log…") { FilePanels.saveLog(model.log) }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Open WIO Profile…") { Task { await model.wioEditors.keyEditor?.openWithPanel() } }
                .keyboardShortcut("o")
            Button("Save WIO Profile") { Task { await model.wioEditors.keyEditor?.save() } }
                .keyboardShortcut("s")
            Button("Save WIO Profile As…") { Task { await model.wioEditors.keyEditor?.saveAs() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("WIO Profile Editor…") { model.wioEditors.openNew() }
            Button("Rescan Ports") { model.deviceManager.rescanPorts() }
        }
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { MainWindowBehavior.minimize(NSApp.keyWindow) }
                .keyboardShortcut("m")
            Button("Zoom") { NSApp.keyWindow?.performZoom(nil) }
        }
        CommandGroup(before: .windowList) {
            Button("Server Log") { model.showMainWindow() }
                .keyboardShortcut("0")
            Button("Device Manager") { openWindow(id: SceneID.deviceManager) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Server") {
            Button("Start Server…") { Task { await model.startServer() } }
                .disabled(model.isRunning)
            Button("Stop Server") { Task { await model.stopServer() } }
                .disabled(!model.isRunning)
            Divider()
            Button("Device Manager…") { openWindow(id: SceneID.deviceManager) }
            Divider()
            Button("Max Connections…") { model.ask(.maxConnections) }
            Button("Set Port…") { model.ask(.port) }
                .disabled(model.isRunning)
            Menu("Users/Passwords") {
                Button("Users…") { openWindow(id: SceneID.users) }
                Button("Change Master Password…") { openWindow(id: SceneID.changeMaster) }
                Toggle("Authenticate Users", isOn: Binding(get: { model.settings.authenticate },
                                                           set: { model.settings.authenticate = $0 }))
                    .disabled(model.isRunning)
            }
            Divider()
            Button("Launch Local Controller…") { model.launchLocalController() }
        }
    }
}
