import Foundation
import Synchronization

/// A configurable fake RT-21 (or DCU-1) rotor controller, driven by a `GHEClock`.
///
/// Understands `BI<d>;` (→ `ddd.d;`, as fw 4.13.1 answers `358.4;`), `AI<d>;` (→ `ddd;`),
/// `AP<d>hhh.h\r;` (goto now), `AP<d>nnn;` + `AM<d>;` (set then execute), `AP<d>nnn\r;`,
/// jog `AA<d>;` / `AB<d>;` (turns until stop or the 0°/360° limit), stop `;`, and
/// register reads `R<reg><d>;` (→ `<reg>SOH<value>;`). Motion is computed from the clock, so
/// `ManualClock.advance(by:)` moves the rotor deterministically. Every received command is recorded.
public final class FakeRT21Device: FakeSerialDevice {
    public enum Personality: Sendable { case rt21, dcu1 }

    public struct Options: Sendable {
        public var personality: Personality = .rt21
        /// Rotation speed in degrees per second.
        public var degreesPerSecond: Double = 6
        /// Never reply (models a dead or misaddressed controller).
        public var silent = false
        /// Delay before each reply (on the device clock).
        public var replyDelay: Duration = .zero
        /// Prefix every reply with an ACK frame and a register frame (`\u{06};R\u{01}1;`).
        public var injectNoise = false
        /// Deliver each reply in two chunks split mid-frame.
        public var splitReplies = false
        /// Network-module behaviour: only one link may be open at a time.
        public var singleConnection = false
        /// With `singleConnection`: a second open attempt also locks the module until `powerCycle()`.
        public var lockOnSecondConnection = false
        public init() {}
    }

    private struct Motion {
        var start: Double
        var target: Double
        var since: ContinuousClock.Instant
    }

    private struct State {
        var options: Options
        var heading: Double
        var motion: Motion?
        var pendingTarget: Double?
        var links: [ObjectIdentifier: FakeDeviceTransport] = [:]
        var rx: [UInt8] = []
        var commands: [String] = []
        var rawCommands: [String] = []
        var refusedOpens = 0
        var locked = false
        var registers: [UInt8: String] = [:]
    }

    public let clock: any GHEClock
    private let state: Mutex<State>

    public init(heading: Double = 0, clock: any GHEClock = SystemClock(), options: Options = Options()) {
        self.clock = clock
        state = Mutex(State(options: options, heading: heading))
    }

    // MARK: Factories

    /// A new host-side link (each call is a separate "connection").
    public func makeTransport() -> FakeDeviceTransport { FakeDeviceTransport(device: self) }

    /// Opens a link and wraps it as a `StreamConnection` (fake network module).
    public func makeStreamConnection(peerAddress: String = "127.0.0.1") async throws -> any StreamConnection {
        try await FakeDeviceStreamConnection.open(self, peerAddress: peerAddress)
    }

    /// A connector whose every `connect` opens a link to this device (host/port ignored).
    public func connector() -> MemoryConnector {
        MemoryConnector { host, _ in try await self.makeStreamConnection(peerAddress: host) }
    }

    // MARK: Inspection and control

    /// Current heading (moves with the clock).
    public var heading: Double { state.withLock { s in Self.current(s, now: clock.now) } }
    public var isMoving: Bool { state.withLock { s in Self.moving(s, now: clock.now) } }
    /// Commands received, without `;`, CR or padding (e.g. `AP2045.0`, `AM2`, `` for stop).
    public var commands: [String] { state.withLock { $0.commands } }
    /// Commands exactly as received, without the `;` (e.g. `AP2045.0\r`).
    public var rawCommands: [String] { state.withLock { $0.rawCommands } }
    public func clearCommands() { state.withLock { $0.commands.removeAll(); $0.rawCommands.removeAll() } }
    public var openLinkCount: Int { state.withLock { $0.links.count } }
    public var refusedOpens: Int { state.withLock { $0.refusedOpens } }
    public var isLockedUntilPowerCycle: Bool { state.withLock { $0.locked } }

    public var options: Options {
        get { state.withLock { $0.options } }
        set { state.withLock { $0.options = newValue } }
    }

    public func setHeading(_ h: Double) {
        state.withLock { $0.heading = h; $0.motion = nil; $0.pendingTarget = nil }
    }

    public func setRegister(_ reg: Character, _ value: String) {
        state.withLock { $0.registers[reg.asciiValue ?? 0] = value }
    }

    /// Models the misuse that wedges the real network module.
    /// While locked, new opens are refused and open links get no replies.
    public func lockUp() { state.withLock { $0.locked = true } }

    /// Power-cycles the controller: drops every link (they see `linkLost`), clears the lock, stops motion.
    public func powerCycle() {
        let links = state.withLock { s -> [FakeDeviceTransport] in
            s.heading = Self.current(s, now: clock.now)
            s.motion = nil; s.pendingTarget = nil; s.locked = false; s.rx.removeAll()
            return Array(s.links.values)
        }
        for l in links { l.drop(TransportError.linkLost) }
    }

    // MARK: FakeSerialDevice

    public func attach(_ link: FakeDeviceTransport) throws {
        try state.withLock { s in
            if s.locked {
                s.refusedOpens += 1
                throw TransportError.openFailed("connection refused (device locked until power cycle)")
            }
            if s.options.singleConnection, !s.links.isEmpty, s.links[ObjectIdentifier(link)] == nil {
                s.refusedOpens += 1
                if s.options.lockOnSecondConnection { s.locked = true }
                throw TransportError.openFailed("connection refused (only one connection allowed)")
            }
            s.links[ObjectIdentifier(link)] = link
        }
    }

    public func detach(_ link: FakeDeviceTransport) {
        state.withLock { s in _ = s.links.removeValue(forKey: ObjectIdentifier(link)) }
    }

    public func receive(_ bytes: [UInt8], from link: FakeDeviceTransport) {
        var replies: [[UInt8]] = []
        let (opts, locked) = state.withLock { s -> (Options, Bool) in
            for b in bytes {
                if b == 0x3B {
                    let frame = s.rx
                    s.rx.removeAll()
                    if let r = handle(frame, &s) { replies.append(r) }
                } else if s.rx.count < 256 {
                    s.rx.append(b)
                }
            }
            return (s.options, s.locked)
        }
        guard !opts.silent, !locked else { return }
        for r in replies { send(r, to: link, opts) }
    }

    // MARK: Command handling

    private func handle(_ frame: [UInt8], _ s: inout State) -> [UInt8]? {
        let raw = String(decoding: frame, as: UTF8.self)
        let cmd = raw.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" }.trimmingCharacters(in: .whitespaces)
        s.rawCommands.append(raw)
        s.commands.append(cmd)
        let now = clock.now
        let chars = Array(cmd)
        if cmd.isEmpty {   // stop
            s.heading = Self.current(s, now: now); s.motion = nil; s.pendingTarget = nil
            return nil
        }
        guard chars.count >= 3 else { return nil }
        let op = String(chars[0...1])
        let arg = String(chars[3...])
        switch op {
        case "BI":
            guard s.options.personality == .rt21 else { return nil }
            return Array(String(format: "%05.1f;", Self.current(s, now: now)).utf8)
        case "AI":
            let h = Int(Self.current(s, now: now).rounded())
            return Array(String(format: "%03d;", h).utf8)
        case "AP":
            guard let v = Double(arg), v.isFinite else { return nil }
            let target = min(max(v, 0), 360)
            if raw.contains("\r") { start(to: target, &s, now) } else { s.pendingTarget = target }
            return nil
        case "AM":
            if let t = s.pendingTarget { s.pendingTarget = nil; start(to: t, &s, now) }
            return nil
        case "AA", "AB":
            guard s.options.personality == .rt21 else { return nil }
            start(to: op == "AB" ? 360 : 0, &s, now)
            return nil
        case _ where chars[0] == "R":
            let reg = chars[1].asciiValue ?? 0
            return [reg, 0x01] + Array((s.registers[reg] ?? "0").utf8) + [0x3B]
        default:
            return nil
        }
    }

    private func start(to target: Double, _ s: inout State, _ now: ContinuousClock.Instant) {
        s.heading = Self.current(s, now: now)
        s.motion = Motion(start: s.heading, target: target, since: now)
    }

    private static func current(_ s: State, now: ContinuousClock.Instant) -> Double {
        guard let m = s.motion else { return s.heading }
        let dt = m.since.duration(to: now)
        let secs = Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18
        let travel = max(0, secs) * s.options.degreesPerSecond
        let dist = m.target - m.start
        if travel >= abs(dist) { return m.target }
        return m.start + (dist < 0 ? -travel : travel)
    }

    private static func moving(_ s: State, now: ContinuousClock.Instant) -> Bool {
        guard let m = s.motion else { return false }
        return current(s, now: now) != m.target
    }

    private func send(_ reply: [UInt8], to link: FakeDeviceTransport, _ opts: Options) {
        var bytes = reply
        if opts.injectNoise { bytes = [0x06, 0x3B, 0x52, 0x01, 0x31, 0x3B] + bytes }
        let chunks: [[UInt8]] = opts.splitReplies && bytes.count > 1
            ? [Array(bytes[..<(bytes.count / 2)]), Array(bytes[(bytes.count / 2)...])]
            : [bytes]
        if opts.replyDelay > .zero {
            let clock = self.clock
            Task {
                try? await clock.sleep(for: opts.replyDelay)
                for c in chunks { link.deliver(c) }
            }
        } else {
            for c in chunks { link.deliver(c) }
        }
    }
}
