import Foundation
import Synchronization
import GHEKit
import GHEServerKit

/// The shared `-GHESimulator demo` world used by both apps: simulated ports backed by fake devices,
/// a demo Device Manager (two RT-21s, a DCU-1, a Fixed antenna at 999°, a Cloned antenna and a Base
/// with a buttons switch, a band switch, a 4-square map, an on/off bank, a stack match, a remote RT-21
/// and a virtual switch) and its WIO profiles. Nothing here touches the network or real serial ports.
public final class DemoScenario: Sendable {
    /// Simulated port names as they appear in the Device Manager's Port list.
    public enum Ports {
        public static let rt21One = "SIM-RT21-1"
        public static let rt21Two = "SIM-RT21-2"
        public static let dcu1 = "SIM-DCU1-1"
        public static let wio = "SIM-WIO-1"
    }

    /// Device names used by the demo rows.
    public enum Names {
        public static let tower1 = "Tower 1"
        public static let tower2 = "Tower 2"
        public static let tower3 = "Tower 3"
        public static let fixed = "Dipole"
        public static let clone = "Tower 1 Back"
        public static let antennaSwitch = "Antenna Switch"
        public static let bandDecoder = "Band Decoder"
        public static let fourSquare = "4-Square"
        public static let preamps = "Preamps"
        public static let stack = "Top,Middle,Bottom"
        public static let remoteTower = "Remote Tower"
        public static let beamSelector = "Beam Selector"
    }

    /// Port name → simulated device id (`Endpoint.simulated`).
    public static let simulatedPorts: [(name: String, id: String)] = [
        (Ports.rt21One, "rt21-1"), (Ports.rt21Two, "rt21-2"), (Ports.dcu1, "dcu1-1"), (Ports.wio, "wio-1"),
    ]

    public let clock: any GHEClock
    public let rotor1: FakeRT21Device
    public let rotor2: FakeRT21Device
    public let dcu1: FakeDCU1Device
    /// Base with remotes 1–5 (switches, stack) and an RT-21 behind remote 6.
    public let wioBase: FakeWIOBase
    /// Private leases so the demo never collides with real devices in the same process.
    public let leases = EndpointLeases()
    private let retained = Mutex<[DeviceSlotController]>([])

    /// - Parameter degreesPerSecond: rotation speed of the fake rotors.
    public init(clock: any GHEClock = SystemClock(), degreesPerSecond: Double = 5) {
        self.clock = clock
        var o = FakeRT21Device.Options()
        o.degreesPerSecond = degreesPerSecond
        rotor1 = FakeRT21Device(heading: 45, clock: clock, options: o)
        rotor2 = FakeRT21Device(heading: 270, clock: clock, options: o)
        dcu1 = FakeDCU1Device(heading: 180, clock: clock, degreesPerSecond: degreesPerSecond)
        wioBase = FakeWIOBase(remotes: [1: 40, 2: 45, 3: 50, 4: 42, 5: 38], rotors: [6: 135], clock: clock)
    }

    // MARK: Ports and transports

    /// Serves the simulated ports: a fresh link per open for rotors, the one fake Base for the WIO port.
    public var transportFactory: DefaultTransportFactory {
        let r1 = rotor1, r2 = rotor2, d = dcu1.core, base = wioBase
        return DefaultTransportFactory(leases: leases, owner: "Simulator") { id in
            switch id {
            case "rt21-1": FakeDeviceTransport(device: r1)
            case "rt21-2": FakeDeviceTransport(device: r2)
            case "dcu1-1": FakeDeviceTransport(device: d)
            case "wio-1": base
            default: nil
            }
        }
    }

    /// A resolver listing only the simulated ports (plus any ports.ini keys), never real serial ports.
    public func makePortResolver(ports: PortsIni = PortsIni(), extraNames: [String] = []) -> ServerPortResolver {
        ServerPortResolver(ports: ports, extraNames: extraNames, simulated: Self.simulatedPorts, serialPorts: { [] })
    }

    // MARK: Device Manager

    /// The demo `DeviceManager.xml`: 100 rows, the first twelve used, all set to auto-connect.
    public static func panels() -> [DevicePanelConfig] {
        var rows = DeviceManagerXML.blankPanels()
        func set(_ i: Int, _ name: String, _ port: String, _ type: DeviceType, sub: String = "N/A", addr: Int? = nil,
                 fixed: Double? = nil, clone: Double? = nil) {
            rows[i] = DevicePanelConfig(order: i, name: name, port: port, deviceType: type.rawValue, subType: sub,
                                        wioAddress: addr, initialState: true, fixedHeading: fixed, cloneOffset: clone)
        }
        set(0, Names.tower1, Ports.rt21One, .rt21)
        set(1, Names.tower2, Ports.rt21Two, .rt21)
        set(2, Names.tower3, Ports.dcu1, .dcu1)
        // A fixed heading above 360 makes clients show "---".
        set(3, Names.fixed, DevicePanelConfig.notApplicable, .fixedAntenna, fixed: 999)
        set(4, Names.clone, Ports.rt21One, .clonedAntenna, clone: 180)
        set(5, Names.antennaSwitch, Ports.wio, .gheBase, sub: DemoProfiles.buttonsName, addr: 1)
        set(6, Names.bandDecoder, Ports.wio, .gheBase, sub: DemoProfiles.bandName, addr: 2)
        set(7, Names.fourSquare, Ports.wio, .gheBase, sub: DemoProfiles.mapName, addr: 3)
        set(8, Names.preamps, Ports.wio, .gheBase, sub: DemoProfiles.bankName, addr: 4)
        set(9, Names.stack, Ports.wio, .gheBase, sub: WIOStackType.stackMatchLow.subTypeName, addr: 5)
        set(10, Names.remoteTower, Ports.wio, .gheBase, sub: WIOSubtypes.rt21, addr: 6)
        set(11, Names.beamSelector, Ports.wio, .virtualSwitch, sub: DemoProfiles.virtualName, addr: 0)
        return rows
    }

    /// The environment every demo row shares.
    public func makeEnvironment(registry: DeviceRegistry, portResolver: (any PortResolver)? = nil,
                                profiles: (any WioProfileLookup)? = nil,
                                switchState: any SwitchStatePersisting = InMemorySwitchStateStore()) -> DeviceEnvironment {
        DeviceEnvironment(registry: registry, portResolver: portResolver ?? makePortResolver(),
                          transportFactory: transportFactory, clock: clock,
                          profiles: profiles ?? StaticProfileLookup(DemoProfiles.all), switchState: switchState)
    }

    /// A registry plus one slot per Device Manager row (100), none connected yet.
    public func makeRegistry(panels: [DevicePanelConfig] = DemoScenario.panels())
        -> (registry: DeviceRegistry, environment: DeviceEnvironment, slots: [DeviceSlotController]) {
        let registry = DeviceRegistry()
        let env = makeEnvironment(registry: registry)
        let slots = panels.map { DeviceSlotController(config: $0, environment: env) }
        return (registry, env, slots)
    }

    /// Connects every `initialState` row in `order`, one after another so clones find their source.
    public static func connectAll(_ slots: [DeviceSlotController]) async {
        var sorted: [(Int, DeviceSlotController)] = []
        for s in slots {
            let c = await s.config
            if c.initialState && !c.isEmpty { sorted.append((c.order, s)) }
        }
        for (_, s) in sorted.sorted(by: { $0.0 < $1.0 }) { await s.connect() }
    }

    /// A running in-memory server fed by a real `DeviceRegistry` with every demo row connected.
    /// The scenario keeps the slots alive.
    public func makeInProcessServer(settings: HubSettings = HubSettings(),
                                    credentials: any CredentialLookup = InMemoryCredentials()) async throws -> InProcessServer {
        let (registry, _, slots) = makeRegistry()
        retained.withLock { $0 += slots }
        let server = InProcessServer(registry: registry, credentials: credentials, settings: settings, clock: clock)
        try await server.start()
        await Self.connectAll(slots)
        return server
    }

    /// Convenience for the client app: a new scenario on the system clock, kept alive for the process.
    public static func makeInProcessServer(settings: HubSettings = HubSettings()) async throws -> InProcessServer {
        let scenario = DemoScenario()
        live.withLock { $0.append(scenario) }
        return try await scenario.makeInProcessServer(settings: settings)
    }

    private static let live = Mutex<[DemoScenario]>([])

    // MARK: Files

    /// Writes the demo `DeviceManager.xml` and `wioProfiles/*.xml` into a (temporary) server folder.
    public static func writeFiles(to dirs: AppDirectories) throws {
        try DeviceManagerXML.write(panels(), to: dirs.file(DeviceManagerXML.fileName))
        let profiles = dirs.subdirectory(WioProfileStore.directoryName)
        for p in DemoProfiles.all { try WioProfileXML.write(p, to: profiles.file(DemoProfiles.fileName(for: p))) }
    }
}
