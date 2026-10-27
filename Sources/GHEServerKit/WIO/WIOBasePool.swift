import Foundation
import GHEKit

/// One `WIOBase` per port name, shared by every device on that port (`DeviceFactory.wioMap`).
/// A dead Base is replaced on the next acquire. Concurrent acquires share one open/validate.
public actor WIOBasePool {
    private var bases: [String: Task<WIOBase, any Error>] = [:]
    private let clock: any GHEClock

    public init(clock: any GHEClock) { self.clock = clock }

    /// The live Base on `portName`, opening (and validating) it if needed.
    /// The first device to open a port decides Base PTT.
    public func base(portName: String, basePTT: Bool,
                     makeTransport: @escaping @Sendable () -> any ByteTransport) async throws -> WIOBase {
        if let existing = bases[portName] {
            if let b = try? await existing.value, await b.isAlive { return b }
            if bases[portName] == existing { bases[portName] = nil }
        }
        if let raced = bases[portName] { return try await raced.value }
        let clock = self.clock
        let task = Task<WIOBase, any Error> {
            let b = WIOBase(portName: portName, transport: makeTransport(), clock: clock, basePTT: basePTT)
            try await b.open()
            return b
        }
        bases[portName] = task
        do {
            return try await task.value
        } catch {
            if bases[portName] == task { bases[portName] = nil }
            throw error
        }
    }

    /// The Base on a port if one is open (clone lookup must not open one).
    public func existingBase(portName: String) async -> WIOBase? {
        guard let t = bases[portName], let b = try? await t.value, await b.isAlive else { return nil }
        return b
    }
}

/// Where cloned antennas find their source rotor.
/// Entries are removed when the source closes, and each source's readings are fanned out
/// so clones can subscribe and unsubscribe.
public actor RotorSourceDirectory {
    public struct Source: Sendable {
        public let driver: any RotorDriver
        public let readings: EventBroadcaster<RotorReading>
    }
    private var sources: [String: Source] = [:]

    public init() {}

    public static func directKey(port: String) -> String { "port:\(port)" }
    public static func wioKey(port: String, address: Int) -> String { "wio:\(port)#\(address)" }

    public func register(_ key: String, driver: any RotorDriver, readings: EventBroadcaster<RotorReading>) {
        sources[key] = Source(driver: driver, readings: readings)
    }

    public func unregister(_ key: String, driver: any RotorDriver) {
        if let s = sources[key], s.driver === driver { sources[key] = nil }
    }

    public func source(_ key: String) -> Source? { sources[key] }
}
