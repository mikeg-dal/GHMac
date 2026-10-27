import Foundation
import GHEKit
import GHEServerKit

/// The WIO profiles used by the `-GHESimulator demo` scenario (one per display type, plus a virtual switch).
public enum DemoProfiles {
    public static let buttonsName = "Demo 6-Way"
    public static let bandName = "Demo Band Decoder"
    public static let mapName = "Demo 4-Square"
    public static let bankName = "Demo Preamps"
    public static let virtualName = "Demo Beam Selector"

    /// Pins for a binary code (pin i on when bit i is set), every other pin off.
    static func binary(_ code: Int) -> [Int8] { (0..<8).map { (code >> $0) & 1 == 1 ? 1 : 0 } }

    /// Buttons (SWITCH): six antennas, one relay each, plus OFF.
    public static let buttons = WioProfile(name: buttonsName, displayType: .buttons, positions:
        (1...6).map { WioProfile.Position.relay("Ant \($0)", onPins: [$0 - 1]) }
        + [WioProfile.Position(name: "OFF", pins: binary(0))])

    /// Band switch (BANDSWITCH): 160–10 m with their MHz ranges; binary-coded outputs.
    public static let band: WioProfile = {
        let bands: [(String, Double, Double)] = [
            ("160m", 1.8, 2.0), ("80m", 3.5, 4.0), ("60m", 5.3, 5.4), ("40m", 7.0, 7.3), ("30m", 10.1, 10.15),
            ("20m", 14.0, 14.35), ("17m", 18.068, 18.168), ("15m", 21.0, 21.45), ("12m", 24.89, 24.99),
            ("10m", 28.0, 29.7),
        ]
        return WioProfile(name: bandName, displayType: .band, positions: bands.enumerated().map { i, b in
            WioProfile.Position(name: b.0, lowerMHz: b.1, upperMHz: b.2, pins: binary(i + 1))
        })
    }()

    /// Map (HEADING): eight directions of a four-square plus omni.
    public static let map: WioProfile = {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        var positions = dirs.enumerated().map { i, d in
            WioProfile.Position(name: d, heading: i * 45, beamwidth: 60, pins: binary(i + 1))
        }
        positions.append(WioProfile.Position(name: "Omni", heading: 0, beamwidth: 360, pins: binary(9)))
        return WioProfile(name: mapName, displayType: .map, positions: positions)
    }()

    /// On/Off bank: independent relays.
    public static let bank = WioProfile(name: bankName, displayType: .bank, positions: [
        .relay("Preamp 1", onPins: [0]), .relay("Preamp 2", onPins: [1]),
        .relay("Bandpass", onPins: [2]), .relay("Attenuator", onPins: [3]),
    ])

    /// A virtual switch that points the 4-square and turns Tower 1.
    public static let virtual = WioProfile(name: virtualName, displayType: .buttons, virtualSwitch: true, positions: [
        WioProfile.Position(name: "Europe", virtualEntries: [
            .init(target: DemoScenario.Names.fourSquare, action: "NE"), .init(target: DemoScenario.Names.tower1, action: "#45"),
        ]),
        WioProfile.Position(name: "Japan", virtualEntries: [
            .init(target: DemoScenario.Names.fourSquare, action: "NW"), .init(target: DemoScenario.Names.tower1, action: "#330"),
        ]),
        WioProfile.Position(name: "Omni", virtualEntries: [
            .init(target: DemoScenario.Names.fourSquare, action: "Omni"),
        ]),
    ])

    public static let all: [WioProfile] = [buttons, band, map, bank, virtual]

    /// File name each profile is written to in a demo `wioProfiles/` folder.
    public static func fileName(for profile: WioProfile) -> String {
        profile.name.replacingOccurrences(of: " ", with: "") + ".xml"
    }
}
