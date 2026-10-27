import Foundation
import GHEKit

/// Cloned antenna: a second name for an existing rotor, offset by ±180°.
///
/// * Readings: `(h + offset)` normalised to [0, 360) with status '8'. The source's
///   error status is masked (a clone of a dead rotor still reports '8').
/// * Commands: `(h − offset)` normalised, forwarded to the source; CW/CCW and stop are forwarded.
/// * Queries are only routed here for this clone's own name (the registry routes by name).
/// * Closing unsubscribes from the source; when the source goes away the clone's stream
///   ends too, so the slot can re-bind to the reconnected source.
public actor ClonedRotor: RotorDriver {
    public nonisolated let name: String
    public nonisolated let offset: Double
    private let source: any RotorDriver
    private let sourceReadings: AsyncStream<RotorReading>
    private var outlet = ReadingOutlet()
    private var pump: Task<Void, Never>?
    private var started = false

    /// - Parameters:
    ///   - source: the rotor being cloned.
    ///   - sourceReadings: a subscription to that rotor's readings (finishes when it goes away).
    public init(name: String, offset: Double, source: any RotorDriver, sourceReadings: AsyncStream<RotorReading>) {
        self.name = name
        self.offset = offset
        self.source = source
        self.sourceReadings = sourceReadings
    }

    public func start() async throws -> AsyncStream<RotorReading> {
        guard !started else { throw TransportError.unsupported("clone already started") }
        started = true
        let out = outlet.makeStream()
        let readings = sourceReadings
        pump = Task { [weak self] in
            for await r in readings { await self?.forward(r) }
            await self?.sourceEnded()
        }
        return out
    }

    public func goTo(_ target: TurnTarget) async {
        switch target.resolved {
        case .heading(let h): await source.goTo(.heading(normalizedHeading(h - offset)))
        case .cw: await source.goTo(.cw)
        case .ccw: await source.goTo(.ccw)
        case .invalid: break
        }
    }

    public func stop() async { await source.stop() }
    public func query() async { await source.query() }

    public func close() async {
        pump?.cancel()
        pump = nil
        outlet.finish()
    }

    private func forward(_ r: RotorReading) {
        outlet.yield(RotorReading(name: name, heading: normalizedHeading(r.heading + offset), status: .clone, rssi: 0))
    }

    private func sourceEnded() { outlet.finish() }
}
