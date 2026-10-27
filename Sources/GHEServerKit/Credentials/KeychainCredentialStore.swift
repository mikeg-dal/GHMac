import Foundation
import GHEKit
import Security

/// Server user accounts and the master hash in the macOS Keychain (no secrets in files).
///
/// Each user is a generic-password item: service `com.mikegarcia.GHMacServer.users`,
/// account = user name, data = the 32-byte P = SHA-256(user ‖ password low bytes). The master hash
/// is a separate item. Uses the file-based login keychain through SecItem (no keychain-access-group
/// entitlement needed); pass `useDataProtectionKeychain: true` to opt into the data-protection keychain.
///
/// The `CredentialLookup`/`CredentialStore` reads can't throw, so they log and return nil/[] on
/// failure; the `load…` variants surface the error.
public final class KeychainCredentialStore: CredentialStore {
    public static let defaultUserService = "com.mikegarcia.GHMacServer.users"
    public static let defaultMasterService = "com.mikegarcia.GHMacServer.master"
    static let masterAccount = "master"

    public let userService: String
    public let masterService: String
    public let useDataProtectionKeychain: Bool

    public init(userService: String = defaultUserService, masterService: String = defaultMasterService,
                useDataProtectionKeychain: Bool = false) {
        self.userService = userService
        self.masterService = masterService
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    // MARK: CredentialStore

    public func passwordHash(for user: String) async -> [UInt8]? {
        logging { try loadPasswordHash(for: user) } ?? nil
    }

    public func users() async -> [String] {
        logging { try loadUsers() } ?? []
    }

    public func setUser(_ user: String, passwordHash: [UInt8]) async throws {
        if let p = CredentialValidation.validateUserName(user) { throw CredentialStoreError.invalidUserName(p) }
        try store(passwordHash, service: userService, account: user, label: "GHMac Server user \(user)")
    }

    public func removeUser(_ user: String) async throws {
        try delete(service: userService, account: user)
    }

    public func masterHash() async -> [UInt8]? {
        logging { try loadMasterHash() } ?? nil
    }

    public func setMasterHash(_ hash: [UInt8]) async throws {
        try store(hash, service: masterService, account: Self.masterAccount, label: "GHMac Server master password")
    }

    // MARK: Throwing variants

    public func loadUsers() throws -> [String] {
        var q = baseQuery(service: userService)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public func loadPasswordHash(for user: String) throws -> [UInt8]? {
        try read(service: userService, account: user)
    }

    public func loadMasterHash() throws -> [UInt8]? {
        try read(service: masterService, account: Self.masterAccount)
    }

    /// Deletes every item this store owns (tests, "reset users").
    public func removeAll() throws {
        for service in [userService, masterService] {
            let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    // MARK: SecItem plumbing

    private func baseQuery(service: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private func read(service: String, account: String) throws -> [UInt8]? {
        var q = baseQuery(service: service)
        q[kSecAttrAccount as String] = account
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return [UInt8](data)
    }

    private func store(_ hash: [UInt8], service: String, account: String, label: String) throws {
        guard hash.count == CredentialValidation.hashLength else {
            throw CredentialStoreError.invalidHash(length: hash.count)
        }
        var q = baseQuery(service: service)
        q[kSecAttrAccount as String] = account
        let update: [String: Any] = [kSecValueData as String: Data(hash)]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            q[kSecValueData as String] = Data(hash)
            q[kSecAttrLabel as String] = label
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(q as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private func delete(service: String, account: String) throws {
        var q = baseQuery(service: service)
        q[kSecAttrAccount as String] = account
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        throw CredentialStoreError.keychain(status: status, message: message)
    }

    private func logging<T>(_ body: () throws -> T) -> T? {
        do { return try body() } catch {
            GHELog.devices.error("Keychain: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
