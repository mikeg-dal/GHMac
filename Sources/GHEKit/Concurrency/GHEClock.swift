import Foundation
import Synchronization

/// Injectable time source. Every timer goes through one of these so
/// tests can drive time deterministically with `ManualClock`.
public protocol GHEClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

public extension GHEClock {
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let d = now.duration(to: deadline)
        if d > .zero { try await sleep(for: d) }
    }
}

/// Real time.
public struct SystemClock: GHEClock {
    public init() {}
    public var now: ContinuousClock.Instant { .now }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Test clock: time only moves when `advance(by:)` is called.
///
/// Sleepers whose deadline is reached are resumed in deadline order; between
/// each resumption the clock yields so woken tasks can run and schedule new
/// sleeps that may also fall inside the advanced window.
public final class ManualClock: GHEClock {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var elapsed: Duration = .zero
        var nextID: UInt64 = 0
        var sleepers: [Sleeper] = []
    }

    private let base: ContinuousClock.Instant
    private let state = Mutex(State())

    public init() { base = .now }

    public var now: ContinuousClock.Instant { base + state.withLock { $0.elapsed } }

    /// Time advanced since creation.
    public var elapsed: Duration { state.withLock { $0.elapsed } }

    /// Number of tasks currently sleeping on this clock.
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= .zero { await Task.yield(); return }
        let id = state.withLock { s -> UInt64 in s.nextID += 1; return s.nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.sleepers.append(Sleeper(id: id, deadline: s.elapsed + duration, continuation: c))
                    return false
                }
                if resumeNow { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = state.withLock { s -> CheckedContinuation<Void, any Error>? in
                guard let i = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return s.sleepers.remove(at: i).continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward, waking every sleeper whose deadline falls inside the window.
    public func advance(by duration: Duration) async {
        let target = state.withLock { $0.elapsed } + duration
        await settle()
        while true {
            let next = state.withLock { s -> Sleeper? in
                guard let i = s.sleepers.indices.min(by: { s.sleepers[$0].deadline < s.sleepers[$1].deadline }),
                      s.sleepers[i].deadline <= target else { return nil }
                let sl = s.sleepers.remove(at: i)
                s.elapsed = max(s.elapsed, sl.deadline)
                return sl
            }
            guard let next else { break }
            next.continuation.resume()
            await settle()
        }
        state.withLock { $0.elapsed = max($0.elapsed, target) }
        await settle()
    }

    /// Lets other tasks run (woken sleepers, actors) before continuing.
    public func settle(_ rounds: Int = 100) async {
        for _ in 0..<rounds { await Task.yield() }
    }
}
