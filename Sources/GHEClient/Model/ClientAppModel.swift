import AppKit
import Observation
import GHEKit
import GHEClientKit
import GHESimKit

/// The client's main-actor state: wires the kits (connections, loggers, hotkeys, persistence) to the
/// windows. Views read it from the environment; window plumbing lives in `WindowManager`.
@MainActor @Observable
final class ClientAppModel {
    let isSimulator: Bool
    /// `-LocalController <port>` (the Server's "Launch Local Controller…"): connect to 127.0.0.1:<port>.
    let localControllerPort: UInt16?
    let directories: AppDirectories
    let connections: ConnectionManager
    @ObservationIgnored let loggers: LoggerSupervisor
    @ObservationIgnored let hotkeys: HotkeyEngine
    @ObservationIgnored let hotkeyBackend: any HotkeyBackend
    @ObservationIgnored let simulator: SimulatorEnvironment?
    @ObservationIgnored let passwords: PasswordVault
    @ObservationIgnored weak var windows: WindowManager?

    /// settings.ini; every change is saved (debounced).
    var settings: ClientSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    /// Current band of VFO-A / VFO-B.
    var bands = BandState()
    var presets: [RotorPreset]
    var buttonColors: [String: SwitchButtonColor]
    var switchWindowConfig: SwitchWindowsConfig
    var mapSettings: RotorMapSettings
    var mapVisibility: [String: Bool]
    /// Bumped when per-device settings (bands, order, beam, colour) change.
    var deviceRevision = 0
    /// Bumped when hotkey bindings change (captions, tooltips).
    var hotkeyRevision = 0
    /// File ▸ Lock Window Positions.
    var windowsLocked = false
    /// Software Control ▸ Test communication… log lines.
    var softwareLog: [String] = []
    /// Preset windows' "Keep visible" boxes, by frame name ("<short> preset selection" / "Global preset selection").
    var presetKeepVisible: [String: Bool] = [:]
    /// presetFrames.xml as loaded (positions and visibility of the preset windows).
    @ObservationIgnored var presetFrameStates: [String: PresetFrameState] = [:]
    /// Optimistic switch selections until the server echoes (key → position).
    var pendingSwitch: [ItemKey: String] = [:]
    /// Position shown with the "momentary" colour while a switch reports UNKNOWN.
    @ObservationIgnored var previousSwitchPosition: [ItemKey: String] = [:]
    /// Hidden "Sticky Port" feature (w2fu.txt): map switch → its sticky position.
    @ObservationIgnored var stickyPositions: [ItemKey: String] = [:]
    @ObservationIgnored var stickyMonitor: ModemLineMonitor?
    @ObservationIgnored var stickyTask: Task<Void, Never>?
    var stickyPortPath: String?
    /// Set by Restore Defaults: quit without writing anything back.
    @ObservationIgnored var skipSaveOnQuit = false

    @ObservationIgnored private var rotorDeviceCache: [String: RotorDeviceSettings] = [:]
    @ObservationIgnored private var switchDeviceCache: [String: SwitchDeviceSettings] = [:]
    @ObservationIgnored var panelStates: [ItemKey: RotorPanelState] = [:]
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    // Stores.
    @ObservationIgnored var settingsStore: ClientSettingsStore { ClientSettingsStore(directory: directories) }
    @ObservationIgnored var rotorStore: RotorDeviceStore { RotorDeviceStore(directory: directories) }
    @ObservationIgnored var switchStore: SwitchDeviceStore { SwitchDeviceStore(directory: directories) }

    init() {
        if let scenario = GHESimulator.requestedScenario {
            let sim = SimulatorEnvironment(scenario: scenario)
            simulator = sim
            isSimulator = true
            directories = sim.directories
            connections = ConnectionManager(environment: sim.connectionEnvironment)
            loggers = LoggerSupervisor(transports: sim.loggerTransports)
            hotkeyBackend = InMemoryHotkeyBackend()
            passwords = PasswordVault(inMemory: true)
        } else {
            simulator = nil
            isSimulator = false
            let base = AppDirectories.applicationSupport(folderName: AppDirectories.clientFolderName)
            // Local-controller settings live in their own LocalController/ sub-folder.
            directories = Self.localControllerArgument != nil ? base.subdirectory("LocalController") : base
            connections = ConnectionManager(environment: .live())
            loggers = LoggerSupervisor(transports: LoggerTransports(
                makeDatagramSource: { UDPDatagramSocket(port: $0.port, bindAddress: $0.host) },
                connector: NWStreamConnector()))
            hotkeyBackend = CarbonHotkeyBackend()
            passwords = PasswordVault(inMemory: false)
        }
        localControllerPort = isSimulator ? nil : Self.localControllerArgument
        let dirs = directories
        settings = ClientSettingsStore(directory: dirs).load()
        presets = PresetStore(directory: dirs).load()
        buttonColors = ButtonColorStore(directory: dirs).load()
        switchWindowConfig = SwitchWindowStore(directory: dirs).load()
        mapSettings = RotorMapStore(directory: dirs).load()
        mapVisibility = RotorMapStore(directory: dirs).visibility()
        hotkeys = HotkeyEngine(backend: hotkeyBackend, bindings: HotkeyStore(directory: dirs).load())
        bands = BandState(a: settings.bandA, b: Band.allName)
        for f in PresetFramesStore(directory: dirs).load() where presetFrameStates[f.name] == nil {
            presetFrameStates[f.name] = f
            presetKeepVisible[f.name] = f.keepVisible
        }
        installImagesFolder()
        wireConnections()
        wireHotkeys()
    }

    /// Starts the simulator, the logger monitors, loads the Servers rows and auto-connects them.
    func start() {
        tasks.append(Task {
            if let simulator { await simulator.start() }
            await self.loggers.apply(self.settings.loggerConfiguration())
        })
        tasks.append(Task {
            for await event in self.loggers.events() { self.handleLogger(event) }
        })
        loadServerRows()
        // Sleeps 1 s, then reconnects the rows that were connected at quit.
        tasks.append(Task {
            try? await Task.sleep(for: isSimulator ? .milliseconds(200) : .seconds(1))
            self.autoConnectRows()
            if self.isSimulator { await self.injectSimulatedTornado() }
        })
    }

    // MARK: Settings

    private func settingsDidChange(from old: ClientSettings) {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.saveSettingsNow()
        }
        if old.loggerConfiguration() != settings.loggerConfiguration() {
            let config = settings.loggerConfiguration()
            Task { await self.loggers.apply(config) }
        }
        if old.bandScope != settings.bandScope { deviceRevision += 1 }
    }

    func saveSettingsNow() {
        guard !skipSaveOnQuit else { return }
        var s = settings
        s.bandA = bands.a
        s.bandB = bands.b
        try? settingsStore.save(s)
    }

    func savePresets(_ list: [RotorPreset]) {
        presets = RotorPresets.sanitized(list)
        try? PresetStore(directory: directories).save(presets)
    }

    // MARK: Per-device settings

    func rotorSettings(_ key: ItemKey) -> RotorDeviceSettings {
        let k = key.legacyKey
        if let s = rotorDeviceCache[k] { return s }
        let s = (try? rotorStore.loadOrCreate(key: k, scope: settings.bandScope)) ?? rotorStore.load(key: k, scope: settings.bandScope)
        rotorDeviceCache[k] = s
        return s
    }

    func updateRotorSettings(_ key: ItemKey, _ body: (inout RotorDeviceSettings) -> Void) {
        var s = rotorSettings(key)
        body(&s)
        rotorDeviceCache[key.legacyKey] = s
        try? rotorStore.save(key: key.legacyKey, s)
        deviceRevision += 1
    }

    func switchSettings(_ key: ItemKey) -> SwitchDeviceSettings {
        let k = key.legacyKey
        if let s = switchDeviceCache[k] { return s }
        let s = (try? switchStore.loadOrCreate(key: k, scope: settings.bandScope)) ?? switchStore.load(key: k, scope: settings.bandScope)
        switchDeviceCache[k] = s
        return s
    }

    func updateSwitchSettings(_ key: ItemKey, _ body: (inout SwitchDeviceSettings) -> Void) {
        var s = switchSettings(key)
        body(&s)
        switchDeviceCache[key.legacyKey] = s
        try? switchStore.save(key: key.legacyKey, s)
        deviceRevision += 1
    }

    func switchWindow(_ key: ItemKey) -> SwitchWindowConfig {
        switchWindowConfig.switches[key.legacyKey] ?? SwitchWindowConfig()
    }

    /// Switch window settings are saved on every change, not only at shutdown.
    func updateSwitchWindow(_ key: ItemKey, _ body: (inout SwitchWindowConfig) -> Void) {
        var c = switchWindow(key)
        body(&c)
        switchWindowConfig.switches[key.legacyKey] = c
        try? SwitchWindowStore(directory: directories).save(switchWindowConfig)
    }

    func setButtonColor(_ color: SwitchButtonColor?, switchKey: ItemKey, position: String) {
        let k = ButtonColorStore.key(switchKey: switchKey.legacyKey, position: position)
        buttonColors[k] = color
        try? ButtonColorStore(directory: directories).set(color, switchKey: switchKey.legacyKey, position: position)
    }

    func buttonColor(switchKey: ItemKey, position: String) -> SwitchButtonColor? {
        buttonColors[ButtonColorStore.key(switchKey: switchKey.legacyKey, position: position)]
    }

    func saveMapSettings() {
        guard !skipSaveOnQuit else { return }
        try? RotorMapStore(directory: directories).save(mapSettings)
    }

    func setMapVisible(_ visible: Bool, shortName: String) {
        mapVisibility[shortName] = visible
        try? RotorMapStore(directory: directories).setVisible(visible, shortName: shortName)
    }

    func isOnMapLegendChecked(_ shortName: String) -> Bool { mapVisibility[shortName] ?? true }

    // MARK: Images

    var imagesDirectory: AppDirectories { directories.subdirectory(ClientFileName.imagesFolder) }

    /// The default map background: `Images/compass.png`, copied from the bundle on first run.
    var defaultCompassURL: URL { imagesDirectory.file("compass.png") }

    private func installImagesFolder() {
        let dest = defaultCompassURL
        if !FileManager.default.fileExists(atPath: dest.path), let src = Bundle.main.url(forResource: "compass", withExtension: "png") {
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }

    // MARK: Shutdown

    /// Shutdown order: switches, settings, preset windows, server rows, monitors, servers.
    func shutdown() async {
        if !skipSaveOnQuit {
            windows?.saveAllWindowFrames()
            saveSettingsNow()
            saveServerRows()
            saveMapSettings()
            try? HotkeyStore(directory: directories).save(hotkeys.bindings)
        }
        hotkeyBackend.unregisterAll()
        await loggers.stop()
        await connections.disconnectAll()
        if isSimulator { await simulator?.server?.stop() }
    }

    /// The tray title.
    var trayTitle: String {
        switch settings.loggerSource {
        case .n1mm: "GHMac - N1MM Control"
        case .n3fjp: "GHMac - N3FJP Control"
        case .wintest: "GHMac - Win-Test Control"
        case .manual: "GHMac - \(bands.a)"
        }
    }

    // MARK: Connections

    private func wireConnections() {
        connections.isVisible = { [weak self] key in self?.isTrayVisible(key) ?? true }
        connections.restoreActive = { [weak self] key in self?.rotorSettings(key).active }
        connections.passwordHashLookup = { [weak self] user in self?.passwords.hash(for: user) }
        connections.didComputePasswordHash = { [weak self] hash, user in
            guard let self, self.settings.savePasswords else { return }
            self.passwords.store(hash, for: user)
        }
    }

    func loadServerRows() {
        let rows = ServerRowStore(directory: directories).load()
        for (i, row) in rows.enumerated() where i < connections.supervisors.count {
            connections.supervisors[i].config = ServerRowConfig(address: row.address, port: row.port, kind: row.kind,
                                                                user: row.user, rotorName: row.rotorName)
        }
    }

    static var localControllerArgument: UInt16? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LocalController"), i + 1 < args.count else { return nil }
        return UInt16(args[i + 1]).flatMap { $0 > 0 ? $0 : nil }
    }

    private func autoConnectRows() {
        if let port = localControllerPort {
            // Local controller: row 1 is the local server (authentication off), connected at once.
            let s = connections.supervisors[0]
            s.config = ServerRowConfig(address: "127.0.0.1", port: String(port), kind: .ghServer)
            if s.state == .disconnected { s.toggle() }
            return
        }
        let rows = ServerRowStore(directory: directories).load()
        for (i, row) in rows.enumerated() where i < connections.supervisors.count && row.autoConnect {
            connections.supervisors[i].toggle()
        }
    }

    func saveServerRows() {
        guard !skipSaveOnQuit else { return }
        let rows = connections.supervisors.map { s in
            SavedServerRow(address: s.config.address, port: s.config.port, user: s.config.user,
                           rotorName: s.config.rotorName, kind: s.config.kind, autoConnect: s.state != .disconnected)
        }
        try? ServerRowStore(directory: directories).save(rows)
        let names = RotorNamesStore(directory: directories)
        for s in connections.supervisors where s.config.kind == .terminalServerTCP && !s.config.rotorName.isEmpty {
            if let port = UInt16(s.config.port) { try? names.setName(s.config.rotorName, host: s.config.address, port: port) }
        }
    }

    /// Supervisor for a server, for tooltips ("Server: … IP Addr: … Port: …").
    func serverDescription(_ server: ServerID) -> (name: String, address: String, port: String) {
        let s = connections.supervisors.first { $0.serverID == server }
        return (s?.config.address ?? server.host, server.host, String(server.port))
    }

    /// The GH server never sends Tornado messages (client-understood only); the demo injects one.
    private func injectSimulatedTornado() async {
        let sid = ServerID(host: SimulatorEnvironment.serverAddress, port: SimulatorEnvironment.serverPort)
        for _ in 0..<50 where connections.supervisor(for: sid)?.state != .connected {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(300))
        connections.apply(.tornadoAdd(TornadoDescriptor(name: "Tornado", rotors: ["Elem1", "Elem2"],
                                                        positions: ["20M", "15M", "10M"],
                                                        lower: ["14.0", "21.0", "28.0"], upper: ["14.35", "21.45", "29.7"])), from: sid)
        connections.apply(.tornado(TornadoState(name: "Tornado", status: 0, rssi: -66, position: "20M", headings: ["90", "270"])), from: sid)
    }

    func logSoftware(_ line: String) {
        softwareLog.append(line)
        if softwareLog.count > 500 { softwareLog.removeFirst(softwareLog.count - 500) }
    }
}
