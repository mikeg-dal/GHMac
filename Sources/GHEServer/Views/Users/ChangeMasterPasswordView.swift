import SwiftUI

/// Change Master Password: warning → current password → new + confirm → done (no forced
/// quit).
struct ChangeMasterPasswordView: View {
    @Bindable var model: ChangeMasterModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch model.step {
            case .warning:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Change Master Password", systemImage: "exclamationmark.triangle").font(.headline)
                    Text("Changing the master password replaces the current one. This operation cannot be undone. Do you wish to proceed?")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("No") { dismissWindow() }.keyboardShortcut(.cancelAction)
                        Button("Yes") { model.step = .current }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 400)
            case .current:
                PasswordGateView(title: "Master Password", message: "Enter Password:") { await model.verifyCurrent($0) }
            case .new:
                NewPasswordForm(title: "New Master Password", message: "At least 5 characters.", actionTitle: "Create") {
                    await model.setNew($0, confirm: $1)
                }
            case .done:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Password changed.", systemImage: "checkmark.circle").font(.headline)
                    Text("The new master password is stored in your keychain.")
                    HStack { Spacer(); Button("OK") { dismissWindow() }.keyboardShortcut(.defaultAction) }
                }
                .padding(20)
                .frame(width: 360)
            }
        }
        .task { await model.restart() }
    }
}
