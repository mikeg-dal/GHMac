import Foundation
import GHEKit

/// Direct RT-21 (serial or TCP).
///
/// * Polls `BI2;` first after 2 s, then every 1 s (fixed rate).
/// * Goto: `AP2nnn;AM2;` until a reply containing '.' identifies an RT-21, then `AP2hhh.h\r;`.
/// * Jog `AA0;` / `AB0;` only once the RT-21 is identified. Stop `;`.
/// * Status '5' with the last heading on every poll once more than 5 polls went unanswered.
/// * The reading stream finishes when the link is lost (the slot treats that as a cable pull).
public actor RT21Driver: RotorDriver {
    /// Command set differences between the RT-21 and DCU-1 drivers.
    struct Dialect: Sendable {
        var digit: Character
        var poll: [UInt8]
        /// RT-21 tenths goto once model 21 is known.
        var usesTenthsWhenIdentified: Bool
        var allowsJog: Bool

        static func rt21(digit: Character) -> Dialect {
            Dialect(digit: digit, poll: RT21Commands.pollTenths(digit: digit), usesTenthsWhenIdentified: true, allowsJog: true)
        }
        static let dcu1 = Dialect(digit: "1", poll: RT21Commands.pollInteger(digit: "1"),
                                  usesTenthsWhenIdentified: false, allowsJog: false)
    }

    public nonisolated let name: String
    private let transport: any ByteTransport
    private let clock: any GHEClock
    private let dialect: Dialect
    private var parser = RT21ReplyParser()
    private var outlet = ReadingOutlet()
    /// −1 unknown, 20 RT-20 / DCU form, 21 RT-21 (a reply with '.').
    public private(set) var model = -1
    private var queryCount = 0
    private var currentHeading = 0.0
    private var pollTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var running = false

    /// - Parameter addressDigit: unit digit for poll/goto.
    public init(name: String, transport: any ByteTransport, clock: any GHEClock, addressDigit: Character = "2") {
        self.init(name: name, transport: transport, clock: clock, dialect: .rt21(digit: addressDigit))
    }

    init(name: String, transport: any ByteTransport, clock: any GHEClock, dialect: Dialect) {
        self.name = name
        self.transport = transport
        self.clock = clock
        self.dialect = dialect
    }

    public func start() async throws -> AsyncStream<RotorReading> {
        guard !running else { throw TransportError.unsupported("driver already started") }
        let incoming = try await transport.open()
        running = true
        let out = outlet.makeStream()
        readerTask = Task { [weak self] in
            do {
                for try await chunk in incoming { await self?.ingest(chunk) }
            } catch {}
            await self?.linkEnded()
        }
        pollTask = Task { [weak self, clock] in
            var next = clock.now + Timing.rotorPollInitialDelay
            while !Task.isCancelled {
                do { try await clock.sleep(until: next) } catch { return }
                guard let self else { return }
                await self.query()
                next = next + Timing.rotorPollPeriod
            }
        }
        return out
    }

    /// One poll: send the query, then count it; > 5 unanswered → status '5'.
    public func query() async {
        guard running else { return }
        await send(dialect.poll)
        queryCount += 1
        if queryCount > Timing.rotorMaxMissedPolls {
            outlet.yield(RotorReading(name: name, heading: currentHeading, status: .error))
        }
    }

    public func goTo(_ target: TurnTarget) async {
        guard running else { return }
        switch target.resolved {
        case .heading(let h):
            if dialect.usesTenthsWhenIdentified && model == 21 {
                await send(RT21Commands.gotoTenths(h, digit: dialect.digit))
            } else {
                await send(RT21Commands.gotoWithExecute(h, digit: dialect.digit))
            }
        case .cw:
            if dialect.allowsJog && model == 21 { await send(RT21Commands.jog(cw: true)) }
        case .ccw:
            if dialect.allowsJog && model == 21 { await send(RT21Commands.jog(cw: false)) }
        case .invalid:
            break
        }
    }

    public func stop() async {
        guard running else { return }
        await send(RT21Commands.stop)
    }

    public func close() async {
        guard running else { return }
        running = false
        pollTask?.cancel()
        readerTask?.cancel()
        await transport.close()
        outlet.finish()
    }

    // MARK: - Internals

    private func send(_ bytes: [UInt8]) async {
        do { try await transport.write(bytes) } catch { await linkEnded() }
    }

    private func ingest(_ chunk: [UInt8]) {
        for reply in parser.push(chunk) {
            guard case .heading(let h, let m) = reply else { continue }
            currentHeading = h
            // RT-20 replies reset the counter too.
            queryCount = 0
            model = m
            outlet.yield(RotorReading(name: name, heading: h, status: .ok))
        }
    }

    /// The link closed or failed without `close()`: stop polling and end the stream.
    private func linkEnded() async {
        guard running else { return }
        running = false
        pollTask?.cancel()
        readerTask?.cancel()
        await transport.close()
        outlet.finish()
    }
}

/// DCU-1 command set: `AI1;` poll every 1 s, `AP1nnn;AM1;`, stop `;`, no jog.
///
/// This driver reports '5' after > 5 unanswered polls, like the RT-21.
public actor DCU1Driver: RotorDriver {
    public nonisolated let name: String
    private let inner: RT21Driver

    public init(name: String, transport: any ByteTransport, clock: any GHEClock) {
        self.name = name
        inner = RT21Driver(name: name, transport: transport, clock: clock, dialect: .dcu1)
    }

    public func start() async throws -> AsyncStream<RotorReading> { try await inner.start() }
    public func goTo(_ target: TurnTarget) async { await inner.goTo(target) }
    public func stop() async { await inner.stop() }
    public func query() async { await inner.query() }
    public func close() async { await inner.close() }
}
