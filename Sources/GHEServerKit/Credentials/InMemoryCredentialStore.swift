import Foundation

/// A credential store that lives only in memory (tests, simulator mode).
/// Same rules as the Keychain store: 32-byte hashes, user names of at least 3 characters.
public actor InMemoryCredentialStore: CredentialStore {
    private var hashes: [String: [UInt8]]
    private var master: [UInt8]?

    public init(users: [String: [UInt8]] = [:], masterHash: [UInt8]? = nil) {
        self.hashes = users
        self.master = masterHash
    }

    public func passwordHash(for user: String) async -> [UInt8]? { hashes[user] }

    /// Sorted.
    public func users() async -> [String] { hashes.keys.sorted() }

    /// Adding an existing user replaces the password.
    public func setUser(_ user: String, passwordHash: [UInt8]) async throws {
        if let p = CredentialValidation.validateUserName(user) { throw CredentialStoreError.invalidUserName(p) }
        guard passwordHash.count == CredentialValidation.hashLength else {
            throw CredentialStoreError.invalidHash(length: passwordHash.count)
        }
        hashes[user] = passwordHash
    }

    /// Removing an unknown user is not an error.
    public func removeUser(_ user: String) async throws { hashes[user] = nil }

    public func masterHash() async -> [UInt8]? { master }

    public func setMasterHash(_ hash: [UInt8]) async throws {
        guard hash.count == CredentialValidation.hashLength else {
            throw CredentialStoreError.invalidHash(length: hash.count)
        }
        master = hash
    }
}
