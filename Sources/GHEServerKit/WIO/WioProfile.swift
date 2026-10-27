import Foundation
import GHEKit

/// A WIO switch profile (`wioProfiles/*.xml`). Plain value type.
public struct WioProfile: Sendable, Equatable, Hashable {
    /// One `<real name=… position=…/>` entry of a virtual-switch position.
    public struct VirtualEntry: Sendable, Equatable, Hashable {
        /// Target device: a switch name, or a rotor name for `#deg` actions.
        public var target: String
        /// `#<deg>` (turn rotor), `$<cmd>` (ignored) or a position of the target switch.
        public var action: String
        public init(target: String, action: String) { self.target = target; self.action = action }
    }

    public struct Position: Sendable, Equatable, Hashable {
        public var name: String
        public var heading: Int
        public var beamwidth: Int
        public var bidirectional: Bool
        public var lowerMHz: Double
        public var upperMHz: Double
        /// Pin states indexed by pin number (DIO0…DIO7): −1 don't care, 0 off, 1 on, 2 momentary.
        /// Empty for virtual positions.
        public var pins: [Int8]
        /// Virtual-switch entries (empty for real switches).
        public var virtualEntries: [VirtualEntry]

        public init(name: String, heading: Int = 0, beamwidth: Int = 0, bidirectional: Bool = false,
                    lowerMHz: Double = 0, upperMHz: Double = 0, pins: [Int8] = [],
                    virtualEntries: [VirtualEntry] = []) {
            self.name = name; self.heading = heading; self.beamwidth = beamwidth
            self.bidirectional = bidirectional; self.lowerMHz = lowerMHz; self.upperMHz = upperMHz
            self.pins = pins; self.virtualEntries = virtualEntries
        }

        /// Convenience: pins given as a "bit i on" mask, every other pin off.
        public static func relay(_ name: String, onPins: Set<Int>, heading: Int = 0) -> Position {
            Position(name: name, heading: heading, pins: (0..<8).map { onPins.contains($0) ? 1 : 0 })
        }
    }

    /// `<devicename>`: the subtype shown in the Device Manager.
    public var name: String
    public var displayType: SwitchDisplayType
    public var matrixLockout: Bool
    public var virtualSwitch: Bool
    public var positions: [Position]

    public init(name: String, displayType: SwitchDisplayType = .buttons, matrixLockout: Bool = false,
                virtualSwitch: Bool = false, positions: [Position] = []) {
        self.name = name; self.displayType = displayType; self.matrixLockout = matrixLockout
        self.virtualSwitch = virtualSwitch; self.positions = positions
    }

    public var positionNames: [String] { positions.map(\.name) }

    public func position(named n: String) -> Position? { positions.first { $0.name == n } }

    /// The position's pins padded to 8 entries; unknown position → all off.
    public func mask(for position: String) -> [Int8] {
        guard let p = self.position(named: position) else { return [Int8](repeating: 0, count: 8) }
        return p.pins
    }

    /// For ON/OFF banks: start from all −1, every pin that is `on`
    /// in any position becomes 0, then every pin `on` in a selected position becomes 1.
    public func bankMask(selected: [String]) -> [Int8] {
        var r = [Int8](repeating: -1, count: 8)
        for p in positions { for (i, v) in p.pins.prefix(8).enumerated() where v == 1 { r[i] = 0 } }
        for s in selected {
            for (i, v) in mask(for: s).prefix(8).enumerated() where v == 1 { r[i] = 1 }
        }
        return r
    }

    /// No pin is ever `on` (only momentary): the state becomes UNKNOWN once the pulse ends.
    public var isAllMomentary: Bool {
        if virtualSwitch { return false }
        return !positions.contains { $0.pins.contains(1) }
    }

    /// Pins used as momentary by any position.
    public var momentaryPins: Set<Int> {
        var s = Set<Int>()
        for p in positions { for (i, v) in p.pins.enumerated() where v == 2 && i < 8 { s.insert(i) } }
        return s
    }

    /// Virtual entries for a position, in document order.
    public func virtualEntries(for position: String) -> [VirtualEntry] {
        positions.filter { $0.name == position }.flatMap(\.virtualEntries)
    }

    /// The SWITCHADD descriptor for a device named `deviceName` using this profile.
    public func descriptor(deviceName: String) -> SwitchDescriptor {
        SwitchDescriptor(name: deviceName, displayType: displayType.rawValue, positions: positions.map {
            SwitchPosition(name: $0.name, heading: $0.heading, beamwidth: $0.beamwidth,
                           bidirectional: $0.bidirectional, lowerMHz: $0.lowerMHz, upperMHz: $0.upperMHz)
        })
    }
}

/// Looks up profiles by `<devicename>` (the Device Manager subtype).
public protocol WioProfileLookup: Sendable {
    func profile(named name: String) async -> WioProfile?
}

/// A fixed set of profiles (tests, simulator).
public struct StaticProfileLookup: WioProfileLookup {
    public var profiles: [String: WioProfile]
    public init(_ profiles: [WioProfile]) {
        self.profiles = Dictionary(profiles.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    }
    public func profile(named name: String) async -> WioProfile? { profiles[name] }
}

/// Saved switch positions (`switchstate<name>.properties`).
public protocol SwitchStatePersisting: Sendable {
    func loadState(forSwitch name: String) async -> String?
    func saveState(_ state: String, forSwitch name: String) async
}

/// Default store: keeps states in memory only.
public actor InMemorySwitchStateStore: SwitchStatePersisting {
    private var states: [String: String]
    public init(_ initial: [String: String] = [:]) { states = initial }
    public func loadState(forSwitch name: String) async -> String? { states[name] }
    public func saveState(_ state: String, forSwitch name: String) async { states[name] = state }
    public var all: [String: String] { states }
}
