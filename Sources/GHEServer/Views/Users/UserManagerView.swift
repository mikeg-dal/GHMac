import SwiftUI
import GHEServerKit

/// The Users… window: master-password gate, then the User Manager (`PasswordManagerDialog`).
struct UserManagerView: View {
    @Bindable var model: UserManagerModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().frame(width: 360, height: 160)
            case .locked:
                PasswordGateView(title: "Master Password", message: "Enter Password:") { await model.unlock($0) }
            case .createMaster:
                NewPasswordForm(title: "Create Master Password",
                                message: "No master password is set. Create one to protect the user list (at least 5 characters).",
                                actionTitle: "Create") { await model.createMaster($0, confirm: $1) }
            case .unlocked:
                UserListView(model: model) { dismissWindow(id: SceneID.users) }
            }
        }
        .task { await model.begin() }
        .onDisappear { model.lock() }
    }
}

/// "Enter Password:" with OK/Cancel and "Incorrect Password" feedback.
struct PasswordGateView: View {
    let title: String
    let message: String
    let submit: (String) async -> String?
    @State private var password = ""
    @State private var error: String?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "lock").font(.headline)
            Text(message)
            SecureField("", text: $password)
                .frame(width: 260)
                .accessibilityIdentifier("masterPasswordField")
                .onSubmit { Task { await ok() } }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("passwordError") }
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow() }.keyboardShortcut(.cancelAction)
                Button("OK") { Task { await ok() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("masterPasswordOK")
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func ok() async {
        error = await submit(password)
        if error != nil { password = "" }
    }
}

/// New password + confirm, with feedback on a mismatch.
struct NewPasswordForm: View {
    let title: String
    let message: String
    let actionTitle: String
    let submit: (String, String) async -> String?
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "key").font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading) {
                GridRow {
                    Text("Enter New Password:")
                    SecureField("", text: $password).accessibilityIdentifier("newPasswordField")
                }
                GridRow {
                    Text("Confirm:")
                    SecureField("", text: $confirm).accessibilityIdentifier("confirmPasswordField")
                        .onSubmit { Task { await ok() } }
                }
            }
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("passwordError") }
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { Task { await ok() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newPasswordOK")
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func ok() async { error = await submit(password, confirm) }
}

/// User list with Add User… / Remove User / Change Password… and Cancel / OK.
struct UserListView: View {
    @Bindable var model: UserManagerModel
    let close: () -> Void
    @State private var editing: UserSheet?
    @State private var confirmRemove = false
    @State private var error: String?

    struct UserSheet: Identifiable {
        let name: String?
        var id: String { name ?? "<new>" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                List(model.users, id: \.self, selection: $model.selection) { u in
                    Text(u).accessibilityIdentifier("user.\(u)")
                }
                .frame(width: 220, height: 220)
                .accessibilityIdentifier("userList")
                VStack(alignment: .leading, spacing: 8) {
                    Button("Add User…") { editing = UserSheet(name: nil) }
                        .accessibilityIdentifier("addUser")
                    // Nothing to remove or change without a selection.
                    Button("Remove User") { confirmRemove = true }
                        .disabled(model.selection == nil)
                        .accessibilityIdentifier("removeUser")
                    Button("Change Password…") { editing = UserSheet(name: model.selection) }
                        .disabled(model.selection == nil)
                        .accessibilityIdentifier("changePassword")
                }
                .frame(width: 150, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if model.hasChanges { Text("Changes are saved when you click OK.").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK") {
                    Task {
                        error = await model.commit()
                        if error == nil { close() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("userManagerOK")
            }
        }
        .padding(20)
        .sheet(item: $editing) { s in
            UserPassSheet(fixedName: s.name) { model.setUser($0, password: $1, confirm: $2) }
        }
        .confirmationDialog("Are you sure you wish to remove \(model.selection ?? "")?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { if let s = model.selection { model.remove(s) } }
        }
    }
}

/// "Edit User/Pass" (`UserPassDialog`): Username, New Password, Confirm Password.
struct UserPassSheet: View {
    let fixedName: String?
    let submit: (String, String, String) -> String?
    @State private var name = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fixedName == nil ? "Add User" : "Change Password").font(.headline)
            Grid(alignment: .leading) {
                GridRow {
                    Text("Username:")
                    TextField("", text: $name).disabled(fixedName != nil).accessibilityIdentifier("userNameField")
                }
                GridRow {
                    Text("New Password:")
                    SecureField("", text: $password).accessibilityIdentifier("userPasswordField")
                }
                GridRow {
                    Text("Confirm Password:")
                    SecureField("", text: $confirm).accessibilityIdentifier("userConfirmField")
                        .onSubmit(ok)
                }
            }
            .frame(width: 340)
            Text("User names need at least 3 characters, passwords at least 5.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("userError") }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK", action: ok).keyboardShortcut(.defaultAction).accessibilityIdentifier("userOK")
            }
        }
        .padding(20)
        .onAppear { name = fixedName ?? "" }
    }

    private func ok() {
        if let e = submit(name, password, confirm) { error = e } else { dismiss() }
    }
}
