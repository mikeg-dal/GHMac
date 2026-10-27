import Synchronization

/// Thread-safe "first caller wins" flag for one-shot continuations.
final class OnceFlag: Sendable {
    private let done = Mutex(false)
    init() {}
    func claim() -> Bool {
        done.withLock { d in
            if d { return false }
            d = true
            return true
        }
    }
}
