import Foundation
import Synchronization

/// Fan-out of events to any number of `AsyncStream` subscribers.
public final class EventBroadcaster<Event: Sendable>: Sendable {
    private struct State {
        var next = 0
        var subscribers: [Int: AsyncStream<Event>.Continuation] = [:]
        var finished = false
    }
    private let state = Mutex(State())

    public init() {}

    /// A new stream that receives every event yielded after this call.
    public func subscribe(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: bufferingPolicy)
        let id: Int? = state.withLock { s in
            guard !s.finished else { return nil }
            s.next += 1
            s.subscribers[s.next] = continuation
            return s.next
        }
        guard let id else { continuation.finish(); return stream }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func yield(_ event: Event) {
        let subs = state.withLock { Array($0.subscribers.values) }
        for s in subs { s.yield(event) }
    }

    public func finish() {
        let subs = state.withLock { s -> [AsyncStream<Event>.Continuation] in
            s.finished = true
            defer { s.subscribers.removeAll() }
            return Array(s.subscribers.values)
        }
        for s in subs { s.finish() }
    }

    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }
}
