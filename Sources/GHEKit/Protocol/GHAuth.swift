import CryptoKit
import Foundation
import Security

/// Authentication hashing. User and challenge bytes are CP1252;
/// password bytes are the low byte of each UTF-16 unit.
public enum GHAuth {
    /// P = SHA-256(user bytes ‖ low byte of each UTF-16 unit of password).
    public static func passwordHash(user: String, password: String) -> [UInt8] {
        sha256(Windows1252.encode(user) + lowBytes(password))
    }

    /// R = SHA-256(user bytes ‖ challenge bytes ‖ P).
    public static func response(user: String, challenge: String, passwordHash: [UInt8]) -> [UInt8] {
        sha256(Windows1252.encode(user) + Windows1252.encode(challenge) + passwordHash)
    }

    /// Master hash = SHA-256(low bytes ‖ low bytes) (password hashed twice in a row).
    public static func masterHash(_ password: String) -> [UInt8] {
        let b = lowBytes(password)
        return sha256(b + b)
    }

    /// A Java-looking challenge string from a secure random source:
    /// `0.<16 digits><signed long><epoch millis>`, like `"" + Math.random() + (nanoTime * millis) + millis`.
    public static func makeChallenge() -> String {
        let r = secureRandomBytes(24)
        var digits = ""
        for b in r.prefix(16) { digits += String(b % 10) }
        var long: UInt64 = 0
        for b in r[16..<24] { long = long << 8 | UInt64(b) }
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        return "0." + digits + String(Int64(bitPattern: long)) + String(millis)
    }

    /// `(byte) c` for each UTF-16 code unit.
    static func lowBytes(_ s: String) -> [UInt8] {
        s.utf16.map { UInt8(truncatingIfNeeded: $0) }
    }

    /// A fresh digest per call.
    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    private static func secureRandomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            var g = SystemRandomNumberGenerator() // also cryptographically secure on Darwin
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        }
        return bytes
    }
}
