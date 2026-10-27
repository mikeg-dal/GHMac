import AppKit
import SwiftUI

/// The server window: status icon on top, the log in the middle and
/// `Port / Connections / Memory` along the bottom.
struct MainWindowView: View {
    @Bindable var model: ServerAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ServerStatusHeader(isRunning: model.isRunning)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            ServerLogView(log: model.log, revision: model.log.lastSequence)
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 6)
            ServerStatusBar(model: model)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(minWidth: 380, minHeight: 150)
        .background(WindowAccessor { window in
            guard model.mainWindow !== window else { return }
            model.mainWindow = window
            MainWindowBehavior.install(on: window, model: model)
        })
        .sheet(item: $model.mainPrompt) { prompt in
            switch prompt {
            case .maxConnections:
                ValuePromptSheet(title: "Max Connections",
                                 message: "Enter max number of simultaneous connections:",
                                 initial: String(model.settings.maxConnections),
                                 identifier: "maxConnectionsField") { model.setMaxConnections(from: $0) }
            case .port:
                ValuePromptSheet(title: "Set Port",
                                 message: "Enter port number for TCP/IP connection:",
                                 initial: String(model.settings.port),
                                 identifier: "portField") { model.setPort(from: $0) }
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .task {
            model.openWindow = { id in openWindow(id: id) }
            await model.boot()
        }
    }
}

/// Running / stopped icon with tooltips.
struct ServerStatusHeader: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "stop.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(isRunning ? Color.blue : Color.red)
                .help(isRunning ? "Server Running" : "Server stopped")
                .accessibilityIdentifier("serverStatus")
                .accessibilityLabel(isRunning ? "Server Running" : "Server stopped")
            Text(isRunning ? "Running" : "Stopped")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// `Port: n   Connections: cur/max   Memory: …`
struct ServerStatusBar: View {
    let model: ServerAppModel

    var body: some View {
        HStack(spacing: 18) {
            label("Port:", model.isSimulator ? "\(model.settings.port) (simulated)" : "\(model.settings.port)", id: "statusPort")
            label("Connections:", "\(model.clients.count)/\(model.settings.maxConnections)", id: "statusConnections")
                .help("current/max")
            label("Memory:", model.memoryText, id: "statusMemory")
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func label(_ title: String, _ value: String, id: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .accessibilityIdentifier(id)
        }
    }
}

/// A one-field input sheet with inline validation.
struct ValuePromptSheet: View {
    let title: String
    let message: String
    let identifier: String
    /// Returns an error message, or nil when the value was accepted.
    let submit: (String) -> String?
    @State private var text: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, message: String, initial: String, identifier: String, submit: @escaping (String) -> String?) {
        self.title = title; self.message = message; self.identifier = identifier; self.submit = submit
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(message)
            TextField("", text: $text)
                .frame(width: 260)
                .accessibilityIdentifier(identifier)
                .onSubmit(ok)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).accessibilityIdentifier("promptError")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: ok).keyboardShortcut(.defaultAction).accessibilityIdentifier("promptOK")
            }
        }
        .padding(20)
    }

    private func ok() {
        if let e = submit(text) { error = e } else { dismiss() }
    }
}

/// Hands the hosting `NSWindow` to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in if let w = v?.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { onWindow(w) }
    }
}
