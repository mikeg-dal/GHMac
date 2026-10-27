import AppKit
import Foundation
import Observation
import GHEKit
import GHEServerKit
import GHESimKit

/// The server app's state (the protocol lives in `ServerHub`): settings,
/// log, hub lifecycle, Device Manager, credentials and the simulator wiring.
@Observable
final class ServerAppModel {
    static let shared = ServerAppModel()

    /// Main-window input prompts (Settings ▸ Max connections / Set port).
    enum MainPrompt: String, Identifiable {
        case maxConnections, port
        var id: String { rawValue }
    }

    struct Alert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: State

    let isSimulator: Bool
    let directories: AppDirectories
    var settings: ServerSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    let log: LogBuffer
    let credentials: any CredentialStore
    let deviceManager: DeviceManagerModel
    let wioEditors: WioEditorManager

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var clients: [HubClientInfo] = []
    private(set) var memoryText = ProcessMemory.text
    var mainPrompt: MainPrompt?
    var alert: Alert?
    /// Set by the main window so menus and the menu bar extra can open scenes.
    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private(set) var isShuttingDown = false

    // MARK: Plumbing

    @ObservationIgnored private let registry: DeviceRegistry
    @ObservationIgnored private var hub: ServerHub?
    @ObservationIgnored private var hubEventsTask: Task<Void, Never>?
    @ObservationIgnored private var memoryTimer: Timer?
    @ObservationIgnored private var settingsSaver: Debouncer!
    @ObservationIgnored private var booted = false
    // Simulator only.
    @ObservationIgnored private var scenario: DemoScenario?
    @ObservationIgnored private var memoryListener: MemoryListener?
    @ObservationIgnored private var emulator: JavaClientEmulator?

    private init() {
        let sim = GHESimulator.requestedScenario != nil
        isSimulator = sim
        let dirs = sim ? AppDirectories.temporary(prefix: "GHEServer-Sim")
                       : AppDirectories.applicationSupport(folderName: AppDirectories.serverFolderName)
        directories = dirs
        settings = ServerSettings.load(from: dirs)
        log = LogBuffer(fileURL: dirs.file("ServerLog.txt"))
        registry = DeviceRegistry()
        let resolver: ServerPortResolver
        let factory: any TransportFactory
        let switchState: any SwitchStatePersisting = SwitchStateStore(directory: dirs)
        if sim {
            let s = DemoScenario()
            try? DemoScenario.writeFiles(to: dirs)
            scenario = s
            memoryListener = MemoryListener()
            resolver = s.makePortResolver(ports: PortsIni.load(from: dirs))
            factory = s.transportFactory
            credentials = InMemoryCredentialStore()
        } else {
            resolver = ServerPortResolver(ports: PortsIni.load(from: dirs))
            factory = DefaultTransportFactory(owner: AppInfo.serverName)
            credentials = KeychainCredentialStore()
        }
        let profiles = WioProfileStore(appDirectories: dirs)
        let env = DeviceEnvironment(registry: registry, portResolver: resolver, transportFactory: factory,
                                    clock: scenario?.clock ?? SystemClock(), profiles: profiles, switchState: switchState)
        let logSink = LogSink()
        deviceManager = DeviceManagerModel(environment: env, resolver: resolver, profileStore: profiles,
                                           directories: dirs, log: { logSink.handler?($0) })
        wioEditors = WioEditorManager()
        logSink.handler = { [weak self] in self?.log.append($0) }
        log.logToFile = settings.serverLogging
        settingsSaver = Debouncer { [weak self] in self?.saveSettings() }
        wioEditors.app = self
        deviceManager.requestWindow = { [weak self] in self?.openWindow?(SceneID.deviceManager) }
    }

    /// Late-bound log closure (the model isn't fully initialised when the Device Manager is built).
    private final class LogSink { var handler: ((String) -> Void)? }

    // MARK: Startup

    /// Loads the Device Manager, starts the server, then auto-connects saved devices.
    func boot() async {
        guard !booted else { return }
        booted = true
        log.append("User Files at \(directories.root.path)")
        if isSimulator { log.append("Simulator mode (-GHESimulator \(GHESimulator.requestedScenario ?? "demo")): no ports are opened.") }
        await deviceManager.load()
        if !isSimulator { deviceManager.startPortMonitor() }
        startMemoryTimer()
        await startServer()
        await deviceManager.autoConnect()
        if settings.rotorUiVisible && !isSimulator { launchLocalController(quietly: true) }
    }

    private func startMemoryTimer() {
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryText = ProcessMemory.text }
        }
    }

    // MARK: Server lifecycle

    var hubSettings: HubSettings {
        HubSettings(port: UInt16(clamping: settings.port), maxConnections: settings.maxConnections,
                    authenticate: settings.authenticate, stationLatitude: settings.lat, stationLongitude: settings.lon)
    }

    /// Settings ▸ Start Server. A new hub (and listener) per start, so a changed port takes effect.
    func startServer() async {
        guard !isRunning, !isStarting, !isShuttingDown else { return }
        isStarting = true
        defer { isStarting = false }
        let listener: any StreamListener = memoryListener ?? NWStreamListener(port: UInt16(clamping: settings.port))
        let hub = ServerHub(listener: listener, registry: registry, credentials: credentials, settings: hubSettings)
        self.hub = hub
        let events = hub.events()
        hubEventsTask?.cancel()
        hubEventsTask = Task { [weak self] in
            for await e in events { self?.handle(e) }
        }
        do {
            try await hub.start()
            if isSimulator { await attachSimulatedClient() }
        } catch {
            await hub.shutdown()
            if self.hub === hub { self.hub = nil }
            alert = Alert(title: "Server", message: "Could not open port \(settings.port).\nIt may be in use by another program.")
        }
    }

    /// Settings ▸ Stop Server: every client gets CLOSE, then the listener closes.
    func stopServer() async {
        guard let hub else { return }
        self.hub = nil
        await emulator?.disconnect()
        emulator = nil
        await hub.shutdown()
    }

    private func handle(_ e: HubEvent) {
        switch e {
        case .log(let line): log.append(line)
        case .running(let r): isRunning = r
        case .connections(let c, _): clients = c
        }
    }

    /// Simulator: one emulated client so the log and connection count show something.
    private func attachSimulatedClient() async {
        guard let memoryListener, let conn = try? memoryListener.connect(from: "192.168.1.50") else { return }
        let e = JavaClientEmulator(connection: conn)
        await e.start()
        emulator = e
    }

    // MARK: Settings

    private func settingsChanged(from old: ServerSettings) {
        log.logToFile = settings.serverLogging
        if !settings.serverLogging { log.closeFile() }
        if let hub, settings.maxConnections != old.maxConnections || settings.lat != old.lat || settings.lon != old.lon {
            let s = hubSettings
            Task { await hub.update(s) }   // max connections apply to new accepts at once
        }
        settingsSaver.schedule()
    }

    func saveSettings() {
        if let f = mainWindow?.frame {
            settings.serverWindowWidth = Int(f.width); settings.serverWindowHeight = Int(f.height)
            settings.serverWindowX = Int(f.minX); settings.serverWindowY = Int(f.minY)
        }
        do { try settings.save(to: directories) } catch {
            log.append("***ERROR*** Could not save settings: \(error.localizedDescription)")
        }
    }

    /// 1…65535 with an accurate message.
    func setPort(from text: String) -> String? {
        guard let n = Int(JavaString.trim(text)), (1...65535).contains(n) else {
            return "Port must be a whole number from 1 to 65535."
        }
        settings.port = n
        return nil
    }

    func setMaxConnections(from text: String) -> String? {
        guard let n = Int(JavaString.trim(text)), n > 0 else { return "Must be an integer > 0." }
        settings.maxConnections = n
        return nil
    }

    // MARK: Panels and commands

    func showMainWindow() {
        NSApp.activate()
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(SceneID.main)
        }
    }

    /// Minimise → hide to the menu bar extra.
    func hideMainWindow() { mainWindow?.orderOut(nil) }

    func ask(_ prompt: MainPrompt) {
        showMainWindow()
        mainPrompt = prompt
    }

    /// Launches GHMac Client as Local Controller on this server's port.
    func launchLocalController(quietly: Bool = false) {
        if isSimulator {
            if !quietly {
                alert = Alert(title: "Launch Local Controller",
                              message: "The simulator server has no TCP port. Start GHMac Client with -GHESimulator demo instead.")
            }
            return
        }
        guard let url = LocalControllerLauncher.clientAppURL() else {
            if !quietly {
                alert = Alert(title: "Launch Local Controller",
                              message: "GHMac Client is not installed. Put “GHMac Client.app” next to the server or in Applications.")
            }
            return
        }
        LocalControllerLauncher.launch(url, port: settings.port) { [weak self] error in
            guard let error, !quietly else { return }
            self?.alert = Alert(title: "Launch Local Controller", message: error.localizedDescription)
        }
    }

    // MARK: Shutdown (one path for menu, menu bar extra and window close)

    func shutdown() async {
        guard !isShuttingDown else { return }
        settingsSaver.flush()
        saveSettings()
        isShuttingDown = true
        await stopServer()
        await deviceManager.closeAll()
        deviceManager.saveNow()
        log.closeFile()
        if isSimulator { try? FileManager.default.removeItem(at: directories.root) }
    }
}

/// Scene identifiers.
enum SceneID {
    static let main = "main"
    static let deviceManager = "deviceManager"
    static let users = "users"
    static let changeMaster = "changeMaster"
}
