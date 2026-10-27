import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

/// Opens a Base on a fake, driving the 3 s validate wait on the manual clock.
func openFakeBase(_ fake: FakeWIOBase, clock: ManualClock, ptt: Bool = false, port: String = "COM7") async throws -> WIOBase {
    let base = WIOBase(portName: port, transport: fake, clock: clock, basePTT: ptt)
    let before = clock.sleeperCount
    let t = Task { try await base.open() }
    _ = await eventually { clock.sleeperCount > before || fake.writes.count > 0 }
    _ = await eventually { clock.sleeperCount > before }
    await clock.advance(by: Timing.wioBaseValidateWait)
    try await t.value
    return base
}

/// Frames of a given API id and AT command ("IO"/"DB"), or TX16 when `command` is nil and api 0x01.
func atFrames(_ fake: FakeWIOBase, _ command: String) -> [[UInt8]] {
    let c = Array(command.utf8)
    return fake.writes.filter { f in
        (f[3] == XBeeAPI.remoteAT && f.count > 17 && Array(f[16...17]) == c)
            || (f[3] == XBeeAPI.localAT && Array(f[5...6]) == c)
    }
}

/// Relay byte of an `IO` frame.
func relayByte(of f: [UInt8]) -> UInt8 { f[f.count - 2] }

/// Advances the manual clock in small steps, letting tasks run between steps.
func stepClock(_ clock: ManualClock, by total: Duration, tick: Duration = .milliseconds(100)) async {
    var left = total
    while left > .zero {
        let d = min(tick, left)
        await clock.advance(by: d)
        try? await Task.sleep(for: .milliseconds(2))
        left -= d
    }
}

/// Collects a stream into a shared buffer in the background.
final class StreamTap<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private(set) var finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<T>) {
        task = Task { [weak self] in
            for await x in stream { self?.append(x) }
            self?.finish()
        }
    }
    private func append(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    private func finish() { lock.lock(); finished = true; lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func cancel() { task?.cancel() }
}

extension WioProfile {
    /// Four positions A…D, one relay each (pins 0…3), like `Simple.xml`.
    static func simple(_ name: String = "4 Simple", lockout: Bool = false) -> WioProfile {
        WioProfile(name: name, displayType: .buttons, matrixLockout: lockout, positions: [
            .relay("A", onPins: [0]), .relay("B", onPins: [1]), .relay("C", onPins: [2]), .relay("D", onPins: [3]),
            .relay("OFF", onPins: []),
        ])
    }
}
