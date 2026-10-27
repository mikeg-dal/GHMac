import Carbon.HIToolbox
import CoreGraphics

/// Key names ("F5", "NumPad1", "Add", …) ⇄ macOS virtual key codes.
public enum KeyCodeTable {
    /// Canonical name → key code. Every name here round-trips.
    public static let codes: [String: UInt16] = {
        var t: [String: UInt16] = [:]
        let letters: [(String, Int)] = [
            ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D), ("E", kVK_ANSI_E),
            ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H), ("I", kVK_ANSI_I), ("J", kVK_ANSI_J),
            ("K", kVK_ANSI_K), ("L", kVK_ANSI_L), ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O),
            ("P", kVK_ANSI_P), ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
            ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X), ("Y", kVK_ANSI_Y),
            ("Z", kVK_ANSI_Z),
        ]
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let pad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                   kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (n, c) in letters { t[n] = UInt16(c) }
        for (i, c) in digits.enumerated() { t["D\(i)"] = UInt16(c) }
        for (i, c) in pad.enumerated() { t["NumPad\(i)"] = UInt16(c) }
        for (i, c) in fkeys.enumerated() { t["F\(i + 1)"] = UInt16(c) }
        let others: [(String, Int)] = [
            ("Add", kVK_ANSI_KeypadPlus), ("Subtract", kVK_ANSI_KeypadMinus),
            ("Multiply", kVK_ANSI_KeypadMultiply), ("Divide", kVK_ANSI_KeypadDivide),
            ("Decimal", kVK_ANSI_KeypadDecimal),
            ("Left", kVK_LeftArrow), ("Right", kVK_RightArrow), ("Up", kVK_UpArrow), ("Down", kVK_DownArrow),
            ("Home", kVK_Home), ("End", kVK_End), ("PageUp", kVK_PageUp), ("PageDown", kVK_PageDown),
            ("Insert", kVK_Help), ("Delete", kVK_ForwardDelete), ("Escape", kVK_Escape),
            ("Back", kVK_Delete), ("Return", kVK_Return), ("Space", kVK_Space), ("Tab", kVK_Tab),
        ]
        for (n, c) in others { t[n] = UInt16(c) }
        return t
    }()

    /// Other names for the same keys (accepted on input only).
    public static let aliases: [String: String] = [
        "Prior": "PageUp", "Next": "PageDown", "Enter": "Return",
    ]

    /// Key code → canonical name.
    public static let names: [UInt16: String] = {
        var t: [UInt16: String] = [:]
        for (n, c) in codes { t[c] = n }
        t[UInt16(kVK_ANSI_KeypadEnter)] = "Return"
        return t
    }()

    /// Names that macOS `RegisterEventHotKey` cannot take
    /// (media/volume/browser/launch keys arrive as system-defined events; no F21–F24 on Macs).
    public static let unsupportedByRegisterEventHotKey: Set<String> = [
        "F21", "F22", "F23", "F24",
        "VolumeUp", "VolumeDown", "VolumeMute", "Play", "MediaStop", "MediaPlayPause",
        "MediaNextTrack", "MediaPreviousTrack", "SelectMedia",
        "LaunchApplication1", "LaunchApplication2", "LaunchMail",
        "BrowserBack", "BrowserForward", "BrowserHome", "BrowserRefresh", "BrowserSearch", "BrowserStop",
    ]

    public static func canonicalName(_ base: String) -> String { aliases[base] ?? base }

    public static func keyCode(for base: String) -> UInt16? { codes[canonicalName(base)] }
    public static func name(for keyCode: UInt16) -> String? { names[keyCode] }
    public static func isUnsupported(_ base: String) -> Bool {
        unsupportedByRegisterEventHotKey.contains(base) || keyCode(for: base) == nil
    }

    // MARK: Modifiers (⌃→CTRL, ⌥→ALT, ⇧→SHIFT, ⌘→WIN)

    public static func carbonModifiers(_ mods: some Sequence<KeyModifier>) -> UInt32 {
        var m: UInt32 = 0
        for mod in mods {
            switch mod {
            case .ctrl: m |= UInt32(controlKey)
            case .alt: m |= UInt32(optionKey)
            case .shift: m |= UInt32(shiftKey)
            case .win: m |= UInt32(cmdKey)
            }
        }
        return m
    }

    public static func modifiers(carbon m: UInt32) -> Set<KeyModifier> {
        var s = Set<KeyModifier>()
        if m & UInt32(controlKey) != 0 { s.insert(.ctrl) }
        if m & UInt32(optionKey) != 0 { s.insert(.alt) }
        if m & UInt32(shiftKey) != 0 { s.insert(.shift) }
        if m & UInt32(cmdKey) != 0 { s.insert(.win) }
        return s
    }

    public static func modifiers(cgFlags f: CGEventFlags) -> Set<KeyModifier> {
        var s = Set<KeyModifier>()
        if f.contains(.maskControl) { s.insert(.ctrl) }
        if f.contains(.maskAlternate) { s.insert(.alt) }
        if f.contains(.maskShift) { s.insert(.shift) }
        if f.contains(.maskCommand) { s.insert(.win) }
        return s
    }
}
