import Foundation
import GHEKit
import GHEClientKit
import GHEServerKit
import GHESimKit

/// Everything simulator mode swaps in: a temporary settings folder, an in-process GH server on a memory
/// listener, a fake RT-21 for the Terminal Server row, memory logger sources and an in-memory hotkey backend.
/// Nothing touches the network or the user's real settings.
///
/// `-GHESimulator demo` serves the shared `DemoScenario` (real DeviceRegistry over fake hardware);
/// `-GHESimulator scripted` serves the small `DemoRegistry` (it also has a not-responding rotor).
@MainActor
final class SimulatorEnvironment {
    static let serverAddress = "Simulator"
    static let serverPort: UInt16 = 17220

    let directories: AppDirectories
    let scripted: Bool
    private let serverBox = ServerBox()
    let fakeRT21 = FakeRT21Device(heading: 120)
    let datagramSources = SimulatorDatagrams()
    private(set) var server: InProcessServer?

    init(scenario: String) {
        scripted = scenario == "scripted"
        directories = AppDirectories.temporary(prefix: "GHEClient-Sim")
        seedFiles()
    }

    func start() async {
        let srv: InProcessServer
        if scripted {
            let registry = DemoRegistry()
            srv = InProcessServer(registry: registry)
            await registry.start()
            try? await srv.start()
        } else {
            do { srv = try await DemoScenario.makeInProcessServer() } catch {
                GHELog.ui.error("Demo scenario failed: \(error.localizedDescription); using the scripted registry")
                let registry = DemoRegistry()
                srv = InProcessServer(registry: registry)
                await registry.start()
                try? await srv.start()
            }
        }
        server = srv
        await serverBox.set(srv)
    }

    var connectionEnvironment: ConnectionEnvironment {
        let box = serverBox
        let connector = MemoryConnector { _, _ in try await box.get().listener.connect(from: "127.0.0.1") }
        let rt21 = fakeRT21
        let clock = SystemClock()
        return ConnectionEnvironment(clock: clock, resolve: { name in
            let t = JavaString.trim(name)
            return t.isEmpty ? nil : t
        }, makeConnection: { request in
            switch request.kind {
            case .ghServer:
                return GHServerConnection(id: request.id, user: request.user, passwordHash: request.passwordHash,
                                          connector: connector, clock: clock, traffic: request.traffic)
            case .terminalServerTCP:
                return TerminalServerConnection(id: request.id, rotorName: request.rotorName, poll: request.terminalPoll,
                                                makeTransport: { _, _ in rt21.makeTransport() },
                                                leases: EndpointLeases(), clock: clock, traffic: request.traffic)
            }
        })
    }

    var loggerTransports: LoggerTransports {
        let d = datagramSources
        return LoggerTransports(makeDatagramSource: { d.source(for: $0.port) },
                                connector: MemoryConnector { _, _ in throw TransportError.openFailed("Simulator: no N3FJP") })
    }

    /// The demo's saved state: the simulator row auto-connects; "4L40" is a 40 m-only antenna so the
    /// band filter has something to hide.
    private func seedFiles() {
        let rows = [
            SavedServerRow(address: Self.serverAddress, port: String(Self.serverPort), user: "demo", kind: .ghServer, autoConnect: true),
            SavedServerRow(address: "RT21-Sim", port: "6555", rotorName: "Direct", kind: .terminalServerTCP, autoConnect: false),
        ]
        try? ServerRowStore(directory: directories).save(rows)
        try? PresetStore(directory: directories).save([
            RotorPreset(name: "EU", heading: "45"), RotorPreset(name: "JA", heading: "330"),
            RotorPreset(name: "W6", heading: "290"), RotorPreset(name: "VK", heading: "250"),
            RotorPreset(name: "ZS", heading: "110"), RotorPreset(name: "PY", heading: "160"),
            RotorPreset(name: "KH6", heading: "280"), RotorPreset(name: "UA9", heading: "20"),
        ])
        let store = RotorDeviceStore(directory: directories)
        let scope = BandScope.hfContest
        let names = scripted ? DemoRegistry.rotorNames
            : [DemoScenario.Names.tower1, DemoScenario.Names.tower2, DemoScenario.Names.tower3, DemoScenario.Names.fixed,
               DemoScenario.Names.clone, DemoScenario.Names.remoteTower]
        for (i, name) in names.enumerated() {
            let key = ItemKey(server: ServerID(host: Self.serverAddress, port: Self.serverPort), name: name).legacyKey
            var s = store.load(key: key, scope: scope)
            s.priority = 100 + i * 10
            s.mapPriority = 100 + i * 10
            s.mapBands = LegacyBandList.hfUnionVHF
            // A 40 m-only antenna, so the band filter has something to hide.
            if name == "4L40" || name == DemoScenario.Names.tower2 { s.trayBands = ["40M"]; s.beamWidth = 50 }
            try? store.save(key: key, s)
        }
    }
}

/// Logger sockets are replaced by memory sources in simulator mode (nothing listens on the network).
nonisolated final class SimulatorDatagrams: Sendable {
    func source(for port: UInt16) -> any DatagramSource { MemoryDatagramSource() }
}

/// Hands the in-process server to connections, waiting until it has started.
private actor ServerBox {
    private var server: InProcessServer?
    private var waiters: [CheckedContinuation<InProcessServer, Never>] = []

    func set(_ s: InProcessServer) {
        server = s
        for w in waiters { w.resume(returning: s) }
        waiters = []
    }

    func get() async -> InProcessServer {
        if let server { return server }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
