import Foundation
import Synchronization

// In-memory transports for tests and simulator mode.

/// A `ByteTransport` whose other end is driven by a closure-based device (fakes) or by a test.
/// `deliver(_:)` pushes bytes "from the device"; writes go to `onWrite`.
public final class MemoryTransport: ByteTransport, @unchecked Sendable {
    private struct State {
        var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        var isOpen = false
        var writes: [[UInt8]] = []
        var opens = 0
    }
    private let state = Mutex(State())
    /// Called (outside the lock) for every write while open. Fake devices reply via `deliver`.
    public let onWrite: @Sendable ([UInt8]) -> Void
    /// If set, `open()` throws this.
    public let openError: (@Sendable () -> (any Error)?)

    public init(openError: @escaping @Sendable () -> (any Error)? = { nil },
                onWrite: @escaping @Sendable ([UInt8]) -> Void = { _ in }) {
        self.onWrite = onWrite
        self.openError = openError
    }

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        if let e = openError() { throw e }
        let (stream, c) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        let old = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            let old = s.continuation
            s.continuation = c; s.isOpen = true; s.opens += 1
            return old
        }
        old?.finish()
        return stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        let open = state.withLock { s -> Bool in
            guard s.isOpen else { return false }
            s.writes.append(bytes); return true
        }
        guard open else { throw TransportError.notOpen }
        onWrite(bytes)
    }

    public func close() async {
        let c = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            s.isOpen = false
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
    }

    /// Bytes arriving from the device side.
    public func deliver(_ bytes: [UInt8]) {
        let c = state.withLock { $0.continuation }
        c?.yield(bytes)
    }

    /// Simulates a cable pull / TCP reset.
    public func fail(_ error: any Error = TransportError.linkLost) {
        let c = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            s.isOpen = false
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish(throwing: error)
    }

    public var isOpen: Bool { state.withLock { $0.isOpen } }
    public var writes: [[UInt8]] { state.withLock { $0.writes } }
    public var openCount: Int { state.withLock { $0.opens } }
    public func clearWrites() { state.withLock { $0.writes.removeAll() } }
}

/// One end of an in-memory stream pair. Each `send` is delivered as ONE chunk to the
/// peer's `incoming`, which lets tests model TCP read boundaries exactly.
public final class MemoryStreamConnection: StreamConnection, @unchecked Sendable {
    public let peerAddress: String
    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let inContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let peer = Mutex<MemoryStreamConnection?>(nil)
    private let closed = Mutex(false)
    /// Every chunk this end has sent, in order.
    private let sentLog = Mutex<[[UInt8]]>([])

    init(peerAddress: String) {
        self.peerAddress = peerAddress
        (incoming, inContinuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
    }

    /// A connected pair: (client end, server end). `clientAddress` is what the server sees as the peer.
    public static func pair(clientAddress: String = "127.0.0.1", serverAddress: String = "127.0.0.1")
        -> (client: MemoryStreamConnection, server: MemoryStreamConnection) {
        let c = MemoryStreamConnection(peerAddress: serverAddress)
        let s = MemoryStreamConnection(peerAddress: clientAddress)
        c.peer.withLock { $0 = s }
        s.peer.withLock { $0 = c }
        return (c, s)
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !closed.withLock({ $0 }) else { throw TransportError.notOpen }
        sentLog.withLock { $0.append(bytes) }
        guard let p = peer.withLock({ $0 }), !p.closed.withLock({ $0 }) else { throw TransportError.linkLost }
        p.inContinuation.yield(bytes)
    }

    public func close() async {
        let was = closed.withLock { c -> Bool in defer { c = true }; return c }
        guard !was else { return }
        inContinuation.finish()
        let p = peer.withLock { $0 }
        p?.inContinuation.finish()   // peer sees EOF
    }

    /// Abort with an error on both ends (TCP reset).
    public func reset() {
        closed.withLock { $0 = true }
        inContinuation.finish(throwing: TransportError.linkLost)
        peer.withLock { $0 }?.inContinuation.finish(throwing: TransportError.linkLost)
    }

    public var sentChunks: [[UInt8]] { sentLog.withLock { $0 } }
    public var isClosed: Bool { closed.withLock { $0 } }
}

/// An in-memory listener: tests call `connect()` to get the client end of a new connection.
public final class MemoryListener: StreamListener, @unchecked Sendable {
    private let state = Mutex<AsyncStream<any StreamConnection>.Continuation?>(nil)
    public init() {}

    public func start() async throws -> AsyncStream<any StreamConnection> {
        let (stream, c) = AsyncStream<any StreamConnection>.makeStream()
        state.withLock { $0 = c }
        return stream
    }

    public func stop() async { state.withLock { c in c?.finish(); c = nil } }

    /// Opens a new connection; returns the client end. Throws if not listening.
    public func connect(from clientAddress: String = "127.0.0.1") throws -> MemoryStreamConnection {
        guard let c = state.withLock({ $0 }) else { throw TransportError.openFailed("not listening") }
        let (client, server) = MemoryStreamConnection.pair(clientAddress: clientAddress)
        c.yield(server)
        return client
    }

    public var isListening: Bool { state.withLock { $0 != nil } }
}

/// Connector that hands out ends of in-memory connections from a closure (client tests).
public struct MemoryConnector: StreamConnector {
    public let make: @Sendable (String, UInt16) async throws -> any StreamConnection
    public init(make: @escaping @Sendable (String, UInt16) async throws -> any StreamConnection) { self.make = make }
    public func connect(host: String, port: UInt16) async throws -> any StreamConnection { try await make(host, port) }
}

/// In-memory datagram source (logger tests).
public final class MemoryDatagramSource: DatagramSource, @unchecked Sendable {
    private let state = Mutex<AsyncStream<Datagram>.Continuation?>(nil)
    public init() {}
    public func datagrams() async throws -> AsyncStream<Datagram> {
        let (s, c) = AsyncStream<Datagram>.makeStream()
        state.withLock { $0 = c }
        return s
    }
    public func close() async { state.withLock { c in c?.finish(); c = nil } }
    public func inject(_ bytes: [UInt8], from source: String = "127.0.0.1:12060") {
        state.withLock { $0 }?.yield(Datagram(bytes: bytes, source: source))
    }
}
