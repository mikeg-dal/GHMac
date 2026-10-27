import Foundation
import GHEKit

// CONTRACT. Shared between connections, automation, persistence and the client UI.

/// Identity of one configured server connection.
public struct ServerID: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
    public var description: String { "\(host):\(port)" }
}

/// Identity of a rotor/switch/stack in the client. Keyed by host AND port;
/// `legacyKey` is the `<name>\u{1E}:<port>` form used in the settings files.
public struct ItemKey: Hashable, Sendable, CustomStringConvertible {
    public var server: ServerID
    public var name: String
    public init(server: ServerID, name: String) { self.server = server; self.name = name }
    public var legacyKey: String { name + "\u{1E}:" + String(server.port) }
    public var description: String { "\(name) @ \(server)" }
}

/// Connection type in the Servers dialog.
public enum ServerKind: Int, Sendable, Hashable, CaseIterable {
    case ghServer = 0
    case terminalServerTCP = 1
    public var title: String { self == .ghServer ? "GH Server" : "Terminal Server (TCP)" }
}

/// What a connection reports to its supervisor.
public enum ConnectionEvent: Sendable, Equatable {
    /// TCP connected (fires before authentication).
    case connected
    case message(ServerMessage)
    /// INVALID USER/PASS: do not retry.
    case invalidCredentials
    /// Server sent CLOSE.
    case closedByServer
    /// EOF, error, failed ping.
    case lost(String)
}

/// One outbound connection: a server or a direct RT-21 terminal server.
public protocol ServerConnection: Actor {
    nonisolated var id: ServerID { get }
    /// Connects; the stream ends after `.lost`/`.closedByServer`/`.invalidCredentials` or `disconnect()`.
    func connect() async throws -> AsyncStream<ConnectionEvent>
    /// Queues a command; order is preserved. Safe to call from any context.
    nonisolated func enqueue(_ command: ClientCommand)
    func disconnect() async
}

// MARK: - Bands

/// Band slot: A = VFO-A / radio 1, B = VFO-B / radio 2.
public enum BandSlot: Sendable, Hashable { case a, b }
public enum VFO: Sendable, Hashable { case a, b }

// MARK: - Loggers

public enum LoggerEvent: Sendable, Equatable {
    /// Band for a slot; nil = "???" (no band).
    case band(slot: BandSlot, band: String?)
    /// Frequency for band switches with that VFO box checked (MHz).
    case frequency(vfo: VFO, mhz: Double)
    /// Turn every active+visible rotor to this raw heading string.
    case turnActive(raw: String)
    case stopActive
    /// N1MM focus radio (SO2R gating).
    case focusRadio(Int)
    /// Raw packet text for the Software Control test window.
    case raw(String)
    case status(String)
}

public protocol LoggerMonitor: Actor {
    func start() async throws -> AsyncStream<LoggerEvent>
    func stop() async
}

// MARK: - Hotkeys

public enum KeyModifier: String, Sendable, Hashable, Codable, CaseIterable {
    case ctrl = "CTRL", alt = "ALT", shift = "SHIFT", win = "WIN"
}

/// A hotkey name ("F5", "CTRL-NumPad1", "ALT-F"). Mac extension: several modifiers.
public struct KeyName: Hashable, Codable, Sendable, CustomStringConvertible {
    public var modifiers: [KeyModifier]
    /// Key name, e.g. "F5", "NumPad1", "Add", "A".
    public var base: String
    public init(modifiers: [KeyModifier] = [], base: String) { self.modifiers = modifiers; self.base = base }
    public var legacyString: String { (modifiers.map { $0.rawValue + "-" }).joined() + base }
    public var description: String { legacyString }
}

public protocol HotkeyBackend: AnyObject {
    func register(_ key: KeyName) throws
    func unregister(_ key: KeyName)
    func unregisterAll()
    var onPress: ((KeyName) -> Void)? { get set }
}

// MARK: - Phidgets

public enum KnobEvent: Sendable, Equatable {
    case attached(serial: Int)
    case detached(serial: Int)
    case delta(serial: Int, Int)
    case button(serial: Int, pressed: Bool)
}

public protocol KnobService: Sendable {
    var isAvailable: Bool { get }
    func events() -> AsyncStream<KnobEvent>
}
