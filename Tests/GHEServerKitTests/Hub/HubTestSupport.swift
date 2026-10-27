import Foundation
import Synchronization
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

/// Joins fields with US (U+001F), the GH field separator.
func wire(_ fields: String...) -> String { fields.joined(separator: "\u{1F}") }

/// A one-shot gate a mock device can wait on.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// A scriptable device registry that records every command.
actor MockRegistry: DeviceRegistryProtocol {
    enum Call: Equatable, Sendable {
        case turn(String, TurnTarget)
        case turnFinished(String)
        case stop(String)
        case query(String)
        case setStack(String, Bool)
        case setSwitch(String, String, Bool?)
    }

    private let events = EventBroadcaster<RegistryEvent>()
    var snapshot = RegistryInventory()
    private(set) var calls: [Call] = []
    var switchResult: SwitchCommandResult = .ok
    /// If set, `turn` for this rotor waits on the gate before finishing.
    var slowRotor: String?
    let gate = TestGate()

    init(rotors: [String] = [], switches: [SwitchDescriptor] = [], stacks: [[String]] = [],
         readings: [RotorReading] = []) {
        snapshot.rotors = rotors
        snapshot.switches = switches
        snapshot.stacks = stacks
        for r in readings { snapshot.lastReadings[r.name] = r }
    }

    func subscribe() -> AsyncStream<RegistryEvent> { events.subscribe() }
    func inventory() -> RegistryInventory { snapshot }

    func turn(_ rotor: String, _ target: TurnTarget) async {
        calls.append(.turn(rotor, target))
        if rotor == slowRotor {
            await gate.wait()
            calls.append(.turnFinished(rotor))
        }
    }
    func stop(_ rotor: String) async { calls.append(.stop(rotor)) }
    func query(_ rotor: String) async { calls.append(.query(rotor)) }
    func setStack(_ antenna: String, _ selected: Bool) async { calls.append(.setStack(antenna, selected)) }
    func setSwitch(_ name: String, _ position: String, _ on: Bool?) async -> SwitchCommandResult {
        calls.append(.setSwitch(name, position, on))
        return switchResult
    }

    // Test controls
    func emit(_ e: RegistryEvent) { events.yield(e) }
    func setSlowRotor(_ name: String?) { slowRotor = name }
    func setSwitchResult(_ r: SwitchCommandResult) { switchResult = r }
    func clearCalls() { calls.removeAll() }
    /// Calls other than inventory queries.
    var commandCalls: [Call] { calls.filter { if case .query = $0 { return false } else { return true } } }
}

/// Collects hub events (log lines etc.).
final class HubEventLog: Sendable {
    private final class Store: Sendable {
        let items = Mutex<[HubEvent]>([])
    }
    private let store = Store()
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ hub: ServerHub) {
        let stream = hub.events()
        let store = store
        let t = Task {
            for await e in stream { store.items.withLock { $0.append(e) } }
        }
        task.withLock { $0 = t }
    }

    var events: [HubEvent] { store.items.withLock { $0 } }
    var logLines: [String] {
        events.compactMap { if case .log(let s) = $0 { return s } else { return nil } }
    }
    func contains(_ prefix: String) -> Bool { logLines.contains { $0.hasPrefix(prefix) } }
    var lastConnectionCount: Int? {
        for e in events.reversed() { if case .connections(let c, _) = e { return c.count } }
        return nil
    }
    deinit { task.withLock { $0?.cancel() } }
}

/// Everything a hub test needs.
struct HubFixture: Sendable {
    let server: InProcessServer
    let registry: MockRegistry
    let clock: ManualClock
    let log: HubEventLog
    var hub: ServerHub { server.hub }

    static let alicePassword = "secret1"

    static func make(registry: MockRegistry = MockRegistry(), authenticate: Bool = false, maxConnections: Int = 4,
                     allowRestart: Bool = true, latitude: Double = 0, longitude: Double = 0) async throws -> HubFixture {
        let clock = ManualClock()
        let settings = HubSettings(maxConnections: maxConnections, authenticate: authenticate, allowRestart: allowRestart,
                                   stationLatitude: latitude, stationLongitude: longitude)
        let server = InProcessServer(registry: registry,
                                     credentials: InMemoryCredentials(passwords: ["alice": alicePassword]),
                                     settings: settings, clock: clock)
        let log = HubEventLog(server.hub)
        try await server.start()
        return HubFixture(server: server, registry: registry, clock: clock, log: log)
    }

    func connect(from address: String = "127.0.0.1") async throws -> JavaClientEmulator {
        try await server.connectEmulator(from: address)
    }

    /// Connects and waits until the hub counts the connection.
    func connectAndWait(from address: String = "127.0.0.1", expectedCount: Int) async throws -> JavaClientEmulator {
        let c = try await connect(from: address)
        let hub = hub
        _ = await eventually { await hub.connectionCount == expectedCount }
        return c
    }

    func waitForCalls(_ expected: [MockRegistry.Call]) async -> Bool {
        let registry = registry
        return await eventually { await registry.commandCalls == expected }
    }
}
