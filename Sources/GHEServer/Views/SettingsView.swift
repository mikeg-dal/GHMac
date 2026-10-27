import SwiftUI
import GHEKit

/// Settings (⌘,): the `settings_server.ini` values, including the station location.
struct ServerSettingsView: View {
    @Bindable var model: ServerAppModel
    @State private var portText = ""
    @State private var maxText = ""
    @State private var latText = ""
    @State private var lonText = ""
    @State private var hideOnMinimize = MainWindowBehavior.hideOnMinimize

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Port") {
                    TextField("", text: $portText)
                        .frame(width: 90)
                        .onSubmit { applyPort() }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("settingsPort")
                }
                if model.isRunning {
                    Text("Stop the server to change the port.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Max connections") {
                    TextField("", text: $maxText)
                        .frame(width: 90)
                        .onSubmit { applyMax() }
                        .accessibilityIdentifier("settingsMaxConnections")
                }
                Toggle("Authenticate Users", isOn: $model.settings.authenticate)
                    .disabled(model.isRunning)
                    .help(model.isRunning ? "Stop the server to change this." : "")
            }
            Section("Station Location") {
                LabeledContent("Latitude") {
                    TextField("", text: $latText).frame(width: 110).onSubmit { applyLocation() }
                }
                LabeledContent("Longitude") {
                    TextField("", text: $lonText).frame(width: 110).onSubmit { applyLocation() }
                }
                Text("Decimal degrees. North is positive. Longitude is **west-positive** (enter east longitudes as negative), as stored in the settings file. Used only by the TO_DEC command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Window and Logging") {
                Toggle("Server Logging (ServerLog.txt)", isOn: $model.settings.serverLogging)
                Toggle("Minimize at Startup", isOn: $model.settings.serverMinimized)
                Toggle("Hide window to the menu bar when minimized", isOn: $hideOnMinimize)
                    .onChange(of: hideOnMinimize) { _, v in MainWindowBehavior.hideOnMinimize = v }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear(perform: load)
        .onDisappear { applyPort(); applyMax(); applyLocation() }
    }

    private func load() {
        portText = String(model.settings.port)
        maxText = String(model.settings.maxConnections)
        latText = JavaDouble.string(model.settings.lat)
        lonText = JavaDouble.string(model.settings.lon)
    }

    private func applyPort() {
        guard !model.isRunning else { portText = String(model.settings.port); return }
        if model.setPort(from: portText) != nil { portText = String(model.settings.port) }
    }

    private func applyMax() {
        if model.setMaxConnections(from: maxText) != nil { maxText = String(model.settings.maxConnections) }
    }

    private func applyLocation() {
        if let v = JavaDouble.parse(JavaString.trim(latText)), (-90...90).contains(v) { model.settings.lat = v }
        if let v = JavaDouble.parse(JavaString.trim(lonText)), (-180...180).contains(v) { model.settings.lon = v }
        latText = JavaDouble.string(model.settings.lat)
        lonText = JavaDouble.string(model.settings.lon)
    }
}
