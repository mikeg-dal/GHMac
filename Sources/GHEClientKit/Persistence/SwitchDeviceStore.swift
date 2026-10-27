import Foundation
import GHEKit

/// What is persisted per switch in `.ini` files.
public struct SwitchDeviceSettings: Sendable, Hashable {
    public var bands: [String]
    public var active: Bool
    /// Stored but unused by the UI.
    public var priority: Int

    public init(bands: [String], active: Bool = false, priority: Int) {
        self.bands = bands; self.active = active; self.priority = priority
    }

    public func shows(band: String) -> Bool { bands.contains(band) }
}

/// `switchbands.ini`, `switchstatus.ini`, `switchpriority.ini`, keyed by `ItemKey.legacyKey`.
public struct SwitchDeviceStore: Sendable {
    public let directory: AppDirectories
    public var randomPriority: @Sendable () -> Int

    public init(directory: AppDirectories, randomPriority: @escaping @Sendable () -> Int = { Int.random(in: 100...600) }) {
        self.directory = directory
        self.randomPriority = randomPriority
    }

    var bandsFile: PropertiesFile { PropertiesFile(directory, ClientFileName.switchBands, comment: "File stores switch names and bands:") }
    var priorityFile: PropertiesFile { PropertiesFile(directory, ClientFileName.switchPriority, comment: "File stores switch priorities:") }
    // `switchtatus.ini` (misspelled) and `switchstatus.ini` both exist. The
    // misspelled file holds what the user actually set, so its values win; we write `switchstatus.ini`.
    var statusFile: MisnamedPropertiesFile {
        MisnamedPropertiesFile(directory: directory, canonical: ClientFileName.switchStatus,
                               legacy: ClientFileName.switchStatusLegacy, legacyWins: true,
                               comment: "File stores switch status:")
    }

    public func load(_ item: ItemKey, scope: BandScope) -> SwitchDeviceSettings { load(key: item.legacyKey, scope: scope) }

    /// Defaults (SwitchModel.load*): bands missing file → HF ∪ VHF, missing key → scope columns;
    /// active false; priority random 100…600.
    public func load(key: String, scope: BandScope) -> SwitchDeviceSettings {
        let bands: [String]
        if let p = bandsFile.read() {
            bands = p[key].map(LegacyBandList.decode) ?? LegacyBandList.array(for: scope)
        } else {
            bands = LegacyBandList.hfUnionVHF
        }
        let active = statusFile.read()?[key] == "true"
        let priority = priorityFile.read()?[key].flatMap(JavaString.parseInt) ?? randomPriority()
        return SwitchDeviceSettings(bands: bands, active: active, priority: priority)
    }

    public func loadOrCreate(key: String, scope: BandScope) throws -> SwitchDeviceSettings {
        let s = load(key: key, scope: scope)
        try save(key: key, s)
        return s
    }

    public func save(_ item: ItemKey, _ s: SwitchDeviceSettings) throws { try save(key: item.legacyKey, s) }

    public func save(key: String, _ s: SwitchDeviceSettings) throws {
        try bandsFile.update { $0[key] = LegacyBandList.encode(s.bands) }
        try statusFile.update { $0[key] = String(s.active) }
        try priorityFile.update { $0[key] = String(s.priority) }
    }
}

/// Per-position switch button colours.
public enum SwitchButtonColor: String, CaseIterable, Sendable, Hashable, Codable {
    case cyan = "Cyan", red = "Red", orange = "Orange", yellow = "Yellow", green = "Green", black = "Black"
}

/// `buttoncolors.ini`: key `fullName\u{1F}position`, value a `SwitchButtonColor` name. No key = the
/// global switch colour ("Default").
public struct ButtonColorStore: Sendable {
    public let file: PropertiesFile

    public init(directory: AppDirectories) {
        file = PropertiesFile(directory, ClientFileName.buttonColors, comment: "File stores Switch Button Colors")
    }

    public static func key(switchKey: String, position: String) -> String { switchKey + "\u{1F}" + position }

    /// All colours; unknown values are ignored.
    public func load() -> [String: SwitchButtonColor] {
        var out: [String: SwitchButtonColor] = [:]
        let p = file.readOrEmpty()
        for k in p.keys { if let c = SwitchButtonColor(rawValue: p[k] ?? "") { out[k] = c } }
        return out
    }

    public func color(switchKey: String, position: String) -> SwitchButtonColor? {
        load()[Self.key(switchKey: switchKey, position: position)]
    }

    /// Sets (or with nil, removes = "Default") one colour and saves at once.
    public func set(_ color: SwitchButtonColor?, switchKey: String, position: String) throws {
        try file.update { $0[Self.key(switchKey: switchKey, position: position)] = color?.rawValue }
    }
}

/// `rotormap.ini` (map window) and `rotormapVisibility.ini` (per-rotor map checkboxes by short name).
public struct RotorMapSettings: Sendable, Hashable {
    /// Background image path.
    public var background: String?
    public var x = 0, y = 0, width = 500, height = 440

    public init(background: String? = nil, x: Int = 0, y: Int = 0, width: Int = 500, height: Int = 440) {
        self.background = background; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct RotorMapStore: Sendable {
    public let directory: AppDirectories

    public init(directory: AppDirectories) { self.directory = directory }

    var mapFile: PropertiesFile { PropertiesFile(directory, ClientFileName.rotorMap, comment: "Settings for rotor map") }
    var visibilityFile: PropertiesFile {
        PropertiesFile(directory, ClientFileName.rotorMapVisibility, comment: "Rotor visiblity ir rotor map display")
    }

    /// Missing background → nil; the caller uses `Images/compass.png` or the bundled compass.
    public func load() -> RotorMapSettings {
        let p = mapFile.readOrEmpty()
        return RotorMapSettings(background: p["background"], x: legacyInt(p["x"], default: 0), y: legacyInt(p["y"], default: 0),
                                width: legacyInt(p["width"], default: 500), height: legacyInt(p["height"], default: 440))
    }

    public func save(_ s: RotorMapSettings) throws {
        try mapFile.update { p in
            if let b = s.background { p["background"] = b }
            p["x"] = String(s.x); p["y"] = String(s.y)
            p["width"] = String(s.width); p["height"] = String(s.height)
        }
    }

    /// Whether a rotor (by short name) is ticked on the map; default true.
    public func isVisible(shortName: String) -> Bool {
        legacyBool(visibilityFile.read()?[shortName], default: true)
    }

    public func visibility() -> [String: Bool] {
        let p = visibilityFile.readOrEmpty()
        return Dictionary(uniqueKeysWithValues: p.keys.map { ($0, JavaString.parseBool(p[$0] ?? "")) })
    }

    public func setVisible(_ visible: Bool, shortName: String) throws {
        try visibilityFile.update { $0[shortName] = String(visible) }
    }
}
