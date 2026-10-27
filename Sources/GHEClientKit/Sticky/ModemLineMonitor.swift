import Foundation
import GHEKit

/// Events from the hidden "Sticky Port".
public enum StickyEvent: Sendable, Equatable {
    /// PTT LOCK bank positions on (CTS went low) or off (CTS went high).
    case pttLock(Bool)
    /// Map switches with "sticky" on jump to their sticky position.
    case jumpToSticky
    case failed(String)
}

/// Pure edge detector for CTS/DSR.
public struct ModemLineEdges: Sendable, Equatable {
    public private(set) var last: ModemLines?
    public init(initial: ModemLines? = nil) { last = initial }

    /// Events for a new reading. The first reading only sets the baseline (RXTX reports changes only).
    public mutating func update(_ lines: ModemLines) -> [StickyEvent] {
        defer { last = lines }
        guard let prev = last else { return [] }
        var out: [StickyEvent] = []
        if prev.cts != lines.cts {
            out += lines.cts ? [.pttLock(false)] : [.pttLock(true), .jumpToSticky]
        }
        if !prev.dsr && lines.dsr { out.append(.jumpToSticky) }
        return out
    }
}

/// Polls `modemLines()` every 20 ms (macOS has no TIOCMIWAIT) and reports edges.
public actor ModemLineMonitor {
    public static let pollInterval: Duration = .milliseconds(20)
    private let port: any ModemControl
    private let clock: any GHEClock
    private let interval: Duration
    private var task: Task<Void, Never>?

    public init(port: any ModemControl, clock: any GHEClock = SystemClock(), interval: Duration = pollInterval) {
        self.port = port; self.clock = clock; self.interval = interval
    }

    public func start() -> AsyncStream<StickyEvent> {
        task?.cancel()
        let (stream, c) = AsyncStream<StickyEvent>.makeStream()
        let port = port, clock = clock, interval = interval
        task = Task.detached {
            var edges = ModemLineEdges()
            while !Task.isCancelled {
                do {
                    for e in edges.update(try await port.modemLines()) { c.yield(e) }
                } catch {
                    c.yield(.failed(error.localizedDescription)); break
                }
                do { try await clock.sleep(for: interval) } catch { break }
            }
            c.finish()
        }
        return stream
    }

    public func stop() {
        task?.cancel(); task = nil
    }
}
