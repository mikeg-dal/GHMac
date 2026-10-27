import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

enum CredentialFixtures {
    /// (kind, name, hash) rows from test_credentials_expected.txt (JDK 8, test passwords only).
    static func expected() throws -> [(kind: String, name: String, hash: [UInt8])] {
        let text = String(decoding: try Fixtures.data("server/test_credentials_expected.txt"), as: UTF8.self)
        return text.split(separator: "\n").map { line in
            let f = line.split(separator: "\t").map(String.init)
            return (f[0], f[1], hex(f[2]))
        }
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func hash(_ seed: UInt8) -> [UInt8] { [UInt8](repeating: seed, count: 32) }
}

@Suite struct PasswordHashGoldenTests {
    /// The hashes agree with ones computed under Java 8, so existing clients can log in.
    @Test func hashesMatchGHAuth() throws {
        let rows = try CredentialFixtures.expected()
        let passwords = ["alice": "secret1", "bob": "hunter22", "W1AW-op": "pässwörd€"]
        for r in rows where r.kind == "user" {
            #expect(GHAuth.passwordHash(user: r.name, password: passwords[r.name]!) == r.hash, "\(r.name)")
        }
        #expect(GHAuth.masterHash("testmaster") == rows.first { $0.kind == "master" }?.hash)
    }
}

@Suite struct CredentialStoreTests {
    @Test func inMemorySemantics() async throws {
        let s = InMemoryCredentialStore()
        #expect(await s.users().isEmpty)
        #expect(await s.masterHash() == nil)
        try await s.setUser("zed", passwordHash: CredentialFixtures.hash(1))
        try await s.setUser("amy", passwordHash: CredentialFixtures.hash(2))
        try await s.setUser("zed", passwordHash: CredentialFixtures.hash(3)) // overwrite
        #expect(await s.users() == ["amy", "zed"])
        #expect(await s.passwordHash(for: "zed") == CredentialFixtures.hash(3))
        #expect(await s.passwordHash(for: "nobody") == nil)
        try await s.removeUser("amy")
        try await s.removeUser("amy")
        #expect(await s.users() == ["zed"])
        await #expect(throws: CredentialStoreError.invalidHash(length: 3)) { try await s.setUser("bob", passwordHash: [1, 2, 3]) }
        await #expect(throws: CredentialStoreError.invalidUserName(.userNameTooShort)) {
            try await s.setUser("ab", passwordHash: CredentialFixtures.hash(1))
        }
        await #expect(throws: CredentialStoreError.invalidHash(length: 0)) { try await s.setMasterHash([]) }
        try await s.setMasterHash(CredentialFixtures.hash(7))
        #expect(await s.masterHash() == CredentialFixtures.hash(7))
    }

    @Test func validationRules() {
        typealias V = CredentialValidation
        #expect(V.validateUserName("") == .userNameTooShort)
        #expect(V.validateUserName("ab") == .userNameTooShort)
        #expect(V.validateUserName(" abc") == .userNameHasSurroundingSpaces)
        #expect(V.validateUserName("abc") == nil)
        #expect(V.validatePassword("abcd", confirmation: "abcd") == .passwordTooShort)
        #expect(V.validatePassword("abcde", confirmation: "abcdf") == .passwordsDiffer)
        #expect(V.validatePassword("abcde", confirmation: "abcde") == nil)
        #expect(V.validateMasterPassword("abcde", confirmation: "x") == .masterPasswordsDiffer)
        #expect(V.validateMasterPassword("abc", confirmation: "abc") == .masterPasswordTooShort)
        #expect(V.Problem.passwordTooShort.description == "Passwords must be at least 5 characters long.")
    }

    /// Touches the real login keychain, so it only runs with GHE_KEYCHAIN_TESTS=1 (CI never prompts).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GHE_KEYCHAIN_TESTS"] == "1", "set GHE_KEYCHAIN_TESTS=1"))
    func keychainRoundTrip() async throws {
        let id = UUID().uuidString
        let store = KeychainCredentialStore(userService: "com.mikegarcia.GHMacServer.tests.users.\(id)",
                                            masterService: "com.mikegarcia.GHMacServer.tests.master.\(id)")
        defer { try? store.removeAll() }
        #expect(await store.users().isEmpty)
        try await store.setUser("alice", passwordHash: CredentialFixtures.hash(1))
        try await store.setUser("alice", passwordHash: CredentialFixtures.hash(2))
        try await store.setUser("bob", passwordHash: CredentialFixtures.hash(3))
        #expect(await store.users() == ["alice", "bob"])
        #expect(await store.passwordHash(for: "alice") == CredentialFixtures.hash(2))
        try await store.removeUser("alice")
        #expect(await store.passwordHash(for: "alice") == nil)
        try await store.setMasterHash(CredentialFixtures.hash(4))
        #expect(await store.masterHash() == CredentialFixtures.hash(4))
        await #expect(throws: CredentialStoreError.invalidHash(length: 1)) { try await store.setMasterHash([1]) }
    }
}
