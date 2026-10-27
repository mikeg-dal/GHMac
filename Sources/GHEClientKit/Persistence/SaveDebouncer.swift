import Foundation
import GHEKit
import Synchronization

/// Coalesces "something changed, save it" calls: the action runs once, `delay` after the last
/// `schedule()`. `flush()` runs a pending save immediately (use it at quit). Runs on any thread.
public final class SaveDebouncer: Sendable {
    private struct State {
        var generation = 0
        var pending = false
        var task: Task<Void, Never>?
    }

    private let clock: any GHEClock
    private let delay: Duration
    private let action: @Sendable () -> Void
    private let state = Mutex(State())

    public init(clock: any GHEClock = SystemClock(), delay: Duration = .milliseconds(500),
                action: @escaping @Sendable () -> Void) {
        self.clock = clock
        self.delay = delay
        self.action = action
    }

    public func schedule() {
        let clock = clock, delay = delay
        state.withLock { s in
            s.generation += 1
            s.pending = true
            s.task?.cancel()
            let generation = s.generation
            s.task = Task { [weak self] in
                do { try await clock.sleep(for: delay) } catch { return }
                self?.fire(ifGeneration: generation)
            }
        }
    }

    public var hasPendingSave: Bool { state.withLock { $0.pending } }

    /// Runs the pending save now, if any.
    public func flush() {
        let run = state.withLock { s -> Bool in
            guard s.pending else { return false }
            s.pending = false
            s.task?.cancel()
            s.task = nil
            return true
        }
        if run { action() }
    }

    private func fire(ifGeneration generation: Int) {
        let run = state.withLock { s -> Bool in
            guard s.pending, s.generation == generation else { return false }
            s.pending = false
            s.task = nil
            return true
        }
        if run { action() }
    }

    deinit { state.withLock { $0.task?.cancel() } }
}
