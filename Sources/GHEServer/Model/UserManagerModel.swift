import Foundation
import Observation
import GHEKit
import GHEServerKit

/// Users/Passwords: the master-password gate, first-run master creation, and the User Manager
/// with Cancel/OK semantics (edits are staged and written only on OK).
@Observable
final class UserManagerModel {
    enum Phase: Equatable { case loading, locked, createMaster, unlocked }

    private(set) var phase: Phase = .loading
    /// Staged user list (sorted).
    private(set) var users: [String] = []
    var selection: String?
    private(set) var hasChanges = false
    @ObservationIgnored private var staged: [String: [UInt8]] = [:]
    @ObservationIgnored private var removed: Set<String> = []
    @ObservationIgnored let store: any CredentialStore

    init(store: any CredentialStore) { self.store = store }

    /// Called when the window opens: always starts locked (or asks to create a master password).
    func begin() async {
        reset()
        phase = await store.masterHash() == nil ? .createMaster : .locked
    }

    func lock() {
        reset()
        phase = .locked
    }

    private func reset() {
        users = []; selection = nil; staged = [:]; removed = []; hasChanges = false
    }

    // MARK: Master password

    /// "Enter Password:" → the User Manager, or "Incorrect Password".
    func unlock(_ password: String) async -> String? {
        guard let master = await store.masterHash(), GHAuth.masterHash(password) == master else {
            return "Incorrect Password"
        }
        users = await store.users().sorted()
        phase = .unlocked
        return nil
    }

    /// First use with no master password (Keychain empty): create one (≥5 characters, confirmed).
    func createMaster(_ password: String, confirm: String) async -> String? {
        if let p = CredentialValidation.validateMasterPassword(password, confirmation: confirm) { return p.description }
        do { try await store.setMasterHash(GHAuth.masterHash(password)) } catch { return "\(error)" }
        users = await store.users().sorted()
        phase = .unlocked
        return nil
    }

    // MARK: Staged edits

    /// Add User / Change Password. Names under 3 characters are refused.
    func setUser(_ name: String, password: String, confirm: String) -> String? {
        if let p = CredentialValidation.validateUserName(name) { return p.description }
        if let p = CredentialValidation.validatePassword(password, confirmation: confirm) { return p.description }
        staged[name] = GHAuth.passwordHash(user: name, password: password)
        removed.remove(name)
        if !users.contains(name) { users = (users + [name]).sorted() }
        selection = name
        hasChanges = true
        return nil
    }

    func remove(_ name: String) {
        staged[name] = nil
        removed.insert(name)
        users.removeAll { $0 == name }
        if selection == name { selection = nil }
        hasChanges = true
    }

    /// OK: writes the staged changes to the credential store.
    func commit() async -> String? {
        do {
            for name in removed { try await store.removeUser(name) }
            for (name, hash) in staged { try await store.setUser(name, passwordHash: hash) }
        } catch {
            return "\(error)"
        }
        staged = [:]; removed = []; hasChanges = false
        return nil
    }
}

/// Settings ▸ Users/Passwords ▸ Change Master Password. Saved to the credential
/// store with feedback; the app keeps running.
@Observable
final class ChangeMasterModel {
    enum Step: Equatable { case warning, current, new, done }
    var step: Step = .warning
    @ObservationIgnored let store: any CredentialStore

    init(store: any CredentialStore) { self.store = store }

    func restart() async {
        step = await store.masterHash() == nil ? .new : .warning
    }

    func verifyCurrent(_ password: String) async -> String? {
        guard let m = await store.masterHash(), GHAuth.masterHash(password) == m else { return "Incorrect Password" }
        step = .new
        return nil
    }

    func setNew(_ password: String, confirm: String) async -> String? {
        if let p = CredentialValidation.validateMasterPassword(password, confirmation: confirm) { return p.description }
        do { try await store.setMasterHash(GHAuth.masterHash(password)) } catch { return "\(error)" }
        step = .done
        return nil
    }
}
