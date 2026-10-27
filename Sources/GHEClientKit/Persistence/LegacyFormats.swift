import Foundation
import GHEKit

/// Band lists as stored: tokens each followed by one space ("160M 80M 50 ").
/// Tokens are kept as strings because the defaults include the table headers `Rotor`, `All`, `Order`.
public enum LegacyBandList {
    public static func decode(_ value: String) -> [String] {
        var seen = Set<String>()
        // Java `split(" ")`; empty tokens (from "" or double spaces) carry no meaning and are dropped.
        return JavaString.split(value, separator: " ").filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func encode(_ tokens: [String]) -> String {
        tokens.map { $0 + " " }.joined()
    }

    /// The band-table column arrays (headers included, as stored).
    public static let hfArray = ["Rotor", "All", "160M", "80M", "60M", "40M", "30M", "20M", "17M", "15M", "12M", "10M", "50", "Order"]
    public static let hfContestArray = ["Rotor", "All", "160M", "80M", "40M", "20M", "15M", "10M", "50", "Order"]
    public static let vhfArray = ["Rotor", "All", "50", "144", "222", "432", "902", "1.2G", "2.3G", "3.4G", "5.7G", "10G", "24G", "47G", "Order"]

    public static func array(for scope: BandScope) -> [String] {
        switch scope {
        case .hfContest: hfContestArray
        case .hfAll: hfArray
        case .vhf: vhfArray
        }
    }

    /// Default when the band file is missing: HF ∪ VHF .
    public static let hfUnionVHF: [String] = {
        var seen = Set<String>()
        return (hfArray + vhfArray).filter { seen.insert($0).inserted }
    }()

    /// The real bands in a token list, in band order.
    public static func bands(in tokens: [String]) -> [Band] {
        let set = Set(tokens)
        return Band.allCases.filter { set.contains($0.rawValue) }
    }
}

/// `rotorcolors.ini` values: `Integer.toString(color.getRGB(), 16)` (opaque colours are negative,
/// e.g. green → `-ff0100`) or `default`.
public enum LegacyColorCodec {
    public static let defaultValue = "default"

    /// `rgb` is 0xRRGGBB; nil writes `default`.
    public static func encode(_ rgb: UInt32?) -> String {
        guard let rgb else { return defaultValue }
        let argb = Int32(bitPattern: 0xFF00_0000 | (rgb & 0xFF_FFFF))
        return String(argb, radix: 16)
    }

    /// 0xRRGGBB, or nil for `default`, `null`, empty and unparsable values.
    public static func decode(_ value: String?) -> UInt32? {
        guard let value, !value.isEmpty, value != defaultValue, value != "null",
              let v = Int32(value, radix: 16) else { return nil }
        // `new Color(int)` ignores the alpha byte.
        return UInt32(bitPattern: v) & 0xFF_FFFF
    }
}

/// Integer parse with a fallback.
func legacyInt(_ value: String?, default defaultValue: Int) -> Int {
    value.flatMap(JavaString.parseInt) ?? defaultValue
}

/// `new Boolean(String)` / `Boolean.parseBoolean`: true iff "true" ignoring case.
func legacyBool(_ value: String?, default defaultValue: Bool) -> Bool {
    value.map(JavaString.parseBool) ?? defaultValue
}
