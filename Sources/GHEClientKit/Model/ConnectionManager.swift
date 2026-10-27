import Foundation
import Observation
import GHEKit

/// Owns the 10 Servers-dialog rows, merges every server's inventory into per-item models and
/// routes UI commands to the server that owns each item.
///
/// Items are keyed by host AND port; `ItemKey.legacyKey` gives the legacy file key.
@MainActor @Observable
public final class ConnectionManager {
    public static let defaultRowCount = 10

    public private(set) var supervisors: [ConnectionSupervisor] = []
    /// Rotors sorted by name, then port, then host.
    public private(set) var rotors: [RotorItem] = []
    public private(set) var switches: [SwitchItem] = []
    public private(set) var stacks: [StackItem] = []
    public private(set) var tornados: [TornadoItem] = []
    /// Last LOCATIONS names per server (unused by the UI, kept for parity).
    public private(set) var presetNames: [ServerID: [String]] = [:]

    /// Band visibility hook: true if the item is shown for the current bands. Default: all visible.
    @ObservationIgnored public var isVisible: (ItemKey) -> Bool = { _ in true }
    /// Restores a rotor's "active" flag when it first appears (`rotorstatus.ini`).
    @ObservationIgnored public var restoreActive: (ItemKey) -> Bool? = { _ in nil }
    /// Saved password hashes, by user name.
    @ObservationIgnored public var passwordHashLookup: (String) -> [UInt8]? = { _ in nil }
    /// Called with the hash computed on connect .
    @ObservationIgnored public var didComputePasswordHash: ([UInt8], String) -> Void = { _, _ in }

    /// Traffic and connection-event log (subscribe for the traffic window).
    @ObservationIgnored public let traffic = EventBroadcaster<TrafficEntry>()
    @ObservationIgnored let environment: ConnectionEnvironment

    @ObservationIgnored private var rotorIndex: [ItemKey: RotorItem] = [:]
    @ObservationIgnored private var switchIndex: [ItemKey: SwitchItem] = [:]
    @ObservationIgnored private var stackIndex: [ItemKey: StackItem] = [:]
    @ObservationIgnored private var tornadoIndex: [ItemKey: TornadoItem] = [:]
    /// Active flags of rotors that went away, so a reconnect keeps them.
    @ObservationIgnored private var activeMemory: [ItemKey: Bool] = [:]

    public init(environment: ConnectionEnvironment = .live(), rows: Int = ConnectionManager.defaultRowCount) {
        self.environment = environment
        supervisors = (0..<rows).map { ConnectionSupervisor(id: $0, environment: environment) }
        for s in supervisors { s.delegate = self }
    }

    // MARK: Lookup

    public func rotor(_ key: ItemKey) -> RotorItem? { rotorIndex[key] }
    public func switchItem(_ key: ItemKey) -> SwitchItem? { switchIndex[key] }
    public func stack(_ key: ItemKey) -> StackItem? { stackIndex[key] }
    public func tornado(_ key: ItemKey) -> TornadoItem? { tornadoIndex[key] }

    /// Rotors shown in the tray for the current bands.
    public var visibleRotors: [RotorItem] { rotors.filter { isVisible($0.key) } }

    /// The supervisor currently using `server`, if any.
    public func supervisor(for server: ServerID) -> ConnectionSupervisor? {
        supervisors.first { $0.serverID == server && $0.state != .disconnected }
    }

    /// Lines for the RSSI test window; `showAll` includes wired devices (RSSI 0).
    public func rssiEntries(showAll: Bool = false) -> [RSSIEntry] {
        var out: [RSSIEntry] = []
        out += rotors.map { RSSIEntry(key: $0.key, kind: .rotor, rssi: $0.rssi) }
        out += switches.map { RSSIEntry(key: $0.key, kind: .switchBox, rssi: $0.rssi) }
        out += stacks.map { RSSIEntry(key: $0.key, kind: .stack, rssi: $0.rssi) }
        return showAll ? out : out.filter { $0.rssi != 0 }
    }

    /// Disconnects every row (app exit, `closeAllServers`).
    public func disconnectAll() async {
        for s in supervisors { await s.disconnect() }
    }

    // MARK: Commands

    /// Turns a rotor. Ganging: if it is active and visible, every active+visible rotor of every
    /// server gets its own TURN; otherwise only this rotor, on its own server.
    public func turn(_ rotor: RotorItem, to target: TurnTarget) {
        for r in targets(for: rotor) { send(.turn(rotor: r.name, target), to: r.key.server) }
    }

    /// Stops a rotor, ganged like `turn`.
    public func stop(_ rotor: RotorItem) {
        for r in targets(for: rotor) { send(.stop(rotor: r.name), to: r.key.server) }
    }

    /// Logger Alt-J / global presets: raw heading to every active+visible rotor (`turnRotor(String)`).
    public func turnActive(raw: String) {
        for r in activeVisibleRotors() { send(.turn(rotor: r.name, .raw(raw)), to: r.key.server) }
    }

    /// Logger stop: every active+visible rotor.
    // Each STOP goes only to the owner.
    public func stopActive() {
        for r in activeVisibleRotors() { send(.stop(rotor: r.name), to: r.key.server) }
    }

    /// Stack-match antenna click: sends the requested state (the UI passes the toggled value).
    public func setStack(_ key: ItemKey, selected: Bool) {
        send(.setStack(antenna: key.name, selected: selected), to: key.server)
    }

    /// Switch position; `on` only for on/off bank panels.
    public func setSwitch(_ item: SwitchItem, position: String, on: Bool? = nil) {
        send(.setSwitch(name: item.name, position: position, on: on), to: item.key.server)
    }

    public func tornadoCalibrate(_ tuner: TornadoItem, rotor: String) {
        send(.tornadoCal(tuner: tuner.key.name, rotor: rotor), to: tuner.key.server)
    }

    public func setTornado(_ tuner: TornadoItem, position: String) {
        send(.setTornado(tuner: tuner.key.name, position: position), to: tuner.key.server)
    }

    public func tornadoTurn(_ tuner: TornadoItem, rotor: String, cw: Bool) {
        send(.tornadoTurn(tuner: tuner.key.name, rotor: rotor, cw: cw), to: tuner.key.server)
    }

    /// Queues a command on the server's connection. Returns false (and logs) if it is not connected.
    @discardableResult
    public func send(_ command: ClientCommand, to server: ServerID) -> Bool {
        guard let s = supervisor(for: server), s.state == .connected, let conn = s.connection else {
            traffic.yield(TrafficEntry(server: server, direction: .note, text: "Not connected; command dropped"))
            return false
        }
        conn.enqueue(command)
        return true
    }

    private func targets(for rotor: RotorItem) -> [RotorItem] {
        if rotor.isActive && isVisible(rotor.key) {
            return activeVisibleRotors()
        }
        return [rotor]
    }

    private func activeVisibleRotors() -> [RotorItem] {
        rotors.filter { $0.isActive && $0.isConnected && isVisible($0.key) }
    }

    // MARK: Inventory

    /// Applies one server message to the models (public for simulators and tests).
    public func apply(_ message: ServerMessage, from server: ServerID) {
        switch message {
        case .add(let name):
            addRotor(ItemKey(server: server, name: name))
        case .remove(let name):
            removeRotor(ItemKey(server: server, name: name))
        case .point(let name, let heading, let status, let rssi):
            // Routed by (server, exact name) — no splitting on ':'.
            rotorIndex[ItemKey(server: server, name: name)]?.applyPoint(heading: heading, status: status, rssi: rssi)
        case .stackAdd(let names):
            for name in names.prefix(4) {
                let key = ItemKey(server: server, name: name)
                if let s = stackIndex[key] {
                    s.group = names
                    s.isConnected = true
                } else {
                    let s = StackItem(key: key, group: names)
                    stackIndex[key] = s
                    stacks.append(s)
                    stacks.sort { Self.precedes($0.key, $1.key) }
                }
            }
        case .stackRemove(let names):
            for name in names.prefix(4) {
                let key = ItemKey(server: server, name: name)
                if stackIndex.removeValue(forKey: key) != nil { stacks.removeAll { $0.key == key } }
                for r in rotors(on: server, named: name) { r.clearStack() }
            }
        case .stack(let names, let selected, let status, let rssi):
            let now = environment.clock.now
            for (i, name) in names.prefix(4).enumerated() {
                let on = i < selected.count ? selected[i] : false
                if let s = stackIndex[ItemKey(server: server, name: name)] {
                    s.selected = on; s.status = status; s.rssi = rssi
                }
                // Rotor panels match case-insensitively.
                for r in rotors(on: server, named: name) { r.applyStack(selected: on, status: status, rssi: rssi, at: now) }
            }
        case .switchAdd(let descriptor):
            let key = ItemKey(server: server, name: descriptor.name)
            if let s = switchIndex[key] {
                s.descriptor = descriptor
            } else {
                let s = SwitchItem(key: key, descriptor: descriptor)
                switchIndex[key] = s
                switches.append(s)
                switches.sort { Self.precedes($0.key, $1.key) }
            }
        case .switchRemove(let name):
            let key = ItemKey(server: server, name: name)
            if switchIndex.removeValue(forKey: key) != nil { switches.removeAll { $0.key == key } }
        case .switchUpdate(let name, let state, let status, let rssi):
            switchIndex[ItemKey(server: server, name: name)]?.applyUpdate(state: state, status: status, rssi: rssi)
        case .switchLocks(let name, let states):
            switchIndex[ItemKey(server: server, name: name)]?.locks = states
        case .presetsLine(let names):
            presetNames[server] = names
        case .tornadoAdd(let d):
            let key = ItemKey(server: server, name: d.name)
            if let t = tornadoIndex[key] {
                t.descriptor = d
            } else {
                let t = TornadoItem(key: key, descriptor: d)
                tornadoIndex[key] = t
                tornados.append(t)
                tornados.sort { Self.precedes($0.key, $1.key) }
            }
        case .tornadoRemove(let name):
            let key = ItemKey(server: server, name: name)
            if tornadoIndex.removeValue(forKey: key) != nil { tornados.removeAll { $0.key == key } }
        case .tornado(let state):
            tornadoIndex[ItemKey(server: server, name: state.name)]?.state = state
        case .user, .pass, .invalidUserPass, .close, .popup, .ignored:
            break
        }
    }

    private func rotors(on server: ServerID, named name: String) -> [RotorItem] {
        let lower = name.lowercased()
        return rotors.filter { $0.key.server == server && $0.name.lowercased() == lower }
    }

    private func addRotor(_ key: ItemKey) {
        if let r = rotorIndex[key] {
            r.isConnected = true
            return
        }
        let active = activeMemory[key] ?? restoreActive(key) ?? false
        let r = RotorItem(key: key, isActive: active)
        rotorIndex[key] = r
        rotors.append(r)
        rotors.sort { Self.precedes($0.key, $1.key) }
    }

    private func removeRotor(_ key: ItemKey) {
        guard let r = rotorIndex.removeValue(forKey: key) else { return }
        activeMemory[key] = r.isActive
        rotors.removeAll { $0.key == key }
    }

    /// Removes every item of `server` (user disconnect, invalid credentials, fresh reconnect).
    private func removeAll(of server: ServerID, onlyDisconnected: Bool = false) {
        for r in rotors where r.key.server == server && (!onlyDisconnected || !r.isConnected) { removeRotor(r.key) }
        let stale = { (key: ItemKey, connected: Bool) in key.server == server && (!onlyDisconnected || !connected) }
        for s in stacks where stale(s.key, s.isConnected) { stackIndex[s.key] = nil }
        stacks.removeAll { stale($0.key, $0.isConnected) }
        for s in switches where s.key.server == server { switchIndex[s.key] = nil }
        switches.removeAll { $0.key.server == server }
        for t in tornados where t.key.server == server { tornadoIndex[t.key] = nil }
        tornados.removeAll { $0.key.server == server }
        presetNames[server] = nil
    }

    /// Sorted-map order of `name␞:port` keys (UTF-16 compare), then host.
    static func precedes(_ a: ItemKey, _ b: ItemKey) -> Bool {
        if a.name != b.name { return a.name.utf16.lexicographicallyPrecedes(b.name.utf16) }
        if a.server.port != b.server.port { return a.server.port < b.server.port }
        return a.server.host < b.server.host
    }
}

extension ConnectionManager: ConnectionSupervisorDelegate {
    func supervisor(_ s: ConnectionSupervisor, isInUse id: ServerID) -> Bool {
        supervisors.contains { $0 !== s && $0.serverID == id && $0.state != .disconnected }
    }

    func supervisor(_ s: ConnectionSupervisor, didConnect id: ServerID) {
        // A fresh connection re-announces its inventory; drop greyed leftovers of the old one.
        removeAll(of: id, onlyDisconnected: true)
        traffic.yield(TrafficEntry(server: id, direction: .note, text: "Server connected"))
    }

    func supervisor(_ s: ConnectionSupervisor, received message: ServerMessage, from id: ServerID) {
        apply(message, from: id)
    }

    func supervisor(_ s: ConnectionSupervisor, didLose id: ServerID) {
        // Only THIS server's switches go.
        for sw in switches where sw.key.server == id { switchIndex[sw.key] = nil }
        switches.removeAll { $0.key.server == id }
        for t in tornados where t.key.server == id { tornadoIndex[t.key] = nil }
        tornados.removeAll { $0.key.server == id }
        // Grey this server's rotors and stack widgets.
        for r in rotors where r.key.server == id { r.isConnected = false }
        for st in stacks where st.key.server == id { st.isConnected = false }
        traffic.yield(TrafficEntry(server: id, direction: .note, text: "Server disconnected"))
    }

    func supervisor(_ s: ConnectionSupervisor, didEnd id: ServerID) {
        removeAll(of: id)
        traffic.yield(TrafficEntry(server: id, direction: .note, text: "Server closed"))
    }

    func savedPasswordHash(user: String) -> [UInt8]? { passwordHashLookup(user) }

    func storePasswordHash(_ hash: [UInt8], user: String) { didComputePasswordHash(hash, user) }

    var trafficSink: TrafficSink? {
        let b = traffic
        return { b.yield($0) }
    }
}
