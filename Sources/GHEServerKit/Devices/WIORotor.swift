import Foundation
import GHEKit

/// An RT-21 behind a Remote. RT-21 text travels in TX16 frames to
/// `0x10nn`; replies come back as RX16 frames.
///
/// * Polls `BI2;` every 800 ms; status '5' (RSSI 0) on every cycle once > 5 cycles went unanswered.
/// * Goto `AP2hhh.h\r;` and stop `;` are sent 3× 500 ms apart, asynchronously:
///   the caller never waits, and a newer command supersedes the remaining repeats of an older one.
/// * Jog `AA0;` / `AB0;` once.
/// * RSSI = −(XBee RSSI byte). Each radio packet is parsed on its own (no reassembly).
/// * The poll task is cancelled on close.
public actor WIORotor: RotorDriver {
    public nonisolated let name: String
    public nonisolated let wioAddress: Int
    private let remote: PhysicalRemote
    private let clock: any GHEClock
    private var outlet = ReadingOutlet()
    private var frameID: UInt8 = 0
    private var responseReceived = true
    private var failedCycles = 0
    private var lastReading: RotorReading?
    private var currentHeading = 0.0
    private var pollTask: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var repeatTask: Task<Void, Never>?
    private var running = false

    public init(name: String, remote: PhysicalRemote, clock: any GHEClock) {
        self.name = name
        self.wioAddress = remote.address
        self.remote = remote
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<RotorReading> {
        guard !running else { throw TransportError.unsupported("driver already started") }
        running = true
        let out = outlet.makeStream()
        let packets = remote.packets.subscribe()
        await remote.attach()
        pump = Task { [weak self] in
            for await p in packets { await self?.handle(p) }
            await self?.linkEnded()
        }
        pollTask = Task { [weak self, clock] in
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollCycle()
                next = next + Timing.wioRotorPollPeriod
                do { try await clock.sleep(until: next) } catch { return }
            }
        }
        return out
    }

    public func goTo(_ target: TurnTarget) async {
        guard running else { return }
        switch target.resolved {
        case .heading(let h): sendRepeated(RT21Commands.gotoTenths(h, digit: "2"))
        case .cw: send(RT21Commands.jog(cw: true))
        case .ccw: send(RT21Commands.jog(cw: false))
        case .invalid: break
        }
    }

    public func stop() async {
        guard running else { return }
        sendRepeated(RT21Commands.stop)
    }

    /// Re-emits the last heading so GETHEAD gets an answer.
    public func query() async {
        if let r = lastReading { outlet.yield(r) }
    }

    public func close() async {
        guard running else { return }
        running = false
        stopTasks()
        await remote.detach()
        outlet.finish()
    }

    // MARK: - Internals

    private func pollCycle() {
        guard running else { return }
        failedCycles = responseReceived ? 0 : failedCycles + 1
        if failedCycles > Timing.rotorMaxMissedPolls {
            outlet.yield(RotorReading(name: name, heading: currentHeading, status: .error, rssi: 0))
        }
        responseReceived = false
        send(RT21Commands.pollTenths(digit: "2"))
    }

    private func send(_ text: [UInt8]) {
        let id = frameID
        frameID = (frameID + 1) % 10
        remote.sendFrame(XBeeFrame.tx16(id: id, wioAddress: wioAddress, payload: text))
    }

    private func sendRepeated(_ text: [UInt8]) {
        repeatTask?.cancel()
        send(text)
        repeatTask = Task { [weak self, clock] in
            for _ in 1..<Timing.wioRepeatCount {
                do { try await clock.sleep(for: Timing.wioRepeatSpacing) } catch { return }
                guard let self else { return }
                await self.send(text)
            }
        }
    }

    private func handle(_ p: RemotePacket) {
        var parser = RT21ReplyParser()
        var bytes = p.payload
        // Each packet is parsed as a complete reply even without the trailing ';'.
        if bytes.last != 0x3B { bytes.append(0x3B) }
        for reply in parser.push(bytes) {
            guard case .heading(let h, _) = reply else { continue }
            currentHeading = h
            responseReceived = true
            let r = RotorReading(name: name, heading: h, status: .ok, rssi: -Int(p.rssiByte))
            lastReading = r
            outlet.yield(r)
        }
    }

    private func stopTasks() {
        pollTask?.cancel(); pollTask = nil
        pump?.cancel(); pump = nil
        repeatTask?.cancel(); repeatTask = nil
    }

    private func linkEnded() {
        guard running else { return }
        running = false
        stopTasks()
        outlet.finish()
    }
}
