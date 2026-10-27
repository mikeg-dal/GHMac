import Foundation
import GHEKit

/// TCP client to N3FJP's API server. Sends nothing; reads CRLF lines and
/// reconnects 1 s after any disconnect or failed connect, forever, until stopped.
public actor N3FJPMonitor: LoggerMonitor {
    public static let waitingMessage = "Waiting for N3FJP Connection!"

    private let connector: any StreamConnector
    private let host: String
    private let port: UInt16
    private let clock: any GHEClock
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<LoggerEvent>.Continuation?
    private var connection: (any StreamConnection)?

    public init(connector: any StreamConnector, host: String = "127.0.0.1", port: UInt16 = 1100,
                clock: any GHEClock = SystemClock()) {
        self.connector = connector; self.host = host; self.port = port; self.clock = clock
    }

    public func start() async throws -> AsyncStream<LoggerEvent> {
        await stop()
        let (stream, c) = AsyncStream<LoggerEvent>.makeStream()
        continuation = c
        task = Task { await self.run(c) }
        return stream
    }

    public func stop() async {
        task?.cancel(); task = nil
        await connection?.close(); connection = nil
        continuation?.finish(); continuation = nil
    }

    private func run(_ c: AsyncStream<LoggerEvent>.Continuation) async {
        while !Task.isCancelled {
            do {
                let conn = try await connector.connect(host: host, port: port)
                if Task.isCancelled { await conn.close(); break }
                connection = conn
                c.yield(.status("Connected to N3FJP at \(host):\(port)"))
                var framer = N3FJPLineFramer()
                for try await chunk in conn.incoming {
                    for line in framer.push(chunk) { emit(line, c) }
                }
                if let rest = framer.flush() { emit(rest, c) }
            } catch {
                // Connection refused, reset or lost: fall through to the retry.
            }
            await connection?.close(); connection = nil
            if Task.isCancelled { break }
            c.yield(.status(Self.waitingMessage))
            do { try await clock.sleep(for: Timing.n3fjpReconnectDelay) } catch { break }
        }
        c.finish()
    }

    private func emit(_ line: String, _ c: AsyncStream<LoggerEvent>.Continuation) {
        guard !line.isEmpty else { return }
        for e in N3FJPParser.events(for: line) { c.yield(e) }
    }
}
