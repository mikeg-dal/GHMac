import Foundation
import CoreGraphics

public extension KeyName {
    /// Builds a key name with modifiers in canonical order (CTRL, ALT, SHIFT, WIN).
    /// Mac extension: several modifiers (`CTRL-SHIFT-F5`).
    static func make(_ modifiers: Set<KeyModifier>, _ base: String) -> KeyName {
        KeyName(modifiers: KeyModifier.allCases.filter(modifiers.contains), base: KeyCodeTable.canonicalName(base))
    }

    /// Parses a legacy string such as `F5`, `CTRL-NumPad1`, `ALT-F`, `CTRL-SHIFT-F5`.
    init?(legacy: String) {
        var parts = legacy.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
        var mods = Set<KeyModifier>()
        while parts.count > 1, let m = KeyModifier(rawValue: parts[0].uppercased()) {
            mods.insert(m); parts.removeFirst()
        }
        let base = parts.joined(separator: "-")
        guard !base.isEmpty, !base.contains(" ") else { return nil }
        self = .make(mods, base)
    }

    /// From a macOS key event.
    init?(keyCode: UInt16, carbonModifiers: UInt32) {
        guard let base = KeyCodeTable.name(for: keyCode) else { return nil }
        self = .make(KeyCodeTable.modifiers(carbon: carbonModifiers), base)
    }

    init?(keyCode: UInt16, cgFlags: CGEventFlags) {
        guard let base = KeyCodeTable.name(for: keyCode) else { return nil }
        self = .make(KeyCodeTable.modifiers(cgFlags: cgFlags), base)
    }

    /// Same key with modifiers in canonical order.
    var normalized: KeyName { .make(Set(modifiers), base) }

    /// Bare keys accepted without a modifier.
    static let legacyValidBareKeys: Set<String> = {
        var s = Set((1...24).map { "F\($0)" } + (0...9).map { "NumPad\($0)" })
        s.formUnion(["Add", "Subtract", "Multiply", "Divide", "Decimal",
                     "VolumeUp", "VolumeDown", "VolumeMute", "Play", "MediaStop", "MediaPlayPause",
                     "MediaNextTrack", "MediaPreviousTrack", "SelectMedia",
                     "LaunchApplication1", "LaunchApplication2", "LaunchMail",
                     "BrowserBack", "BrowserForward", "BrowserHome", "BrowserRefresh", "BrowserSearch", "BrowserStop"])
        return s
    }()

    /// In the bare-key list or has a modifier.
    var isValidHotkey: Bool { !modifiers.isEmpty || Self.legacyValidBareKeys.contains(base) }

    /// Option alone or Option+Shift: macOS 15+ `RegisterEventHotKey` refuses these.
    var isOptionOnlyCombination: Bool {
        let m = Set(modifiers)
        return m.contains(.alt) && m.isSubset(of: [.alt, .shift])
    }

    var macKeyCode: UInt16? { KeyCodeTable.keyCode(for: base) }

    /// Short caption for buttons: CTRL→Ct, SHIFT→Sh, ALT→Al, NumPad→Num, WIN→Wi, Decimal→Dec.
    var caption: String {
        legacyString.replacingOccurrences(of: "CTRL", with: "Ct").replacingOccurrences(of: "SHIFT", with: "Sh")
            .replacingOccurrences(of: "ALT", with: "Al").replacingOccurrences(of: "NumPad", with: "Num")
            .replacingOccurrences(of: "WIN", with: "Wi").replacingOccurrences(of: "Decimal", with: "Dec")
    }
}

/// What to do with a key pressed while the "Press key for …" sheet is up.
public enum HotkeyRegistration {
    public enum Outcome: Sendable, Equatable {
        case cancel
        case invalid(KeyName)
        case accept(KeyName)
    }

    public static func evaluate(_ key: KeyName) -> Outcome {
        if key.modifiers.isEmpty && key.base == "Escape" { return .cancel }
        return key.isValidHotkey ? .accept(key.normalized) : .invalid(key)
    }

    public static let invalidMessage = "is not a valid hotkey. Use F1–F20, the numeric keypad, or a key with a modifier."
}

/// Messages the legacy hotkey helper sent to the client. Only used when
/// reading old logs or bridging; the Mac engine is in-process.
public enum LegacyKeyhookMessage: Sendable, Equatable {
    case key(KeyName)
    case debug(String)
    case error(String)
    case hello

    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        if t.hasPrefix("DEBUG:") { self = .debug(String(t.dropFirst(6))) }
        else if t.hasPrefix("ERROR:") { self = .error(String(t.dropFirst(6))) }
        else if t == "HELLO" { self = .hello }
        else if let k = KeyName(legacy: t) { self = .key(k) }
        else { return nil }
    }
}
