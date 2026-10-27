import Foundation
import Synchronization

/// The device side of a fake: decides whether a link may open and handles written bytes.
public protocol FakeSerialDevice: AnyObject, Sendable {
    /// Called by `open()`; throw to refuse the connection.
    func attach(_ link: FakeDeviceTransport) throws
    /// Called by `close()` (or when the device drops the link).
    func detach(_ link: FakeDeviceTransport)
    /// Bytes written by the host.
    func receive(_ bytes: [UInt8], from link: FakeDeviceTransport)
}

/// One host-side link to a fake device (a "serial port" or "TCP connection").
public final class FakeDeviceTransport: ByteTransport, ModemControl {
    public let device: any FakeSerialDevice
    private let continuation = Mutex<AsyncThrowingStream<[UInt8], any Error>.Continuation?>(nil)
    private let lines: Mutex<ModemLines>

    public init(device: any FakeSerialDevice, lines: ModemLines = ModemLines(cts: true, dsr: true)) {
        self.device = device
        self.lines = Mutex(lines)
    }

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        await close()
        try device.attach(self)
        let (stream, c) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        continuation.withLock { $0 = c }
        return stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard isOpen else { throw TransportError.notOpen }
        device.receive(bytes, from: self)
    }

    public func close() async {
        let c = continuation.withLock { c in defer { c = nil }; return c }
        guard let c else { return }
        c.finish()
        device.detach(self)
    }

    public func modemLines() async throws -> ModemLines { lines.withLock { $0 } }

    /// Changes the modem lines the host sees (CTS/DSR tests).
    public func setModemLines(_ l: ModemLines) { lines.withLock { $0 = l } }

    public var isOpen: Bool { continuation.withLock { $0 != nil } }

    /// Device → host bytes (ignored when closed).
    public func deliver(_ bytes: [UInt8]) {
        continuation.withLock { $0 }?.yield(bytes)
    }

    /// The device drops the link (power cycle, cable pull): the stream fails with `error`.
    public func drop(_ error: any Error = TransportError.linkLost) {
        let c = continuation.withLock { c in defer { c = nil }; return c }
        guard let c else { return }
        c.finish(throwing: error)
        device.detach(self)
    }
}

/// Adapts a `FakeDeviceTransport` to `StreamConnection` (fake network module for client code).
public final class FakeDeviceStreamConnection: StreamConnection {
    public let peerAddress: String
    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let link: FakeDeviceTransport

    init(link: FakeDeviceTransport, incoming: AsyncThrowingStream<[UInt8], any Error>, peerAddress: String) {
        self.link = link; self.incoming = incoming; self.peerAddress = peerAddress
    }

    public static func open(_ device: any FakeSerialDevice, peerAddress: String) async throws -> FakeDeviceStreamConnection {
        let link = FakeDeviceTransport(device: device)
        let stream = try await link.open()
        return FakeDeviceStreamConnection(link: link, incoming: stream, peerAddress: peerAddress)
    }

    public func send(_ bytes: [UInt8]) async throws { try await link.write(bytes) }
    public func close() async { await link.close() }
}
