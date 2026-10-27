import Foundation

/// Rotor hotkey commands (RotorKeyCommand).
public enum RotorHotkeyCommand: String, CaseIterable, Sendable, Hashable, Codable {
    case presetTurnCCW = "PRESET_TURN_CCW", presetTurnCW = "PRESET_TURN_CW"
    case executeTurn = "EXECUTE_TURN", executeStop = "EXECUTE_STOP"
    case jogCCW = "JOG_CCW", jogCW = "JOG_CW"
    /// Legacy, not auto-registered: `TURN US name US CW/CCW` with a 500 ms lockout.
    case turnCCW = "TURN_CCW", turnCW = "TURN_CW"
}

/// What a hotkey drives. Panels are named by the legacy key `<name>\u{1E}:<port>`;
/// `host` (Mac addition) disambiguates two servers on the same port when known.
public enum HotkeyTarget: Sendable, Hashable, Codable {
    case rotor(panel: String, host: String?, command: RotorHotkeyCommand)
    /// `position` is a position name or `CYCLE_FORWARD` / `CYCLE_BACKWARD`.
    case switchPosition(panel: String, host: String?, position: String)
    /// Stack-match widget, by stack name.
    case stack(name: String)

    public static let cycleForward = "CYCLE_FORWARD"
    public static let cycleBackward = "CYCLE_BACKWARD"

    public static func rotor(_ item: ItemKey, _ command: RotorHotkeyCommand) -> HotkeyTarget {
        .rotor(panel: item.legacyKey, host: item.server.host, command: command)
    }
    public static func switchPosition(_ item: ItemKey, _ position: String) -> HotkeyTarget {
        .switchPosition(panel: item.legacyKey, host: item.server.host, position: position)
    }

    /// Whether this target belongs to the given panel. A nil host matches any server.
    public func refers(to item: ItemKey) -> Bool {
        switch self {
        case .rotor(let p, let h, _), .switchPosition(let p, let h, _):
            p == item.legacyKey && (h == nil || h == item.server.host)
        case .stack: false
        }
    }

    private enum CodingKeys: String, CodingKey { case type, panel, host, cmd, position, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "rotor":
            self = .rotor(panel: try c.decode(String.self, forKey: .panel),
                          host: try c.decodeIfPresent(String.self, forKey: .host),
                          command: try c.decode(RotorHotkeyCommand.self, forKey: .cmd))
        case "switch":
            self = .switchPosition(panel: try c.decode(String.self, forKey: .panel),
                                   host: try c.decodeIfPresent(String.self, forKey: .host),
                                   position: try c.decode(String.self, forKey: .position))
        case "stack":
            self = .stack(name: try c.decode(String.self, forKey: .name))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown hotkey target \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rotor(let p, let h, let cmd):
            try c.encode("rotor", forKey: .type); try c.encode(p, forKey: .panel)
            try c.encodeIfPresent(h, forKey: .host); try c.encode(cmd, forKey: .cmd)
        case .switchPosition(let p, let h, let pos):
            try c.encode("switch", forKey: .type); try c.encode(p, forKey: .panel)
            try c.encodeIfPresent(h, forKey: .host); try c.encode(pos, forKey: .position)
        case .stack(let n):
            try c.encode("stack", forKey: .type); try c.encode(n, forKey: .name)
        }
    }

    /// Stable ordering for dispatch and JSON output.
    var sortKey: String {
        switch self {
        case .rotor(let p, let h, let c): "0\(p)\(h ?? "")\(c.rawValue)"
        case .switchPosition(let p, let h, let pos): "1\(p)\(h ?? "")\(pos)"
        case .stack(let n): "2\(n)"
        }
    }
}

/// Key → targets. One key can drive several targets; one target has at most one key.
/// Encodes as JSON `{ "F5": [ {"type":"rotor", …} ] }` (hotkeys.json).
public struct HotkeyBindings: Sendable, Hashable, Codable {
    public private(set) var map: [KeyName: Set<HotkeyTarget>] = [:]

    public init() {}

    public var keys: [KeyName] { map.keys.sorted { $0.legacyString < $1.legacyString } }
    public var isEmpty: Bool { map.isEmpty }

    public func targets(for key: KeyName) -> [HotkeyTarget] {
        (map[key.normalized] ?? []).sorted { $0.sortKey < $1.sortKey }
    }

    public func key(for target: HotkeyTarget) -> KeyName? {
        map.first { $0.value.contains(target) }?.key
    }

    /// Binds `target` to `key`, removing the target's previous binding.
    public mutating func bind(_ target: HotkeyTarget, to key: KeyName) {
        unbind(target)
        map[key.normalized, default: []].insert(target)
    }

    /// Removes the target's binding; returns the key it had.
    @discardableResult
    public mutating func unbind(_ target: HotkeyTarget) -> KeyName? {
        guard let k = key(for: target) else { return nil }
        map[k]?.remove(target)
        if map[k]?.isEmpty == true { map[k] = nil }
        return k
    }

    public mutating func removeKey(_ key: KeyName) { map[key.normalized] = nil }
    public mutating func clear() { map.removeAll() }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: [HotkeyTarget]].self)
        for (k, targets) in raw {
            guard let key = KeyName(legacy: k) else { continue }
            for t in targets { bind(t, to: key) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var raw: [String: [HotkeyTarget]] = [:]
        for k in keys { raw[k.legacyString] = targets(for: k) }
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> HotkeyBindings {
        try JSONDecoder().decode(HotkeyBindings.self, from: data)
    }
}
