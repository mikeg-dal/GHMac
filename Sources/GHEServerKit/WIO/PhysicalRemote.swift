import Foundation
import GHEKit

/// What a remote reports to its logical devices after each routed AT response.
public struct RemoteSnapshot: Sendable, Equatable {
    /// Relay image, DIO0…DIO7.
    public var relays: [Bool]
    /// XBee AT status: 0 OK, 1 ERROR, 2 invalid command, 3 invalid parameter, 4 no response.
    public var status: Int
    /// dBm (negative), 0 for the Base's own I/O.
    public var rssi: Int
}

/// A radio packet from the RT-21 behind a remote (RX16 frame).
public struct RemotePacket: Sendable, Equatable {
    public var payload: [UInt8]
    /// The raw XBee RSSI byte (`frame[6]`).
    public var rssiByte: UInt8
}

/// One Remote (or the Base's own I/O at address 0), shared by every device at that address.
public actor PhysicalRemote {
    public nonisolated let address: Int
    /// Fired on every routed AT response (subject to the status-4 debounce).
    public nonisolated let snapshots = EventBroadcaster<RemoteSnapshot>()
    /// RX16 packets for the WIO rotor at this address.
    public nonisolated let packets = EventBroadcaster<RemotePacket>()

    private let base: WIOBase
    private let clock: any GHEClock
    public private(set) var relays = [Bool](repeating: false, count: 8)
    public private(set) var status = 4
    public private(set) var rssi = 0
    /// Starts at 1, so the first frame id is 2 (the cycle includes 0 = no response).
    private var frameID: UInt8 = 1
    private var rssiCounter = 0
    private var commandNoResponse = 0
    private var pollNoResponse = 0
    private var users = 0
    private var pollTask: Task<Void, Never>?
    private var requestTail: Task<Void, Never>?
    private var gone = false

    init(address: Int, base: WIOBase, clock: any GHEClock) {
        self.address = address
        self.base = base
        self.clock = clock
    }

    public var relayByte: UInt8 { Self.relayByte(relays) }

    /// Queues a raw frame on the Base's single writer (WIO rotor TX16 frames).
    public nonisolated func sendFrame(_ frame: [UInt8]) { base.send(frame) }

    public static func relayByte(_ r: [Bool]) -> UInt8 {
        var b: UInt8 = 0
        for (i, on) in r.prefix(8).enumerated() where on { b |= 1 << UInt8(i) }
        return b
    }

    // MARK: Users

    /// A logical device or rotor starts using this remote; the first one starts the poll loop.
    public func attach() {
        guard !gone else { return }
        users += 1
        if pollTask == nil {
            pollTask = Task { [weak self] in await self?.runPoll() }
        }
    }

    /// A user stops; the last one stops the poll and releases the remote from the Base.
    public func detach() async {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        shutdown()
        await base.remoteClosed(self)
    }

    /// The Base closed or lost its link.
    func baseGone() { shutdown() }

    private func shutdown() {
        gone = true
        pollTask?.cancel()
        pollTask = nil
        snapshots.finish()
        packets.finish()
    }

    // MARK: Relays

    /// `requestSwitch`: −1 keep, 0 off, 1 on, 2 momentary (on, then off after 500 ms).
    /// Requests run one at a time, without blocking any thread.
    public func request(mask: [Int8]) async {
        let previous = requestTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRequest(mask)
        }
        requestTail = task
        await task.value
    }

    private func performRequest(_ mask: [Int8]) async {
        guard !gone else { return }
        var image = relays
        var momentary = false
        for (i, v) in mask.prefix(8).enumerated() {
            switch v {
            case 0: image[i] = false
            case 1: image[i] = true
            case 2: image[i] = true; momentary = true
            default: break
            }
        }
        base.send(XBeeFrame.relaySet(id: nextFrameID(), wioAddress: address, relayByte: Self.relayByte(image)))
        relays = image
        if momentary {
            try? await clock.sleep(for: Timing.wioMomentaryPulse)
            await performRequest(mask.map { $0 == 2 ? 0 : $0 })
        }
    }

    /// `initializeSwitch`: updates the image only (no I/O); momentary pins are ignored.
    public func initialize(mask: [Int8]) {
        for (i, v) in mask.prefix(8).enumerated() {
            if v == 0 { relays[i] = false } else if v == 1 { relays[i] = true }
        }
    }

    /// Frame ids `(id + 1) % 10` (relay frames advance it; the DB query reuses the current id).
    private func nextFrameID() -> UInt8 {
        frameID = (frameID + 1) % 10
        return frameID
    }

    // MARK: Poll

    private func runPoll() async {
        do {
            try await clock.sleep(for: Timing.wioRemotePollInitialDelay)
            while !Task.isCancelled && !gone {
                // Keep-alive / refresh: resend the full relay image every cycle.
                base.send(XBeeFrame.relaySet(id: nextFrameID(), wioAddress: address, relayByte: relayByte))
                if address != 0 && status == 0 && rssiCounter % Timing.wioRSSIEveryNthCycle == 0 {
                    try await clock.sleep(for: Timing.wioRemoteHalfCycle)
                    base.send(XBeeFrame.rssiQuery(id: frameID, wioAddress: address))
                    try await clock.sleep(for: Timing.wioRemoteHalfCycle)
                } else {
                    try await clock.sleep(for: Timing.wioRemoteCycle)
                }
                rssiCounter += 1
            }
        } catch {}
    }

    // MARK: Inbound

    func handle(_ frame: XBeeInbound) {
        switch frame {
        case .localATResponse(_, _, let st, _):
            status = Int(st)
            rssi = 0
            if status == 4 && address != 0 {
                commandNoResponse += 1
                if commandNoResponse > Timing.wioNoResponseDebounce { notify() }
            } else {
                commandNoResponse = 0
                notify()
            }
        case .remoteATResponse(_, _, _, let cmd, let st, let data):
            status = Int(st)
            if cmd == Array("DB".utf8) {
                if let b = data.first, Int8(bitPattern: b) > 0 { rssi = -Int(b) }
                if status == 4 && address != 0 {
                    pollNoResponse += 1
                    if pollNoResponse > Timing.wioNoResponseDebounce { notify() }
                } else {
                    pollNoResponse = 0
                    notify()
                }
            } else if status == 4 {
                commandNoResponse += 1
                if commandNoResponse > Timing.wioNoResponseDebounce { notify() }
            } else {
                commandNoResponse = 0
                notify()
            }
        case .rx16(_, let rssiByte, _, let payload):
            packets.yield(RemotePacket(payload: payload, rssiByte: rssiByte))
        case .other:
            break
        }
    }

    private func notify() {
        snapshots.yield(RemoteSnapshot(relays: relays, status: status, rssi: rssi))
    }

    /// Current state (for tests and the UI).
    public var snapshot: RemoteSnapshot { RemoteSnapshot(relays: relays, status: status, rssi: rssi) }
    public var userCount: Int { users }
}
