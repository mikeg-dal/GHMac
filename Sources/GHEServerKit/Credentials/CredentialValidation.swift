import Foundation

/// Credential rules, enforced.
public enum CredentialValidation {
    public static let minimumUserNameLength = 3
    public static let minimumPasswordLength = 5
    /// SHA-256 digest length of every stored hash.
    public static let hashLength = 32

    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case userNameTooShort
        case userNameHasSurroundingSpaces
        case passwordTooShort
        case passwordsDiffer
        case masterPasswordTooShort
        case masterPasswordsDiffer

        public var description: String {
            switch self {
            case .userNameTooShort: "Username must be at least 3 characters long."
            case .userNameHasSurroundingSpaces: "Username must not start or end with a space."
            case .passwordTooShort: "Passwords must be at least 5 characters long."
            case .passwordsDiffer: "Passwords are not the same."
            case .masterPasswordTooShort: "Password must be at least 5 characters long."
            case .masterPasswordsDiffer: "Passwords are not the same."
            }
        }
    }

    /// Names under 3 characters (including empty) are rejected, not just warned about.
    /// Leading/trailing spaces are rejected because the server trims the login name.
    public static func validateUserName(_ name: String) -> Problem? {
        if name.count < minimumUserNameLength { return .userNameTooShort }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { return .userNameHasSurroundingSpaces }
        return nil
    }

    /// Checks a new user password and its confirmation ("same" first, then length).
    public static func validatePassword(_ password: String, confirmation: String) -> Problem? {
        if password != confirmation { return .passwordsDiffer }
        if password.count < minimumPasswordLength { return .passwordTooShort }
        return nil
    }

    /// A mismatch is reported instead of silently ignored.
    public static func validateMasterPassword(_ password: String, confirmation: String) -> Problem? {
        if password.count < minimumPasswordLength { return .masterPasswordTooShort }
        if password != confirmation { return .masterPasswordsDiffer }
        return nil
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A hash that isn't 32 bytes.
    case invalidHash(length: Int)
    case invalidUserName(CredentialValidation.Problem)
    /// A Keychain call failed (`OSStatus` and `SecCopyErrorMessageString` text).
    case keychain(status: Int32, message: String)

    public var description: String {
        switch self {
        case .invalidHash(let n): "A stored password hash must be 32 bytes, not \(n)."
        case .invalidUserName(let p): p.description
        case .keychain(let status, let message): "Keychain error \(status): \(message)"
        }
    }
}
