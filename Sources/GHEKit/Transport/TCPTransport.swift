import Foundation
import Network

/// A TCP link to a serial device server (e.g. the RT-21 Ethernet/WiFi module, port 6555)
/// carrying the same `;`-framed protocol as the serial port.
///
/// `close()` returns only once the connection is fully cancelled (or after a short
/// timeout), so a reconnect never overlaps the old connection — the RT-21 module
/// accepts only one.
public actor TCPTransport: ByteTransport {
    public let host: String
    public let port: UInt16
    public let connectTimeout: Duration
    private var connection: NWConnection?
    private var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
    private let queue = DispatchQueue(label: "ghe.tcp")

    public init(host: String, port: UInt16, connectTimeout: Duration = .seconds(5)) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        await close()
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw TransportError.openFailed("bad port \(port)")
        }
        let secs = Int(connectTimeout.components.seconds)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                using: NW.tcpParameters(connectTimeout: max(1, secs)))
        connection = conn
        do {
            try await NW.waitReady(conn, queue: queue, timeout: connectTimeout)
        } catch {
            if connection === conn { connection = nil }
            await NW.cancelAndWait(conn)
            throw error
        }
        guard connection === conn else {   // closed while connecting
            await NW.cancelAndWait(conn)
            throw TransportError.openFailed("closed while connecting")
        }

        let (stream, cont) = AsyncThrowingStream<[UInt8], any Error>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.linkLost(conn) }
            default: break
            }
        }
        receive(on: conn)
        return stream
    }

    private nonisolated func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let bytes = [UInt8](data)
                Task { await self.deliver(bytes, from: conn) }
            }
            if isComplete || error != nil {
                Task { await self.linkLost(conn) }
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func deliver(_ bytes: [UInt8], from conn: NWConnection) {
        guard connection === conn else { return }
        continuation?.yield(bytes)
    }

    /// EOF, reset or failure: finish the stream with `linkLost` and drop the connection.
    private func linkLost(_ conn: NWConnection) {
        guard connection === conn else { return }
        continuation?.finish(throwing: TransportError.linkLost)
        continuation = nil
        connection = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let connection else { throw TransportError.notOpen }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { done.resume(throwing: TransportError.writeFailed(error.localizedDescription)) }
                else { done.resume() }
            })
        }
    }

    public func close() async {
        continuation?.finish()
        continuation = nil
        guard let conn = connection else { return }
        connection = nil
        await NW.cancelAndWait(conn)
    }
}
