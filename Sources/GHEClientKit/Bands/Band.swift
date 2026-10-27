import Foundation

/// An amateur band, named exactly like the band-table columns.
/// Raw values are the legacy strings used in `.ini` files and on the wire.
public enum Band: String, CaseIterable, Sendable, Hashable, Codable {
    case m160 = "160M", m80 = "80M", m60 = "60M", m40 = "40M", m30 = "30M", m20 = "20M"
    case m17 = "17M", m15 = "15M", m12 = "12M", m10 = "10M"
    case m6 = "50", m2 = "144", cm125 = "222", cm70 = "432", cm33 = "902"
    case g1_2 = "1.2G", g2_3 = "2.3G", g3_4 = "3.4G", g5_7 = "5.7G", g10 = "10G", g24 = "24G", g47 = "47G"

    /// The legacy name ("160M", "50", "1.2G").
    public var legacyName: String { rawValue }

    /// Lower band edges in kHz, ascending. The classifier is a `>=` cascade: the
    /// highest edge not above the frequency wins.
    // Lower edges only (29.9 MHz → 10M, 4.2 MHz → 80M); users rely on it.
    public static let lowerEdgesKHz: [(kHz: Double, band: Band)] = [
        (1_800, .m160), (3_500, .m80), (5_000, .m60), (7_000, .m40), (10_000, .m30),
        (14_000, .m20), (18_000, .m17), (21_000, .m15), (24_000, .m12), (28_000, .m10),
        (50_000, .m6), (144_000, .m2), (220_000, .cm125), (420_000, .cm70), (902_000, .cm33),
        (1_220_000, .g1_2), (2_300_000, .g2_3), (3_400_000, .g3_4), (5_660_000, .g5_7),
        (10_000_000, .g10), (24_000_000, .g24), (45_000_000, .g47),
    ]

    /// The band for a frequency in kHz, or nil for `"???"` (below 1800 kHz, NaN).
    public static func classify(kHz: Double) -> Band? {
        var result: Band?
        for edge in lowerEdgesKHz where edge.kHz <= kHz { result = edge.band }
        return result
    }

    /// The band for a frequency in MHz. Compares against `edge / 1000`, which is exactly
    /// the MHz constant the N3FJP table uses (1.8, 3.5 …).
    // The N3FJP table had 60 m at 5000.0 MHz; this uses the same table as N1MM.
    public static func classify(mhz: Double) -> Band? {
        var result: Band?
        for edge in lowerEdgesKHz where edge.kHz / 1000 <= mhz { result = edge.band }
        return result
    }

    /// Legacy string for an optional band: nil → `"???"`.
    public static func legacyString(_ band: Band?) -> String { band?.rawValue ?? Band.unknownName }

    /// The name for "no band".
    public static let unknownName = "???"
    /// The pseudo-band meaning "show everything".
    public static let allName = "ALL"
}

/// Which band columns the band tables and the Band menu show (`bandsScope` in settings.ini).
public enum BandScope: String, CaseIterable, Sendable, Hashable, Codable {
    case hfContest = "hfcontest"
    case hfAll = "hfall"
    case vhf = "vhf"

    /// The settings.ini value.
    public var settingsValue: String { rawValue }

    /// Parses the settings.ini value; unknown values fall back to the default (HF Contest).
    public init(settingsValue: String?) {
        self = settingsValue.flatMap { BandScope(rawValue: $0.lowercased()) } ?? .hfContest
    }

    public var title: String {
        switch self {
        case .hfContest: "HF Contest"
        case .hfAll: "HF All"
        case .vhf: "VHF"
        }
    }

    /// Band columns in display order. 60M only in HF All; "50" in every scope.
    public var columns: [Band] {
        switch self {
        case .hfContest: [.m160, .m80, .m40, .m20, .m15, .m10, .m6]
        case .hfAll: [.m160, .m80, .m60, .m40, .m30, .m20, .m17, .m15, .m12, .m10, .m6]
        case .vhf: [.m6, .m2, .cm125, .cm70, .cm33, .g1_2, .g2_3, .g3_4, .g5_7, .g10, .g24, .g47]
        }
    }
}
