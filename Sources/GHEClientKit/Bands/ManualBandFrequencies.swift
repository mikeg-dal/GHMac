import Foundation

/// Canonical frequency sent to band switches when a band is picked by hand.
/// Names match case-insensitively; "ALL"/unknown → 0.0.
public enum ManualBandFrequencies {
    /// kHz values.
    public static let kHz: [Band: Double] = [
        .m160: 1801, .m80: 3501, .m60: 5331, .m40: 7001, .m30: 10101, .m20: 14001,
        .m17: 18070, .m15: 21001, .m12: 24900, .m10: 28001, .m6: 50100, .m2: 144100,
        .cm125: 222100, .cm70: 432100, .cm33: 902100, .g1_2: 1296000, .g2_3: 2304000,
        .g3_4: 3456000, .g5_7: 5760000, .g10: 10000000, .g24: 24192000, .g47: 47088000,
    ]

    public static func mhz(for bandName: String) -> Double {
        guard let band = Band.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(bandName) == .orderedSame }),
              let k = kHz[band] else { return 0.0 }
        return k / 1000.0
    }

    /// Events for a manual pick from the Band menu: both slots get the pick, then VFO-A
    /// band switches get the canonical frequency.
    public static func events(forPick bandName: String) -> [LoggerEvent] {
        [.band(slot: .a, band: bandName), .band(slot: .b, band: bandName),
         .frequency(vfo: .a, mhz: mhz(for: bandName))]
    }
}
