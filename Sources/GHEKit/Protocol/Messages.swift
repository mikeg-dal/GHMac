import Foundation

/// Field separators on the GH wire.
public enum GHSeparator {
    /// U+001F, between fields.
    public static let unit: Character = "\u{1F}"
    /// U+001D, between sub-fields of a SWITCHADD position entry.
    public static let group: Character = "\u{1D}"
    /// U+001E, client-internal key separator. Never sent on the wire.
    public static let record: Character = "\u{1E}"
    public static let crlf: [UInt8] = [0x0D, 0x0A]
}

/// Default GH server TCP port.
public let ghDefaultServerPort: UInt16 = 17220
/// Default maximum simultaneous clients.
public let ghDefaultMaxConnections = 4

/// Rotor status character in POINT field 3.
public enum RotorStatus: Character, Sendable, Hashable, CaseIterable {
    case ok = "0"
    case offline = "1"
    case stopped = "2"
    case turningCW = "3"
    case turningCCW = "4"
    case error = "5"
    case readOnly = "6"
    case fixed = "7"
    case clone = "8"
    case moving = "9"
}

/// Target of a TURN.
public enum TurnTarget: Sendable, Equatable, Hashable {
    case heading(Double)
    case cw
    case ccw
    /// Forwarded verbatim from an external source (N1MM, Win-Test).
    case raw(String)
}

/// Switch display type.
public enum SwitchDisplayType: Int, Sendable, Hashable {
    case buttons = 1
    case map = 2
    case band = 3
    case bank = 4
}

/// One position of a switch as announced in SWITCHADD.
public struct SwitchPosition: Sendable, Equatable, Hashable {
    public var name: String
    /// Types 1, 2, 4 (and unknown): heading/beamwidth ints and bidirectional flag.
    public var heading: Int
    public var beamwidth: Int
    public var bidirectional: Bool
    /// Type 3: frequency range in MHz.
    public var lowerMHz: Double
    public var upperMHz: Double

    public init(name: String, heading: Int = 0, beamwidth: Int = 0, bidirectional: Bool = false,
                lowerMHz: Double = 0, upperMHz: Double = 0) {
        self.name = name; self.heading = heading; self.beamwidth = beamwidth
        self.bidirectional = bidirectional; self.lowerMHz = lowerMHz; self.upperMHz = upperMHz
    }
}

public struct SwitchDescriptor: Sendable, Equatable, Hashable {
    public var name: String
    /// Raw display type int (may be outside `SwitchDisplayType`; unknown → small button switch).
    public var displayType: Int
    public var positions: [SwitchPosition]
    public init(name: String, displayType: Int, positions: [SwitchPosition]) {
        self.name = name; self.displayType = displayType; self.positions = positions
    }
    public var kind: SwitchDisplayType? { SwitchDisplayType(rawValue: displayType) }
}

/// Tornado tuner (client-understood only).
public struct TornadoDescriptor: Sendable, Equatable, Hashable {
    public var name: String
    public var rotors: [String]
    public var positions: [String]
    public var lower: [String]
    public var upper: [String]
    public init(name: String, rotors: [String], positions: [String], lower: [String], upper: [String]) {
        self.name = name; self.rotors = rotors; self.positions = positions; self.lower = lower; self.upper = upper
    }
}

public struct TornadoState: Sendable, Equatable, Hashable {
    public var name: String
    public var status: Int
    public var rssi: Int
    public var position: String
    public var headings: [String]
    public init(name: String, status: Int, rssi: Int, position: String, headings: [String]) {
        self.name = name; self.status = status; self.rssi = rssi; self.position = position; self.headings = headings
    }
}

/// Server → client message.
public enum ServerMessage: Sendable, Equatable {
    case user
    case pass(challenge: String)
    case invalidUserPass
    case close
    case add(String)
    case remove(String)
    case point(rotor: String, heading: Double, status: RotorStatus, rssi: Int)
    /// STACKADD: the stack device name is a comma list of antenna names.
    case stackAdd([String])
    case stackRemove([String])
    /// STACK: up to four antenna-selected booleans (always four on the wire).
    case stack(names: [String], selected: [Bool], status: Int, rssi: Int)
    case switchAdd(SwitchDescriptor)
    case switchRemove(String)
    /// state: position name, "UNKNOWN", or (bank) comma list / "NONE_SELECTED".
    case switchUpdate(name: String, state: String, status: Int, rssi: Int)
    case switchLocks(name: String, states: [String])
    /// LOCATIONS line. `[]` is sent as an empty line.
    case presetsLine(names: [String])
    case popup(String)
    case tornadoAdd(TornadoDescriptor)
    case tornadoRemove(String)
    case tornado(TornadoState)
    /// Anything unrecognised or malformed (kept for logging).
    case ignored(String)
}

/// Client → server command.
public enum ClientCommand: Sendable, Equatable {
    case turn(rotor: String, TurnTarget)
    case stop(rotor: String)
    case setStack(antenna: String, selected: Bool)
    /// `on` is present only for on/off bank panels.
    case setSwitch(name: String, position: String, on: Bool?)
    case toDec(rotor: String, lat: String, lon: String)
    case toPreset(rotor: String, preset: String)
    case lock(String)
    case unlock(String)
    case getHead(String)
    case getLocations
    case quit
    case restart
    case tornadoCal(tuner: String, rotor: String)
    case setTornado(tuner: String, position: String)
    case tornadoTurn(tuner: String, rotor: String, cw: Bool)
}
