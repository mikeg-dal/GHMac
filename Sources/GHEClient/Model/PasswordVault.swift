import Foundation
import Security

/// Saved server password hashes, kept in the Keychain.
/// Simulator mode keeps them in memory only.
@MainActor
final class PasswordVault {
    static let service = "com.mikegarcia.GHMacClient.userpass"
    private let inMemory: Bool
    private var memory: [String: [UInt8]] = [:]

    init(inMemory: Bool) { self.inMemory = inMemory }

    func hash(for user: String) -> [UInt8]? {
        if inMemory { return memory[user] }
        var query = baseQuery(user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return [UInt8](data)
    }

    func store(_ hash: [UInt8], for user: String) {
        if inMemory { memory[user] = hash; return }
        let q = baseQuery(user)
        let attrs = [kSecValueData as String: Data(hash)]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = Data(hash)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Password Options ▸ Delete saved Passwords…
    func deleteAll() {
        if inMemory { memory = [:]; return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        SecItemDelete(q as CFDictionary)
    }

    private func baseQuery(_ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: user]
    }
}
