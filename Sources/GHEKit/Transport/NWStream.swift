import Foundation
import Network
import Synchronization

/// A TCP connection (accepted or outbound) as a `StreamConnection`. Each received chunk
/// is yielded as-is; EOF finishes `incoming`, an error finishes it with `linkLost`.
public final class NWStreamConnection: StreamConnection {
    public let peerAddress: String
    public let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let closed = Mutex(false)

    /// Wraps `connection`; starts it if it isn't started yet.
    init(_ connection: NWConnection, peerAddress: String, queue: DispatchQueue, start: Bool) {
        self.connection = connection
        self.peerAddress = peerAddress
        self.queue = queue
        (incoming, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        let cont = continuation
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: cont.finish(throwing: TransportError.linkLost)
            default: break
            }
        }
        if start { connection.start(queue: queue) }
        receive()
    }

    private func receive() {
        let cont = continuation
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { cont.yield([UInt8](data)) }
            if error != nil {
                cont.finish(throwing: TransportError.linkLost)
            } else if isComplete {
                cont.finish()
            } else {
                self?.receive()
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !closed.withLock({ $0 }) else { throw TransportError.notOpen }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { done.resume(throwing: TransportError.writeFailed(error.localizedDescription)) }
                else { done.resume() }
            })
        }
    }

    public func close() async {
        let was = closed.withLock { c -> Bool in defer { c = true }; return c }
        guard !was else { return }
        continuation.finish()
        await NW.cancelAndWait(connection)
    }
}

/// Listens for TCP connections on every interface at `port` (0 = ephemeral; read `port` after `start()`).
public final class NWStreamListener: StreamListener {
    private struct State {
        var listener: NWListener?
        var continuation: AsyncStream<any StreamConnection>.Continuation?
        var boundPort: UInt16 = 0
    }
    public let requestedPort: UInt16
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ghe.listener")

    public init(port: UInt16) { requestedPort = port }

    /// The port actually listened on (after `start()`).
    public var port: UInt16 { state.withLock { $0.boundPort } }

    public func start() async throws -> AsyncStream<any StreamConnection> {
        await stop()
        let params = NW.tcpParameters()
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = requestedPort == 0 ? .any : (NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: params, on: nwPort) }
        catch { throw TransportError.openFailed("listen on \(requestedPort): \(error.localizedDescription)") }

        let (stream, cont) = AsyncStream<any StreamConnection>.makeStream()
        let q = queue
        listener.newConnectionHandler = { conn in
            let peer = NW.hostText(conn.endpoint)
            cont.yield(NWStreamConnection(conn, peerAddress: peer, queue: q, start: true))
        }
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if once.claim() { ready.resume() }
                case .failed(let err), .waiting(let err):
                    if once.claim() {
                        listener.cancel()
                        ready.resume(throwing: TransportError.openFailed("listen on \(self.requestedPort): \(err.localizedDescription)"))
                    } else {
                        cont.finish()
                    }
                case .cancelled:
                    if once.claim() { ready.resume(throwing: TransportError.openFailed("cancelled")) }
                    cont.finish()
                default: break
                }
            }
            listener.start(queue: q)
        }
        state.withLock { s in
            s.listener = listener
            s.continuation = cont
            s.boundPort = listener.port?.rawValue ?? 0
        }
        return stream
    }

    public func stop() async {
        let (l, c) = state.withLock { s in
            defer { s.listener = nil; s.continuation = nil }
            return (s.listener, s.continuation)
        }
        l?.newConnectionHandler = nil
        l?.cancel()
        c?.finish()
    }
}

/// Opens outbound TCP connections with Network.framework.
public struct NWStreamConnector: StreamConnector {
    public let connectTimeout: Duration
    public init(connectTimeout: Duration = .seconds(5)) { self.connectTimeout = connectTimeout }

    public func connect(host: String, port: UInt16) async throws -> any StreamConnection {
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else { throw TransportError.openFailed("bad port \(port)") }
        let queue = DispatchQueue(label: "ghe.connector")
        let secs = Int(connectTimeout.components.seconds)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                using: NW.tcpParameters(connectTimeout: max(1, secs)))
        try await NW.waitReady(conn, queue: queue, timeout: connectTimeout)
        return NWStreamConnection(conn, peerAddress: host, queue: queue, start: false)
    }
}
