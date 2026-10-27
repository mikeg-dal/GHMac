import Foundation
import GHEKit

// Shared between devices, hub, persistence and server UI.

/// One heading report from a rotor driver (becomes a POINT on the wire).
public struct RotorReading: Sendable, Equatable {
    public var name: String
    public var heading: Double
    public var status: RotorStatus
    public var rssi: Int
    public init(name: String, heading: Double, status: RotorStatus, rssi: Int = 0) {
        self.name = name; self.heading = heading; self.status = status; self.rssi = rssi
    }
}

/// A rotor driver (RT-21, DCU-1, Fixed, Cloned, WIO rotor). Implementations are actors.
public protocol RotorDriver: Actor {
    nonisolated var name: String { get }
    /// Opens the device and starts polling. The stream ends when the driver closes or the link is lost.
    func start() async throws -> AsyncStream<RotorReading>
    func goTo(_ target: TurnTarget) async
    func stop() async
    /// One-off position query (GETHEAD, inventory).
    func query() async
    func close() async
}

/// Events from the device layer to the hub (and the server UI).
public enum RegistryEvent: Sendable, Equatable {
    case rotorAdded(String)
    case rotorRemoved(String)
    case reading(RotorReading)
    case switchAdded(SwitchDescriptor)
    case switchRemoved(String)
    case switchUpdated(name: String, state: String, status: Int, rssi: Int)
    /// For matrix-lockout switches: every locked switch's state.
    case switchLocks(name: String, states: [String])
    case stackAdded([String])
    case stackRemoved([String])
    case stackUpdated(names: [String], selected: [Bool], status: Int, rssi: Int)
    /// Human-readable line for the server log window.
    case log(String)
}

public enum SwitchCommandResult: Sendable, Equatable {
    case ok
    case lockedOut
    case unknownSwitch
}

/// Snapshot of everything currently "added" (for inventory bursts).
public struct RegistryInventory: Sendable, Equatable {
    public var rotors: [String] = []
    public var switches: [SwitchDescriptor] = []
    /// One entry per stack device: its antenna names.
    public var stacks: [[String]] = []
    public var lastReadings: [String: RotorReading] = [:]
    public init() {}
}

/// The device layer as seen by the hub. Commands are fire-and-forget (results arrive as events).
public protocol DeviceRegistryProtocol: Actor {
    func subscribe() -> AsyncStream<RegistryEvent>
    func inventory() -> RegistryInventory
    func turn(_ rotor: String, _ target: TurnTarget) async
    func stop(_ rotor: String) async
    func query(_ rotor: String) async
    func setStack(_ antenna: String, _ selected: Bool) async
    func setSwitch(_ name: String, _ position: String, _ on: Bool?) async -> SwitchCommandResult
}

// MARK: - Credentials

public protocol CredentialLookup: Sendable {
    /// Stored P = SHA-256(user ‖ password low bytes), or nil for an unknown user.
    func passwordHash(for user: String) async -> [UInt8]?
}

public protocol CredentialStore: CredentialLookup {
    func users() async -> [String]
    func setUser(_ user: String, passwordHash: [UInt8]) async throws
    func removeUser(_ user: String) async throws
    func masterHash() async -> [UInt8]?
    func setMasterHash(_ hash: [UInt8]) async throws
}

// MARK: - Device Manager (file format, runtime, UI)

/// Device types in the Device Manager. DCU-1 is shown to everyone (user decision).
public enum DeviceType: String, Sendable, CaseIterable, Hashable {
    case rt21 = "RT-21"
    case dcu1 = "DCU-1"
    case virtualSwitch = "Virtual Switch"
    case gheBase = "GHE Base"
    case fixedAntenna = "Fixed Antenna"
    case clonedAntenna = "Cloned Antenna"
}

/// One `<panel>` of DeviceManager.xml.
public struct DevicePanelConfig: Sendable, Equatable, Hashable {
    public static let fixedHeadingUnset = -123456.0
    public static let cloneOffsetUnset = -654321.0
    public static let notApplicable = "N/A"

    public var order: Int
    public var name: String
    public var port: String
    public var deviceType: String
    public var subType: String
    /// nil = "N/A".
    public var wioAddress: Int?
    public var basePTT: Bool
    public var initialState: Bool
    public var fixedHeading: Double?
    public var cloneOffset: Double?
    /// Attributes we don't model (e.g. `busAddress`), kept for round-trip.
    public var extraAttributes: [String: String]

    public init(order: Int, name: String = "", port: String = "N/A", deviceType: String = DeviceType.rt21.rawValue,
                subType: String = "N/A", wioAddress: Int? = nil, basePTT: Bool = false, initialState: Bool = false,
                fixedHeading: Double? = nil, cloneOffset: Double? = nil, extraAttributes: [String: String] = [:]) {
        self.order = order; self.name = name; self.port = port; self.deviceType = deviceType
        self.subType = subType; self.wioAddress = wioAddress; self.basePTT = basePTT
        self.initialState = initialState; self.fixedHeading = fixedHeading; self.cloneOffset = cloneOffset
        self.extraAttributes = extraAttributes
    }

    public var type: DeviceType? { DeviceType(rawValue: deviceType) }
    public var isEmpty: Bool { name.isEmpty }
}

/// Status button text of a Device Manager row.
public enum SlotStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case validating
    case connected
    case error(String)
    case retrying

    public var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .validating: "Validating"
        case .connected: "Connected"
        case .error: "Error"
        case .retrying: "Retrying"
        }
    }
}

/// How a port name in the Device Manager resolves to an endpoint (ports.ini TCP extension).
public protocol PortResolver: Sendable {
    /// Every selectable port name: "N/A", enumerated serial ports, ports.ini keys, simulated ports.
    func portNames() -> [String]
    /// nil for "N/A" or an unresolvable name.
    func endpoint(for portName: String, settings: SerialSettings) -> Endpoint?
}
