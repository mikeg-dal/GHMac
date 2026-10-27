import Foundation
import GHEKit

/// Fixed antenna: reports a constant heading with status '7'.
///
/// * First report 500 ms after start, then every 2 s.
/// * Any double passes through unchanged, including > 360 (clients show `---`).
/// * A query answers with status '7', and only for this rotor's
///   name (the registry routes by exact name).
/// * Turn and stop are ignored.
public actor FixedRotor: RotorDriver {
    public nonisolated let name: String
    public nonisolated let heading: Double
    private let clock: any GHEClock
    private var outlet = ReadingOutlet()
    private var pollTask: Task<Void, Never>?

    public init(name: String, heading: Double, clock: any GHEClock) {
        self.name = name
        self.heading = heading
        self.clock = clock
    }

    public func start() async throws -> AsyncStream<RotorReading> {
        let out = outlet.makeStream()
        pollTask?.cancel()
        pollTask = Task { [weak self, clock] in
            // Each 2 s tick waits 500 ms before firing.
            var next = clock.now + .milliseconds(500)
            while !Task.isCancelled {
                do { try await clock.sleep(until: next) } catch { return }
                guard let self else { return }
                await self.emit()
                next = next + Timing.fixedRotorPeriod
            }
        }
        return out
    }

    public func goTo(_ target: TurnTarget) async {}
    public func stop() async {}
    public func query() async { emit() }

    public func close() async {
        pollTask?.cancel()
        pollTask = nil
        outlet.finish()
    }

    private func emit() {
        outlet.yield(RotorReading(name: name, heading: heading, status: .fixed))
    }
}
