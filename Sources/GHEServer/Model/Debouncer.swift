import Foundation

/// Coalesces bursts of changes into one action.
@MainActor
final class Debouncer {
    private let delay: Duration
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(500), action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func schedule() {
        task?.cancel()
        task = Task { [delay, weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Runs a pending action now (quit).
    func flush() {
        guard task != nil else { return }
        fire()
    }

    private func fire() {
        task?.cancel()
        task = nil
        action()
    }
}
