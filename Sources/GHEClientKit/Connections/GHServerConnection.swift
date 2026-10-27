import Foundation
import GHEKit

/// The client side of the server protocol: one TCP connection to a server.
///
/// Writes follow the rules the server needs for wire compatibility:
/// - every command is ONE write of `<cmd>\r\n`, under 256 bytes;
/// - the 32-byte digest is one write with no terminator, and nothing else is written until the
///   server speaks again or `Timing.postAuthHold` passes;
/// - the keepalive NUL is always its own write and is skipped if a command went out in the last 5 s.
public actor GHServerConnection: ServerConnection {
    public nonisolated let id: ServerID

    private let user: String
    /// P = SHA-256(user ‖ password low bytes). The clear-text password is never kept.
    private let passwordHash: [UInt8]
    private let connector: any StreamConnector
    private let clock: any GHEClock
    private let traffic: TrafficSink?

    private nonisolated let outbox: AsyncStream<ClientCommand>
    private nonisolated let outboxInput: AsyncStream<ClientCommand>.Continuation

    /// Write gate for commands ("hold all outgoing commands").
    private enum Gate: Equatable {
        /// Nothing heard from the server yet (it may be about to send `USER:`).
        case awaitingServer
        /// `USER:` answered; waiting for `PASS:`.
        case authenticating
        /// Digest written; waiting for the first post-auth line or the hold timeout.
        case digestSent
        case open
    }

    private var connection: (any StreamConnection)?
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var gate: Gate = .awaitingServer
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCommandWrite: ContinuousClock.Instant?
    private var started = false
    private var finished = false

    public init(id: ServerID, user: String, passwordHash: [UInt8], connector: any StreamConnector,
                clock: any GHEClock = SystemClock(), traffic: TrafficSink? = nil) {
        self.id = id
        self.user = user
        self.passwordHash = passwordHash
        self.connector = connector
        self.clock = clock
        self.traffic = traffic
        (outbox, outboxInput) = AsyncStream<ClientCommand>.makeStream()
    }

    // MARK: ServerConnection

    public func connect() async throws -> AsyncStream<ConnectionEvent> {
        guard !started else { throw TransportError.unsupported("a connection object connects only once") }
        started = true
        let conn = try await connector.connect(host: id.host, port: id.port)
        if finished {   // disconnect() was called while connecting
            await conn.close()
            throw CancellationError()
        }
        connection = conn
        let (stream, continuation) = AsyncStream<ConnectionEvent>.makeStream()
        events = continuation
        // Fires "connected" before authentication.
        continuation.yield(.connected)
        note("Connected")
        let start = clock.now
        tasks.append(Task { await self.readLoop(conn) })
        tasks.append(Task { await self.writeLoop(conn) })
        tasks.append(Task { await self.keepaliveLoop(conn, start: start) })
        return stream
    }

    public nonisolated func enqueue(_ command: ClientCommand) {
        outboxInput.yield(command)
    }

    /// Sends a flushed `QUIT\r\n` , then closes.
    public func disconnect() async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        let mayQuit = gate == .open || gate == .awaitingServer
        openGate()
        outboxInput.finish()
        if let conn = connection {
            if mayQuit {
                let quit = GHWire.encode(ClientCommand.quit)
                if (try? await conn.send(quit)) != nil { log(.outgoing, quit) }
            }
            await conn.close()
        }
        connection = nil
        note("Disconnected")
        events?.finish()
        events = nil
    }

    // MARK: Reading

    private func readLoop(_ conn: any StreamConnection) async {
        var decoder = ClientLineDecoder()
        do {
            for try await chunk in conn.incoming {
                for line in decoder.push(chunk) {
                    await handle(line, conn)
                    if finished { return }
                }
            }
            // EOF is a disconnect right away.
            await finish(.lost("Server closed the connection"))
        } catch {
            await finish(.lost(Self.describe(error)))
        }
    }

    private func handle(_ line: String, _ conn: any StreamConnection) async {
        traffic?(TrafficEntry(server: id, direction: .incoming, text: TrafficEntry.printable(line)))
        let message = GHWire.decodeServerLine(line)
        switch message {
        case .user:
            gate = .authenticating
            // The user name line: one write, CR LF terminated.
            await write(Windows1252.encode(user) + GHSeparator.crlf, conn, isCommand: false)
        case .pass(let challenge):
            gate = .digestSent
            // Wire compatibility: exactly 32 raw bytes in ONE write, no terminator.
            let digest = GHAuth.response(user: user, challenge: challenge, passwordHash: passwordHash)
            do {
                try await conn.send(digest)
                traffic?(TrafficEntry(server: id, direction: .outgoing, text: "<32-byte digest>"))
            } catch {
                await finish(.lost(Self.describe(error)))
                return
            }
            let hold = Timing.postAuthHold
            let clock = self.clock
            tasks.append(Task {
                try? await clock.sleep(for: hold)
                self.openGateAfterHold()
            })
        case .invalidUserPass:
            await finish(.invalidCredentials)
        case .close:
            await finish(.closedByServer)
        default:
            // Any other line means the server is past authentication.
            openGate()
            if case .ignored = message { return }
            events?.yield(.message(message))
        }
    }

    // MARK: Writing

    private func writeLoop(_ conn: any StreamConnection) async {
        for await command in outbox {
            await waitForGate()
            if finished || Task.isCancelled { return }
            let bytes = GHWire.encode(command)
            // Wire compatibility: one write per command, < 256 bytes, never with a NUL.
            guard bytes.count < 256, !bytes.contains(0) else {
                note("Dropped command (\(bytes.count) bytes, servers read at most 255): "
                     + TrafficEntry.printable(Windows1252.decode(bytes)))
                continue
            }
            await write(bytes, conn, isCommand: true)
            if finished { return }
        }
    }

    private func write(_ bytes: [UInt8], _ conn: any StreamConnection, isCommand: Bool) async {
        do {
            try await conn.send(bytes)
            if isCommand { lastCommandWrite = clock.now }
            log(.outgoing, bytes)
        } catch {
            await finish(.lost(Self.describe(error)))
        }
    }

    /// Keepalive: one 0x00 byte at 10 s, then every 5 s (fixed rate, like `Timer.scheduleAtFixedRate`).
    private func keepaliveLoop(_ conn: any StreamConnection, start: ContinuousClock.Instant) async {
        var next = start + Timing.keepaliveInitialDelay
        while !finished {
            do { try await clock.sleep(until: next) } catch { return }
            if finished { return }
            next = next + Timing.keepalivePeriod
            // Never ping in the middle of the handshake: the digest must arrive alone.
            if gate == .authenticating || gate == .digestSent { continue }
            // Skip the ping if a command went out recently (the link is evidently alive
            // and a NUL right behind a command can corrupt it on the server).
            if let last = lastCommandWrite, last.duration(to: clock.now) < Timing.keepalivePeriod { continue }
            do {
                try await conn.send([0])
            } catch {
                await finish(.lost("Keepalive failed: " + Self.describe(error)))
                return
            }
        }
    }

    // MARK: Gate

    private func waitForGate() async {
        if gate == .open || finished { return }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    private func openGate() {
        gate = .open
        let waiters = gateWaiters
        gateWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private func openGateAfterHold() {
        if gate == .digestSent { openGate() }
    }

    // MARK: Ending

    private func finish(_ event: ConnectionEvent) async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        openGate()
        outboxInput.finish()
        note(Self.describe(event))
        events?.yield(event)
        events?.finish()
        events = nil
        let conn = connection
        connection = nil
        await conn?.close()
    }

    // MARK: Logging

    private func log(_ direction: TrafficEntry.Direction, _ bytes: [UInt8]) {
        guard let traffic else { return }
        traffic(TrafficEntry(server: id, direction: direction, text: TrafficEntry.printable(Windows1252.decode(bytes))))
    }

    private func note(_ text: String) {
        traffic?(TrafficEntry(server: id, direction: .note, text: text))
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func describe(_ event: ConnectionEvent) -> String {
        switch event {
        case .connected: "Connected"
        case .message: "Message"
        case .invalidCredentials: "Invalid user/pass"
        case .closedByServer: "Server sent CLOSE"
        case .lost(let why): "Connection lost: \(why)"
        }
    }
}
