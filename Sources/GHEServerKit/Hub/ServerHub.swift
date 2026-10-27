import Foundation
import GHEKit

/// The GH protocol server: listener, connections, inventory, broadcasts, locks and RESTART.
public actor ServerHub: CommandHost {
    public enum HubError: Error, Equatable { case alreadyRunning }

    private let listener: any StreamListener
    private let registry: any DeviceRegistryProtocol
    private let credentials: any CredentialLookup
    private let clock: any GHEClock
    public private(set) var settings: HubSettings

    private let hubEvents = EventBroadcaster<HubEvent>()

    public private(set) var isRunning = false
    private var acceptTask: Task<Void, Never>?
    private var registryTask: Task<Void, Never>?
    private var subscribed = false

    private var nextID: UInt64 = 0
    /// Every live connection, authenticated or not, in accept order.
    private var connections: [UInt64: ClientConnection] = [:]
    private var order: [UInt64] = []
    /// Connections that receive inventory and broadcasts (nothing goes to the rest).
    private var authenticated: [UInt64: String?] = [:]
    /// Rotor name → owning client IP (keyed by IP, not connection).
    private var locks: [String: String] = [:]
    private var mirror = InventoryMirror()

    public init(listener: any StreamListener, registry: any DeviceRegistryProtocol,
                credentials: any CredentialLookup, settings: HubSettings = HubSettings(),
                clock: any GHEClock = SystemClock()) {
        self.listener = listener
        self.registry = registry
        self.credentials = credentials
        self.settings = settings
        self.clock = clock
    }

    // MARK: Observation

    /// Log lines, running state and connection-list changes for the server UI.
    public nonisolated func events() -> AsyncStream<HubEvent> { hubEvents.subscribe() }

    public var clients: [HubClientInfo] {
        order.compactMap { id in
            guard let c = connections[id] else { return nil }
            let auth = authenticated[id]
            return HubClientInfo(id: id, address: c.address, authenticated: auth != nil, user: auth ?? nil)
        }
    }

    public var connectionCount: Int { connections.count }

    /// Applies new settings. `maxConnections` and `allowRestart` take effect at once; `authenticate` is
    /// sampled per new connection; `port` is informational (the listener owns the socket).
    public func update(_ newSettings: HubSettings) {
        settings = newSettings
        publishConnections()
    }

    // MARK: Lifecycle

    /// Opens the listener and starts accepting. Throws if the listener can't bind.
    public func start() async throws {
        guard !isRunning else { throw HubError.alreadyRunning }
        await subscribeIfNeeded()
        let incoming: AsyncStream<any StreamConnection>
        do {
            incoming = try await listener.start()
        } catch {
            log("Could not open port \(settings.port).\nIt may be in use by another program.")
            throw error
        }
        isRunning = true
        acceptTask = Task { [weak self] in
            for await conn in incoming {
                guard let self else { await conn.close(); return }
                await self.accept(conn)
            }
        }
        log("Server started.")
        hubEvents.yield(.running(true))
        publishConnections()
    }

    /// Sends `CLOSE` to every client, closes their sockets and the listener.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        acceptTask?.cancel()
        acceptTask = nil
        await listener.stop()
        for id in order { connections[id]?.closeWithCLOSE() }
        connections.removeAll()
        order.removeAll()
        authenticated.removeAll()
        log("Server stopped.")
        hubEvents.yield(.running(false))
        publishConnections()
    }

    /// Stop then start on the same listener.
    public func restart() async throws {
        await stop()
        try await start()
    }

    /// Stops the server and the registry subscription for good.
    public func shutdown() async {
        await stop()
        registryTask?.cancel()
        registryTask = nil
        hubEvents.finish()
    }

    private func subscribeIfNeeded() async {
        guard !subscribed else { return }
        subscribed = true
        // Subscribe first, then snapshot: events in between are in both, and the mirror applies them idempotently.
        let stream = await registry.subscribe()
        mirror = InventoryMirror(await registry.inventory())
        registryTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: Accept

    private func accept(_ stream: any StreamConnection) async {
        guard isRunning else { await stream.close(); return }
        // Check the limit before talking; over-limit sockets get only CLOSE.
        if connections.count >= settings.maxConnections {
            log("Max connections reached, refused: \t \t\(stream.peerAddress)")
            try? await stream.send(GHWire.encode(.close))
            await stream.close()
            return
        }
        nextID += 1
        let id = nextID
        let auth = settings.authenticate   // sampled per connection
        let conn = ClientConnection(id: id, stream: stream, hub: self,
                                    router: CommandRouter(registry: registry, host: self),
                                    credentials: credentials, clock: clock, authenticate: auth)
        connections[id] = conn
        order.append(id)
        log("Accepted New Client : \t \t\(conn.address)")
        if !auth {
            // Registration and inventory in one actor turn: no gap or duplicate with live broadcasts.
            authenticated[id] = .some(nil)
            sendInventory(to: conn, includePresets: false)
        }
        publishConnections()
        await conn.start()
    }

    /// Called by a connection after a valid digest.
    func clientAuthenticated(_ conn: ClientConnection, user: String) {
        guard connections[conn.id] != nil else { return }
        authenticated[conn.id] = .some(user)
        sendInventory(to: conn, includePresets: true)
        log("Authorized Client : \t \t\(conn.address) \(user)")
        publishConnections()
    }

    private func sendInventory(to conn: ClientConnection, includePresets: Bool) {
        let (messages, needsQuery) = mirror.burst(includePresets: includePresets)
        for m in messages { if let bytes = wireBytes(m) { conn.enqueue(bytes) } }
        // In both auth modes, rotors without a known reading are asked for one (POINT follows as a broadcast).
        if !needsQuery.isEmpty {
            let registry = registry
            Task { for name in needsQuery { await registry.query(name) } }
        }
    }

    /// Cleanup for a connection whose input ended (EOF, reset, QUIT, server close).
    func connectionEnded(_ conn: ClientConnection) {
        log("Client Disconnected \t \t\(conn.address)")
        // Every lock owned by this IP is released.
        locks = locks.filter { $0.value != conn.address }
        if connections.removeValue(forKey: conn.id) != nil {
            order.removeAll { $0 == conn.id }
            authenticated[conn.id] = nil
            publishConnections()
        }
    }

    // MARK: Registry events → broadcasts

    private func handle(_ event: RegistryEvent) {
        mirror.apply(event)
        switch event {
        case .rotorAdded(let name): broadcast(.add(name))
        case .rotorRemoved(let name): broadcast(.remove(name))
        case .reading(let r): broadcast(.point(rotor: r.name, heading: r.heading, status: r.status, rssi: r.rssi))
        case .switchAdded(let d): broadcast(.switchAdd(d))
        case .switchRemoved(let name): broadcast(.switchRemove(name))
        case .switchUpdated(let name, let state, let status, let rssi):
            broadcast(.switchUpdate(name: name, state: state, status: status, rssi: rssi))
        case .switchLocks(let name, let states): broadcast(.switchLocks(name: name, states: states))
        case .stackAdded(let names): broadcast(.stackAdd(names))
        case .stackRemoved(let names): broadcast(.stackRemove(names))
        case .stackUpdated(let names, let selected, let status, let rssi):
            broadcast(.stack(names: names, selected: selected, status: status, rssi: rssi))
        case .log(let text): log(text)
        }
    }

    /// Encodes once and queues to a snapshot of the authenticated connections.
    private func broadcast(_ message: ServerMessage) {
        guard let bytes = wireBytes(message) else { return }
        for id in order where authenticated[id] != nil { connections[id]?.enqueue(bytes) }
    }

    /// The encoded line, or nil (logged) if a name would inject a line break into the stream.
    private func wireBytes(_ message: ServerMessage) -> [UInt8]? {
        let bytes = GHWire.encode(message)
        // A CR/LF inside a device name would split the line and let a name forge messages.
        if bytes.count > 2, bytes.dropLast(2).contains(where: { $0 == 0x0A || $0 == 0x0D }) {
            log("***ERROR*** a device name contains a line break; message not sent")
            return nil
        }
        return bytes
    }

    // MARK: CommandHost

    func mayControl(_ rotor: String, from address: String) -> Bool {
        guard let owner = locks[rotor] else { return true }
        return owner == address
    }

    func lock(_ rotor: String, by address: String) {
        if mayControl(rotor, from: address) { locks[rotor] = address }
    }

    func unlock(_ rotor: String, by address: String) {
        if mayControl(rotor, from: address) { locks[rotor] = nil }
    }

    /// Current rotor locks (rotor → client IP), for tests and the UI.
    public var rotorLocks: [String: String] { locks }

    var stationLatitude: Double { settings.stationLatitude }
    var stationLongitude: Double { settings.stationLongitude }

    func restartRequested(by address: String) async {
        guard settings.allowRestart else {
            log("RESTART refused (disabled in settings): \t \t\(address)")
            return
        }
        // Any authenticated client may restart; logged, with an opt-out.
        log("RESTART requested by \t \t\(address)")
        do { try await restart() } catch { log("RESTART failed: \(error.localizedDescription)") }
    }

    // MARK: UI events

    func log(_ text: String) { hubEvents.yield(.log(text)) }

    private func publishConnections() {
        hubEvents.yield(.connections(clients: clients, max: settings.maxConnections))
    }
}
