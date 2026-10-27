import SwiftUI
import GHEKit
import GHEClientKit

/// Configuration ▸ Servers…: ten connection rows.
struct ServersView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var confirmDelete = false
    @State private var info: String?

    static let widths: [CGFloat] = [113, 51, 160, 74, 78, 114, 130, 125]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu("Password Options") {
                    Toggle("Save Passwords", isOn: Binding(get: { model.settings.savePasswords },
                                                           set: { model.settings.savePasswords = $0 }))
                    Button("Delete saved Passwords...") { confirmDelete = true }
                }
                .fixedSize()
                .accessibilityIdentifier("passwordOptions")
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(Array(["IP Address/Name", "Port", "Type", "Username", "Password", "Rotor Name", "Messages", ""].enumerated()),
                        id: \.offset) { i, t in
                    Text(t).font(.caption.bold()).frame(width: Self.widths[i], alignment: .leading)
                }
            }
            ForEach(model.connections.supervisors) { s in
                ServerRowView(supervisor: s)
            }
            HStack {
                Spacer()
                Button("Close") { model.windows?.closeConfig("serversWindow") }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .onDisappear { model.saveServerRows() }
        // Deleting saved passwords asks first.
        .confirmationDialog("Delete all saved passwords?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.passwords.deleteAll()
                info = "Passwords deleted."
            }
        }
        .alert(info ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
            Button("OK") {}
        }
    }
}

/// One Servers row (ServerSelectionPanel).
struct ServerRowView: View {
    @Environment(ClientAppModel.self) private var model
    @Bindable var supervisor: ConnectionSupervisor

    var body: some View {
        let w = ServersView.widths
        let editable = supervisor.controlsEnabled
        let isGH = supervisor.config.kind == .ghServer
        let id = "serverRow.\(supervisor.id)"
        HStack(spacing: 4) {
            Group {
            TextField("", text: $supervisor.config.address).frame(width: w[0])
                .accessibilityIdentifier("\(id).address")
            TextField("", text: $supervisor.config.port).frame(width: w[1])
                .accessibilityIdentifier("\(id).port")
            Picker("", selection: $supervisor.config.kind) {
                ForEach(ServerKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: w[2])
            TextField("", text: $supervisor.config.user).frame(width: w[3]).disabled(!isGH)
            SecureField("", text: $supervisor.config.password).frame(width: w[4]).disabled(!isGH)
            TextField("", text: $supervisor.config.rotorName).frame(width: w[5]).disabled(isGH)
            }
            .disabled(!editable)
            Text(supervisor.message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .frame(width: w[6], alignment: .leading)
                .help(supervisor.message)
                .accessibilityIdentifier("\(id).message")
            Button {
                supervisor.toggle()
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    model.saveServerRows()
                }
            } label: {
                HStack(spacing: 5) {
                    ConnectionLED(state: supervisor.state, hasError: !supervisor.message.isEmpty)
                    Text(supervisor.state.title).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: w[7])
            .accessibilityIdentifier("\(id).connect")
            .accessibilityValue(supervisor.state.title)
        }
        .textFieldStyle(.roundedBorder)
    }
}

/// The connection LED is shown (black off, green connected, orange connecting/retrying, red error).
struct ConnectionLED: View {
    let state: ConnectionState
    let hasError: Bool

    var color: Color {
        switch state {
        case .connected: .green
        case .connecting, .retrying, .disconnecting: .orange
        case .disconnected: hasError ? .red : Color(white: 0.2)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.black.opacity(0.3)))
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }
}
