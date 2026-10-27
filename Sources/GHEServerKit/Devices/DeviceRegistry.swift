import Foundation
import GHEKit

/// Active devices by name, as the hub sees them.
///
/// A device is "added" when it produces its first event: rotors on any reading (including status '5'),
/// switches and stacks on their first status-0 update. Slots feed the registry; the registry emits
/// ADD/REMOVE/POINT/SWITCH*/STACK* events and routes commands by name.
public actor DeviceRegistry: DeviceRegistryProtocol {
    private struct RotorEntry {
        let driver: any RotorDriver
        let name: String
    }
    private struct SwitchEntry {
        let device: WIOSwitch
        var added: Bool
    }
    private struct StackEntry {
        let device: WIOStackMatch
        var added: Bool
    }

    private let events = EventBroadcaster<RegistryEvent>()
    /// Added rotors in add order (duplicated names are allowed: commands reach all of them).
    private var rotors: [RotorEntry] = []
    private var lastReadings: [String: RotorReading] = [:]
    /// Switches by name; `switchOrder` keeps the add order.
    private var switches: [String: SwitchEntry] = [:]
    private var switchOrder: [String] = []
    /// Matrix-lockout switch names in add order (`mLockedWioSwitches`).
    private var lockedSwitches: [String] = []
    private var stacks: [ObjectIdentifier: StackEntry] = [:]
    private var stackOrder: [ObjectIdentifier] = []
    /// Lower-cased antenna name → stack.
    private var stackByAntenna: [String: WIOStackMatch] = [:]

    public init() {}

    // MARK: DeviceRegistryProtocol

    public func subscribe() -> AsyncStream<RegistryEvent> { events.subscribe() }

    public func inventory() -> RegistryInventory {
        var inv = RegistryInventory()
        inv.rotors = rotors.map(\.name)
        inv.switches = switchOrder.compactMap { n in switches[n].flatMap { $0.added ? $0.device.descriptor : nil } }
        inv.stacks = stackOrder.compactMap { id in stacks[id].flatMap { $0.added ? $0.device.names : nil } }
        inv.lastReadings = lastReadings
        return inv
    }

    public func turn(_ rotor: String, _ target: TurnTarget) async {
        for e in rotors where e.name == rotor { await e.driver.goTo(target) }
    }

    public func stop(_ rotor: String) async {
        for e in rotors where e.name == rotor { await e.driver.stop() }
    }

    public func query(_ rotor: String) async {
        for e in rotors where e.name == rotor { await e.driver.query() }
    }

    public func setStack(_ antenna: String, _ selected: Bool) async {
        guard let s = stackByAntenna[antenna.lowercased()] else { return }
        await s.setAntenna(named: antenna, selected)
    }

    public func setSwitch(_ name: String, _ position: String, _ on: Bool?) async -> SwitchCommandResult {
        guard let entry = switches[name], entry.added else { return .unknownSwitch }
        if lockedSwitches.contains(name) && isLocked(position) {
            log("SET_SWITCH LOCKOUT \(position)")
            return .lockedOut
        }
        let sw = entry.device
        if let on {
            await sw.setState(position, on: on)
            return .ok
        }
        if sw.isVirtual {
            for v in sw.profile.virtualEntries(for: position) { await executeVirtual(v) }
        }
        await sw.setState(position)
        return .ok
    }

    // MARK: Feeding from slots

    /// A reading from a running rotor. The first one adds the rotor (ADD), then the reading is published.
    public func rotorReading(_ r: RotorReading, from driver: any RotorDriver) {
        if !rotors.contains(where: { $0.driver === driver }) {
            rotors.append(RotorEntry(driver: driver, name: driver.name))
            log("ROTOR CONNECTED: \t\(driver.name)")
            events.yield(.rotorAdded(driver.name))
            // The new rotor is queried once.
            Task { await driver.query() }
        }
        lastReadings[r.name] = r
        events.yield(.reading(r))
    }

    /// The rotor closed or its link was lost: REMOVE if it had been added.
    public func removeRotor(_ driver: any RotorDriver) {
        guard let i = rotors.firstIndex(where: { $0.driver === driver }) else { return }
        let name = rotors.remove(at: i).name
        if !rotors.contains(where: { $0.name == name }) { lastReadings[name] = nil }
        log("ROTOR DISCONNECTED: \t\(name)")
        events.yield(.rotorRemoved(name))
    }

    /// Exact-name check used by stack matches.
    public func isRotorConnected(_ name: String) -> Bool { rotors.contains { $0.name == name } }

    /// Registers a switch (not yet visible to clients).
    public func registerSwitch(_ sw: WIOSwitch) {
        if switches[sw.name] == nil { switchOrder.append(sw.name) }
        switches[sw.name] = SwitchEntry(device: sw, added: false)
    }

    /// An update from a switch. The first status-0 update adds it (SWITCHADD) and is then published too.
    public func switchUpdate(_ u: WIOSwitchUpdate, from sw: WIOSwitch) {
        guard var entry = switches[sw.name], entry.device === sw else { return }
        if !entry.added {
            guard u.status == 0 else { return }
            entry.added = true
            switches[sw.name] = entry
            log("SWITCH CONNECTED: \t\(sw.name)")
            if sw.isMatrixLockout && !lockedSwitches.contains(sw.name) {
                log("MLOCKED SWITCH CONNECTED: \t\(sw.name)")
                lockedSwitches.append(sw.name)
            }
            events.yield(.switchAdded(sw.descriptor))
        }
        events.yield(.switchUpdated(name: u.name, state: u.state, status: u.status, rssi: u.rssi))
        if lockedSwitches.contains(sw.name) {
            events.yield(.switchLocks(name: sw.name, states: lockedStates()))
        }
    }

    public func removeSwitch(_ sw: WIOSwitch) {
        guard let entry = switches[sw.name], entry.device === sw else { return }
        switches[sw.name] = nil
        switchOrder.removeAll { $0 == sw.name }
        lockedSwitches.removeAll { $0 == sw.name }
        if entry.added {
            log("SWITCH DISCONNECTED: \t\(sw.name)")
            events.yield(.switchRemoved(sw.name))
        }
    }

    public func registerStack(_ st: WIOStackMatch) {
        let id = ObjectIdentifier(st)
        if stacks[id] == nil { stackOrder.append(id) }
        stacks[id] = StackEntry(device: st, added: false)
    }

    /// An update from a stack match. The first status-0 update adds it (STACKADD) and runs the OK2ZAW init.
    public func stackUpdate(_ u: WIOStackUpdate, from st: WIOStackMatch) {
        let id = ObjectIdentifier(st)
        guard var entry = stacks[id] else { return }
        if !entry.added {
            guard u.status == 0 else { return }
            entry.added = true
            stacks[id] = entry
            log("STACK SWITCH CONNECTED: \t")
            for n in st.names {
                stackByAntenna[n.lowercased()] = st
                log("    \(n)")
            }
            events.yield(.stackAdded(st.names))
            Task { await st.initializeStack() }
        }
        events.yield(.stackUpdated(names: u.names, selected: u.selected, status: u.status, rssi: u.rssi))
    }

    public func removeStack(_ st: WIOStackMatch) {
        let id = ObjectIdentifier(st)
        guard let entry = stacks.removeValue(forKey: id) else { return }
        stackOrder.removeAll { $0 == id }
        for n in st.names where stackByAntenna[n.lowercased()] === st { stackByAntenna[n.lowercased()] = nil }
        if entry.added {
            log("STACK SWITCH DISCONNECTED: \t")
            events.yield(.stackRemoved(st.names))
        }
    }

    /// Lines for the server log window.
    public func log(_ line: String) { events.yield(.log(line)) }

    // MARK: - Matrix lockout and virtual switches

    /// Matrix lockout: refused when any locked switch's state equals the position (ignoring
    /// case). `OFF` is always allowed.
    private func isLocked(_ position: String) -> Bool {
        if position.caseInsensitiveCompare("OFF") == .orderedSame { return false }
        return lockedSwitches.contains { n in
            switches[n]?.device.currentState.caseInsensitiveCompare(position) == .orderedSame
        }
    }

    private func lockedStates() -> [String] {
        lockedSwitches.compactMap { switches[$0]?.device.currentState }
    }

    private func executeVirtual(_ v: WioProfile.VirtualEntry) async {
        let action = v.action
        if action.hasPrefix("#") {
            if let deg = Double(action.dropFirst().trimmingCharacters(in: .whitespaces)) {
                await turn(v.target, .heading(deg))
            }
        } else if action.hasPrefix("$") {
            // External commands are logged and ignored.
            log("Virtual command \(action) for \(v.target) ignored (not supported)")
            return
        } else {
            guard let target = switches[v.target], target.added else {
                log("***ERROR*** \(v.target) Device is Not Connected")
                log("      SET VIRTUAL \(v.target) To \(action)")
                return
            }
            // isLocked applies the OFF exemption.
            if lockedSwitches.contains(v.target) && isLocked(action) {
                log("SET_SWITCH LOCKOUT \(action)")
            } else {
                await target.device.setState(action)
            }
        }
        log("      SET VIRTUAL \(v.target) To \(action)")
    }
}
