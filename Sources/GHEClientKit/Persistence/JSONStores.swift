import Foundation
import GHEKit

/// A Codable value in one JSON file.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Nil when the file is missing or unreadable.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(value), to: url)
    }
}

// MARK: - Presets

/// One global preset. The heading keeps the text the user typed ("330.5").
public struct RotorPreset: Sendable, Hashable, Codable {
    public var name: String
    public var heading: String
    public init(name: String, heading: String) { self.name = name; self.heading = heading }
    public var headingValue: Double? { JavaDouble.parse(heading) }
}

public enum RotorPresets {
    public static let maxCount = 16

    /// Like PresetsDialog OK: keep rows with a non-empty name and a heading that parses as a double,
    /// compacted, at most 16. (The editor UI validates and reports bad rows.)
    public static func sanitized(_ presets: [RotorPreset]) -> [RotorPreset] {
        Array(presets.filter { !$0.name.isEmpty && $0.headingValue != nil }.prefix(maxCount))
    }
}

/// `presets.json`: the global presets list.
public struct PresetStore: Sendable {
    let json: JSONFileStore<[RotorPreset]>
    public init(directory: AppDirectories) { json = JSONFileStore(url: directory.file(ClientFileName.presetsJSON)) }
    public var url: URL { json.url }
    public func load() -> [RotorPreset] { json.load() ?? [] }
    public func save(_ presets: [RotorPreset]) throws { try json.save(RotorPresets.sanitized(presets)) }
}

// MARK: - Hotkeys

/// `hotkeys.json` (common folder, shared by SO2R contexts), `HotkeyBindings` format.
public struct HotkeyStore: Sendable {
    public let url: URL
    public init(directory: AppDirectories) { url = directory.file(ClientFileName.hotkeysJSON) }

    public func load() -> HotkeyBindings {
        (try? Data(contentsOf: url)).flatMap { try? HotkeyBindings.fromJSON($0) } ?? HotkeyBindings()
    }

    public func save(_ bindings: HotkeyBindings) throws { try AtomicFile.write(try bindings.jsonData(), to: url) }
}

// MARK: - Switch windows

/// Background image choice of a switch window (missing key = default compass image,
/// key with null URL = no image).
public enum SwitchWindowImage: Sendable, Hashable, Codable {
    case none
    case file(path: String)
}

/// What `SwitchConfigManager` kept per switch (keyed by full switch name).
public struct SwitchWindowConfig: Sendable, Hashable, Codable {
    public var x: Int?, y: Int?
    public var width: Int?, height: Int?
    /// nil = the default image.
    public var image: SwitchWindowImage?
    /// Map beam colour 0xRRGGBB; nil = default.
    public var beamColor: UInt32?
    public var softwareControl: Bool?
    public var vfoA: Bool?
    public var vfoB: Bool?

    public init(x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil, image: SwitchWindowImage? = nil,
                beamColor: UInt32? = nil, softwareControl: Bool? = nil, vfoA: Bool? = nil, vfoB: Bool? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.image = image
        self.beamColor = beamColor; self.softwareControl = softwareControl; self.vfoA = vfoA; self.vfoB = vfoB
    }

    /// Unset flags read as true.
    public var isSoftwareControl: Bool { softwareControl ?? true }
    public var isVFOA: Bool { vfoA ?? true }
    public var isVFOB: Bool { vfoB ?? true }
}

public struct SwitchWindowsConfig: Sendable, Hashable, Codable {
    public var switches: [String: SwitchWindowConfig] = [:]
    public var lastImageDirectory: String?
    public var lastImage: String?
    public init(switches: [String: SwitchWindowConfig] = [:], lastImageDirectory: String? = nil, lastImage: String? = nil) {
        self.switches = switches; self.lastImageDirectory = lastImageDirectory; self.lastImage = lastImage
    }
}

/// `switchwindows.json`. Save it whenever a window moves or a setting changes.
public struct SwitchWindowStore: Sendable {
    let json: JSONFileStore<SwitchWindowsConfig>
    public init(directory: AppDirectories) { json = JSONFileStore(url: directory.file(ClientFileName.switchWindowsJSON)) }
    public var url: URL { json.url }
    public func load() -> SwitchWindowsConfig { json.load() ?? SwitchWindowsConfig() }
    public func save(_ config: SwitchWindowsConfig) throws { try json.save(config) }

    public func update(_ body: (inout SwitchWindowsConfig) -> Void) throws {
        var c = load()
        body(&c)
        try save(c)
    }
}
