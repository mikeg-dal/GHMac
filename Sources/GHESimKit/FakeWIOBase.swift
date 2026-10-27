import Foundation
import Synchronization
import GHEKit
import GHEServerKit

/// An in-memory Base (XBee coordinator) with remotes behind it, for tests and simulator mode.
///
/// * Local `IO` → relay image of address 0, `0x88` OK reply (none for frame id 0).
/// * Remote AT (0x17) to `0x10nn` → `0x97` reply: status 0 for configured remotes, 4 for missing or
///   unreachable ones. `DB` replies carry the remote's RSSI byte.
/// * TX16 (0x01) payloads go to an embedded `FakeRT21Device` per address; each chunk it answers with
///   comes back as one RX16 (0x81) frame carrying the remote's RSSI byte. TX status (0x89) is sent too.
/// * Fault injection: raw garbage, byte-by-byte delivery, corrupt checksums, CTS low, silence, link failure.
public final class FakeWIOBase: ByteTransport, ModemControl, @unchecked Sendable {
    private struct Remote {
        var relay: UInt8 = 0
        var rssiByte: UInt8
        var reachable = true
    }

    private struct State {
        var continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation?
        var isOpen = false
        var opens = 0
        var decoder = XBeeDecoder()
        var localRelay: UInt8 = 0
        var remotes: [Int: Remote] = [:]
        var cts: Bool
        var written: [[UInt8]] = []
        var splitDelivery = false
        var corruptReplies = 0
        var silent = false
    }

    private let state: Mutex<State>
    /// RT-21s behind remotes, by WIO address.
    public let rotors: [Int: FakeRT21Device]
    private let links: [Int: FakeDeviceTransport]
    private let readers = Mutex<[Task<Void, Never>]>([])

    /// - Parameters:
    ///   - remotes: WIO addresses (1…255) that answer, with their RSSI byte (e.g. 40 → −40 dBm).
    ///   - rotors: addresses with an RT-21 attached and its starting heading (the remote is added too).
    ///   - clock: drives the embedded RT-21s' motion.
    public init(remotes: [Int: UInt8] = [:], rotors: [Int: Double] = [:], cts: Bool = true,
                clock: any GHEClock = SystemClock()) {
        var s = State(cts: cts)
        for (a, rssi) in remotes { s.remotes[a] = Remote(rssiByte: rssi) }
        var devs: [Int: FakeRT21Device] = [:]
        var ls: [Int: FakeDeviceTransport] = [:]
        for (a, h) in rotors {
            if s.remotes[a] == nil { s.remotes[a] = Remote(rssiByte: 40) }
            let d = FakeRT21Device(heading: h, clock: clock)
            devs[a] = d
            ls[a] = d.makeTransport()
        }
        state = Mutex(s)
        self.rotors = devs
        self.links = ls
    }

    deinit { for t in readers.withLock({ $0 }) { t.cancel() } }

    // MARK: ByteTransport / ModemControl

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        let (stream, c) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
        let old = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            let o = s.continuation
            s.continuation = c; s.isOpen = true; s.opens += 1; s.decoder = XBeeDecoder()
            return o
        }
        old?.finish()
        await openRotorLinks()
        return stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        var toRotors: [(Int, [UInt8])] = []
        let replies = try state.withLock { s -> [[UInt8]] in
            guard s.isOpen else { throw TransportError.notOpen }
            s.written.append(bytes)
            var out: [[UInt8]] = []
            for f in s.decoder.push(bytes) {
                guard case .other(let api, let d) = f else { continue }
                out += Self.handle(api: api, data: d, state: &s, hasRotor: { links[$0] != nil }, toRotors: &toRotors)
            }
            return s.silent ? [] : out
        }
        for r in replies { deliverFrame(r) }
        for (a, payload) in toRotors { try? await links[a]?.write(payload) }
    }

    public func close() async {
        let c = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            s.isOpen = false
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
    }

    public func modemLines() async throws -> ModemLines {
        ModemLines(cts: state.withLock { $0.cts })
    }

    // MARK: Inspection and fault injection

    public var isOpen: Bool { state.withLock { $0.isOpen } }
    public var openCount: Int { state.withLock { $0.opens } }
    /// Every write, as received (one frame per write from `WIOBase`).
    public var writes: [[UInt8]] { state.withLock { $0.written } }
    public func clearWrites() { state.withLock { $0.written.removeAll() } }
    /// Relay image of a remote (address 0 = the Base's own I/O).
    public func relayImage(_ address: Int) -> UInt8? {
        state.withLock { address == 0 ? $0.localRelay : $0.remotes[address]?.relay }
    }
    public func addRemote(_ address: Int, rssi: UInt8 = 40) {
        state.withLock { if $0.remotes[address] == nil { $0.remotes[address] = Remote(rssiByte: rssi) } }
    }
    public func setCTS(_ on: Bool) { state.withLock { $0.cts = on } }
    public func setReachable(_ address: Int, _ on: Bool) { state.withLock { $0.remotes[address]?.reachable = on } }
    public func setRSSI(_ address: Int, _ byte: UInt8) { state.withLock { $0.remotes[address]?.rssiByte = byte } }
    /// When true, replies are delivered one byte per chunk.
    public func setSplitDelivery(_ on: Bool) { state.withLock { $0.splitDelivery = on } }
    /// Corrupts the checksum of the next `n` replies.
    public func corruptNextReplies(_ n: Int) { state.withLock { $0.corruptReplies = n } }
    /// When true, nothing is answered (no AT replies, no radio packets).
    public func setSilent(_ on: Bool) { state.withLock { $0.silent = on } }
    /// Raw bytes from the "serial port".
    public func injectRaw(_ bytes: [UInt8]) { state.withLock { $0.continuation }?.yield(bytes) }
    /// Simulates a cable pull.
    public func failLink(_ error: any Error = TransportError.linkLost) {
        let c = state.withLock { s -> AsyncThrowingStream<[UInt8], any Error>.Continuation? in
            s.isOpen = false
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish(throwing: error)
    }

    // MARK: Internals

    private func openRotorLinks() async {
        for (a, link) in links where !link.isOpen {
            guard let stream = try? await link.open() else { continue }
            let t = Task { [weak self] in
                do { for try await chunk in stream { self?.rotorReply(a, chunk) } } catch {}
            }
            readers.withLock { $0.append(t) }
        }
    }

    private func rotorReply(_ address: Int, _ payload: [UInt8]) {
        let (rssi, ok) = state.withLock { s -> (UInt8, Bool) in
            let r = s.remotes[address]
            return (r?.rssiByte ?? 40, s.isOpen && !s.silent && (r?.reachable ?? false))
        }
        guard ok else { return }
        let a = XBeeFrame.remoteAddress16(address)
        deliverFrame(XBeeFrame.encode([XBeeAPI.rx16, UInt8(a >> 8), UInt8(a & 0xFF), rssi, 0] + payload))
    }

    private func deliverFrame(_ frame: [UInt8]) {
        let (c, split, corrupt) = state.withLock { s -> (AsyncThrowingStream<[UInt8], any Error>.Continuation?, Bool, Bool) in
            let corrupt = s.corruptReplies > 0
            if corrupt { s.corruptReplies -= 1 }
            return (s.continuation, s.splitDelivery, corrupt)
        }
        guard let c else { return }
        var f = frame
        if corrupt { f[f.count - 1] &+= 1 }
        if split { for b in f { c.yield([b]) } } else { c.yield(f) }
    }

    private static func handle(api: UInt8, data d: [UInt8], state s: inout State,
                               hasRotor: (Int) -> Bool, toRotors: inout [(Int, [UInt8])]) -> [[UInt8]] {
        switch api {
        case XBeeAPI.localAT where d.count >= 3:
            let id = d[0], cmd = Array(d[1..<3]), param = Array(d[3...])
            if cmd == Array("IO".utf8), let b = param.first { s.localRelay = b }
            guard id != 0 else { return [] }
            return [XBeeFrame.encode([XBeeAPI.localATResponse, id] + cmd + [0])]
        case XBeeAPI.remoteAT where d.count >= 14:
            let id = d[0], addr = Int(d[10]), cmd = Array(d[12..<14]), param = Array(d[14...])
            let a16 = [d[9], d[10]]
            guard var r = s.remotes[addr], r.reachable else {
                // XBee status 4: no response from the remote.
                return id == 0 ? [] : [XBeeFrame.encode([XBeeAPI.remoteATResponse, id] + [UInt8](repeating: 0, count: 8) + a16 + cmd + [4])]
            }
            var data: [UInt8] = []
            if cmd == Array("IO".utf8), let b = param.first { r.relay = b }
            if cmd == Array("DB".utf8) { data = [r.rssiByte] }
            s.remotes[addr] = r
            guard id != 0 else { return [] }
            let src64: [UInt8] = [0, 0x13, 0xA2, 0, 0x40, 0, 0, UInt8(addr)]
            return [XBeeFrame.encode([XBeeAPI.remoteATResponse, id] + src64 + a16 + cmd + [0] + data)]
        case XBeeAPI.tx16 where d.count >= 4:
            let id = d[0], addr = Int(d[2]), payload = Array(d[4...])
            let reachable = s.remotes[addr]?.reachable ?? false
            var out: [[UInt8]] = []
            if id != 0 { out.append(XBeeFrame.encode([XBeeAPI.txStatus, id, reachable ? 0 : 1])) }
            if reachable && hasRotor(addr) && !s.silent { toRotors.append((addr, payload)) }
            return out
        default:
            return []
        }
    }
}
