import Foundation
import GHEKit

/// What is persisted per rotor. Band lists hold legacy tokens (`LegacyBandList`).
public struct RotorDeviceSettings: Sendable, Hashable {
    public var trayBands: [String]
    public var mapBands: [String]
    /// The tray "active" checkbox.
    public var active: Bool
    /// Tray order.
    public var priority: Int
    /// Map order.
    public var mapPriority: Int
    /// Map beam width in degrees.
    public var beamWidth: Int
    /// 0xRRGGBB, or nil for the global colour (`default`).
    public var color: UInt32?

    public init(trayBands: [String], mapBands: [String], active: Bool = false, priority: Int,
                mapPriority: Int, beamWidth: Int = RotorDeviceStore.defaultBeamWidth, color: UInt32? = nil) {
        self.trayBands = trayBands; self.mapBands = mapBands; self.active = active; self.priority = priority
        self.mapPriority = mapPriority; self.beamWidth = beamWidth; self.color = color
    }

    public func showsInTray(band: String) -> Bool { trayBands.contains(band) }
    public func showsOnMap(band: String) -> Bool { mapBands.contains(band) }
}

/// The seven per-rotor `.ini` files, keyed by the full rotor name (`ItemKey.legacyKey`,
/// `short\u{1E}:port`). Plain value type: every call reads/writes the files.
public struct RotorDeviceStore: Sendable {
    public static let defaultBeamWidth = 35

    public let directory: AppDirectories
    /// Priority for a rotor that has none yet: `round(random*500)+100`, i.e. 100…600.
    public var randomPriority: @Sendable () -> Int

    public init(directory: AppDirectories, randomPriority: @escaping @Sendable () -> Int = { Int.random(in: 100...600) }) {
        self.directory = directory
        self.randomPriority = randomPriority
    }

    var bandsFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorBands, comment: "File stores rotor names and bands for tray display:") }
    var mapBandsFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorMapBands, comment: "File stores rotor names and bands for map display:") }
    var statusFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorStatus, comment: "Rotor Options:Checked, Step size") }
    var priorityFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorPriority, comment: "File stores rotor priorities:") }
    // Read both `mappriority.ini` and `mapPriority.ini`, write `mappriority.ini`.
    var mapPriorityFile: MisnamedPropertiesFile {
        MisnamedPropertiesFile(directory: directory, canonical: ClientFileName.mapPriority,
                               legacy: ClientFileName.mapPriorityLegacy, legacyWins: false,
                               comment: "File stores rotor priorities for map display:")
    }
    var beamWidthFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorBeamWidth, comment: "File stores rotor beamwidths in deg:") }
    var colorsFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorColors, comment: "File stores rotor colors:") }

    public func load(_ item: ItemKey, scope: BandScope) -> RotorDeviceSettings { load(key: item.legacyKey, scope: scope) }

    /// Values with these defaults:
    /// - tray bands: missing file → HF ∪ VHF; missing key → the current scope's columns;
    /// - map bands: missing file → HF ∪ VHF; missing key → none;
    /// - priority: missing/invalid → random 100…600; map priority: missing → tray priority;
    /// - beam width 35; colour `default`; active false.
    public func load(key: String, scope: BandScope) -> RotorDeviceSettings {
        let trayBands: [String]
        if let p = bandsFile.read() {
            trayBands = p[key].map(LegacyBandList.decode) ?? LegacyBandList.array(for: scope)
        } else {
            trayBands = LegacyBandList.hfUnionVHF
        }
        let mapBands: [String]
        if let p = mapBandsFile.read() {
            mapBands = p[key].map(LegacyBandList.decode) ?? []
        } else {
            mapBands = LegacyBandList.hfUnionVHF
        }
        let active = statusFile.read()?[key] == "true"
        let priority = priorityFile.read()?[key].flatMap(JavaString.parseInt) ?? randomPriority()
        let mapPriority = mapPriorityFile.read()?[key].flatMap(JavaString.parseInt) ?? priority
        let beam = beamWidthFile.read()?[key].flatMap(JavaString.parseInt) ?? Self.defaultBeamWidth
        let color = LegacyColorCodec.decode(colorsFile.read()?[key])
        return RotorDeviceSettings(trayBands: trayBands, mapBands: mapBands, active: active, priority: priority,
                                   mapPriority: mapPriority, beamWidth: beam, color: color)
    }

    /// Load, then write everything back so defaults (e.g. the random
    /// priority) stick.
    public func loadOrCreate(key: String, scope: BandScope) throws -> RotorDeviceSettings {
        let s = load(key: key, scope: scope)
        try save(key: key, s)
        return s
    }

    public func save(_ item: ItemKey, _ s: RotorDeviceSettings) throws { try save(key: item.legacyKey, s) }

    /// Writes all seven files (load-modify-store, other rotors' keys kept).
    public func save(key: String, _ s: RotorDeviceSettings) throws {
        try bandsFile.update { $0[key] = LegacyBandList.encode(s.trayBands) }
        try mapBandsFile.update { $0[key] = LegacyBandList.encode(s.mapBands) }
        try statusFile.update { $0[key] = String(s.active) }
        try priorityFile.update { $0[key] = String(s.priority) }
        try mapPriorityFile.update { $0[key] = String(s.mapPriority) }
        try beamWidthFile.update { $0[key] = String(s.beamWidth) }
        try colorsFile.update { $0[key] = LegacyColorCodec.encode(s.color) }
    }
}
