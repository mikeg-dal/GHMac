import Foundation

/// A bidirectional byte pipe to a device: serial port, TCP socket, or an in-memory fake.
public protocol ByteTransport: AnyObject, Sendable {
    /// Opens the link and returns the stream of received bytes. The stream finishes
    /// normally on `close()` and with an error when the link is lost ("cable pull").
    func open() async throws -> AsyncThrowingStream<[UInt8], any Error>
    func write(_ bytes: [UInt8]) async throws
    func close() async
}

/// Modem status lines (serial only).
public struct ModemLines: Sendable, Equatable {
    public var cts: Bool
    public var dsr: Bool
    public var dcd: Bool
    public var ri: Bool
    public init(cts: Bool = false, dsr: Bool = false, dcd: Bool = false, ri: Bool = false) {
        self.cts = cts; self.dsr = dsr; self.dcd = dcd; self.ri = ri
    }
}

/// Transports that can report modem lines (serial ports, fakes).
public protocol ModemControl: Sendable {
    func modemLines() async throws -> ModemLines
}

public struct SerialSettings: Sendable, Hashable {
    public enum Flow: Sendable, Hashable { case none, rtsCts }
    public var baud: Int
    public var flow: Flow
    public var assertDTR: Bool
    public var assertRTS: Bool
    public init(baud: Int = 4800, flow: Flow = .none, assertDTR: Bool = true, assertRTS: Bool = true) {
        self.baud = baud; self.flow = flow; self.assertDTR = assertDTR; self.assertRTS = assertRTS
    }
    /// RT-21 / DCU-1 direct: 4800 8N1, no flow control.
    public static let rotor = SerialSettings(baud: 4800)
    /// Base XBee: 9600 8N1.
    public static let wioBase = SerialSettings(baud: 9600)
}

/// Where a device lives.
public enum Endpoint: Sendable, Hashable, CustomStringConvertible {
    case serial(path: String, SerialSettings)
    case tcp(host: String, port: UInt16)
    /// An in-process simulated device, resolved by a `TransportFactory`.
    case simulated(id: String)

    public var description: String {
        switch self {
        case .serial(let path, _): path
        case .tcp(let host, let port): "\(host):\(port)"
        case .simulated(let id): "SIM:\(id)"
        }
    }

    /// Key used for exclusive-use leases (one open link per physical endpoint).
    public var leaseKey: String {
        switch self {
        case .serial(let path, _): "serial:\(path)"
        case .tcp(let host, let port): "tcp:\(host.lowercased()):\(port)"
        case .simulated(let id): "sim:\(id)"
        }
    }
}

/// Builds transports for endpoints. The real factory makes serial/TCP transports; the
/// simulator factory maps `.simulated` (and chosen port names) to fake devices.
public protocol TransportFactory: Sendable {
    func make(_ endpoint: Endpoint) -> any ByteTransport
}

// MARK: - Stream server side

/// One accepted TCP connection (or an in-memory peer in tests).
public protocol StreamConnection: AnyObject, Sendable {
    /// Peer IP address as text (e.g. "192.168.1.20", "127.0.0.1").
    var peerAddress: String { get }
    /// Received bytes; finishes on EOF, throws on error.
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func send(_ bytes: [UInt8]) async throws
    func close() async
}

/// Accepts stream connections (TCP listener, or memory listener in tests).
public protocol StreamListener: AnyObject, Sendable {
    /// Starts listening; the stream yields each accepted connection.
    func start() async throws -> AsyncStream<any StreamConnection>
    func stop() async
}

/// Something that can open an outbound stream connection (client side).
public protocol StreamConnector: Sendable {
    func connect(host: String, port: UInt16) async throws -> any StreamConnection
}

// MARK: - Datagrams

public struct Datagram: Sendable, Equatable {
    public var bytes: [UInt8]
    /// Source address as text ("ip:port").
    public var source: String
    public init(bytes: [UInt8], source: String) { self.bytes = bytes; self.source = source }
}

/// A bound UDP receiver (or an in-memory source in tests).
public protocol DatagramSource: AnyObject, Sendable {
    func datagrams() async throws -> AsyncStream<Datagram>
    func close() async
}

public enum TransportError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case notOpen
    case writeFailed(String)
    case linkLost
    case endpointBusy(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let why): "Cannot open port (\(why))"
        case .notOpen: "The port isn't open."
        case .writeFailed(let why): "Write failed: \(why)"
        case .linkLost: "The connection was lost."
        case .endpointBusy(let who): "Already in use by \(who). Only one connection is allowed."
        case .unsupported(let what): "Not supported: \(what)"
        }
    }
}
