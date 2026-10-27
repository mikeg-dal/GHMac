import Foundation
import GHEKit

/// "Terminal Server (TCP)": talks straight to an RT-21 (LAN/WiFi module or serial device server)
/// without a server, and presents it as one synthetic rotor.
///
/// The RT-21 network module accepts ONE TCP connection, so the link holds an `EndpointLeases`
/// lease: a second connection to the same host:port in this process is refused up front.
public actor TerminalServerConnection: ServerConnection {
    /// Which poll the connection sends every second.
    public enum PollCommand: String, Sendable, Hashable, CaseIterable {
        /// `AI2;` → `ddd;` (default).
        case integer
        /// `BI2;` → `ddd.d;` (the user's RT-21 fw 4.13.1 answered `358.4;`).
        case tenths

        public var bytes: [UInt8] {
            self == .integer ? RT21Commands.pollInteger(digit: "2") : RT21Commands.pollTenths(digit: "2")
        }
    }

    public nonisolated let id: ServerID
    /// The synthetic rotor's name (the "Rotor Name" column, default `ip:port`).
    public nonisolated let rotorName: String

    private let poll: PollCommand
    private let makeTransport: @Sendable (String, UInt16) -> any ByteTransport
    private let leases: EndpointLeases
    private let owner: String
    private let clock: any GHEClock
    private let traffic: TrafficSink?

    private nonisolated let outbox: AsyncStream<ClientCommand>
    private nonisolated let outboxInput: AsyncStream<ClientCommand>.Continuation

    private var transport: LeasedTransport?
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    private var finished = false

    /// - Parameters:
    ///   - rotorName: name typed in the Servers dialog; nil or blank → `host:port`.
    ///   - makeTransport: builds the raw link (production: `TCPTransport`; tests: `FakeRT21Device`).
    public init(id: ServerID, rotorName: String?, poll: PollCommand = .integer,
                makeTransport: @escaping @Sendable (String, UInt16) -> any ByteTransport,
                leases: EndpointLeases = .shared, owner: String = "GHMac Client",
                clock: any GHEClock = SystemClock(), traffic: TrafficSink? = nil) {
        self.id = id
        let trimmed = rotorName.map(JavaString.trim) ?? ""
        // A blank Rotor Name falls back to ip:port.
        self.rotorName = trimmed.isEmpty ? id.description : trimmed
        self.poll = poll
        self.makeTransport = makeTransport
        self.leases = leases
        self.owner = owner
        self.clock = clock
        self.traffic = traffic
        (outbox, outboxInput) = AsyncStream<ClientCommand>.makeStream()
    }

    public func connect() async throws -> AsyncStream<ConnectionEvent> {
        guard !started else { throw TransportError.unsupported("a connection object connects only once") }
        started = true
        let link = LeasedTransport(makeTransport(id.host, id.port), endpoint: .tcp(host: id.host, port: id.port),
                                   owner: "\(owner) (\(rotorName))", leases: leases)
        let bytes = try await link.open()   // throws endpointBusy if this endpoint is already in use
        if finished {
            await link.close()
            throw CancellationError()
        }
        transport = link
        let (stream, continuation) = AsyncStream<ConnectionEvent>.makeStream()
        events = continuation
        continuation.yield(.connected)
        continuation.yield(.message(.add(rotorName)))
        note("Connected to RT-21 at \(id)")
        tasks.append(Task { await self.readLoop(bytes) })
        tasks.append(Task { await self.pollLoop(link) })
        tasks.append(Task { await self.writeLoop(link) })
        return stream
    }

    public nonisolated func enqueue(_ command: ClientCommand) {
        outboxInput.yield(command)
    }

    public func disconnect() async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        outboxInput.finish()
        await transport?.close()   // also releases the lease
        transport = nil
        note("Disconnected")
        events?.finish()
        events = nil
    }

    /// Bytes for a command, or nil if the RT-21 can't do it.
    static func bytes(for command: ClientCommand) -> [UInt8]? {
        switch command {
        case .turn(_, .heading(let h)):
            return RT21Commands.gotoTerminal(h)
        case .turn(_, .raw(let text)):
            // Plain decimal only — no comma, CW/CCW fail and send nothing.
            guard let h = JavaDouble.parse(text) else { return nil }
            return RT21Commands.gotoTerminal(h)
        case .turn(_, .cw), .turn(_, .ccw):
            return nil
        case .stop:
            return RT21Commands.stop
        default:
            // set_stack/set_switch are ignored here.
            return nil
        }
    }

    // MARK: Loops

    private func readLoop(_ bytes: AsyncThrowingStream<[UInt8], any Error>) async {
        var parser = RT21ReplyParser()
        do {
            for try await chunk in bytes {
                traffic?(TrafficEntry(server: id, direction: .incoming, text: TrafficEntry.printable(String(decoding: chunk, as: UTF8.self))))
                for reply in parser.push(chunk) {
                    if case .heading(let h, _) = reply {
                        // Status '0', no RSSI field (POINT␟name␟deg␟0).
                        events?.yield(.message(.point(rotor: rotorName, heading: h, status: .ok, rssi: 0)))
                    }
                }
            }
            // EOF ends the connection.
            await finish(.lost("Rotor closed the connection"))
        } catch {
            await finish(.lost(GHServerConnection.describe(error)))
        }
    }

    private func pollLoop(_ link: LeasedTransport) async {
        // First poll one period after connect, then every period.
        var next = clock.now + Timing.terminalServerPollPeriod
        while !finished {
            do { try await clock.sleep(until: next) } catch { return }
            if finished { return }
            next = next + Timing.terminalServerPollPeriod
            await write(poll.bytes, link)
        }
    }

    private func writeLoop(_ link: LeasedTransport) async {
        for await command in outbox {
            if finished { return }
            guard let bytes = Self.bytes(for: command) else { continue }
            await write(bytes, link)
        }
    }

    private func write(_ bytes: [UInt8], _ link: LeasedTransport) async {
        do {
            try await link.write(bytes)
            traffic?(TrafficEntry(server: id, direction: .outgoing,
                                  text: TrafficEntry.printable(String(decoding: bytes, as: UTF8.self))))
        } catch {
            await finish(.lost(GHServerConnection.describe(error)))
        }
    }

    private func finish(_ event: ConnectionEvent) async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        outboxInput.finish()
        note(GHServerConnection.describe(event))
        events?.yield(event)
        events?.finish()
        events = nil
        let link = transport
        transport = nil
        await link?.close()
    }

    private func note(_ text: String) {
        traffic?(TrafficEntry(server: id, direction: .note, text: text))
    }
}
