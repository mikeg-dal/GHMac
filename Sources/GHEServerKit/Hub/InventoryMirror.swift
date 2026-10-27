import Foundation
import GHEKit

/// The hub's own copy of what the registry has "added", kept in step with registry events.
///
/// The hub builds inventory bursts from this mirror in the same actor turn in which it registers a
/// connection for broadcasts, so a new client never misses or duplicates an event. Updates are
/// idempotent because the initial `inventory()` snapshot can overlap the first few events.
struct InventoryMirror: Sendable, Equatable {
    private(set) var rotors: [String] = []
    private(set) var switches: [SwitchDescriptor] = []
    private(set) var stacks: [[String]] = []
    private(set) var lastReadings: [String: RotorReading] = [:]

    init() {}

    init(_ inventory: RegistryInventory) {
        rotors = inventory.rotors
        switches = inventory.switches
        stacks = inventory.stacks
        lastReadings = inventory.lastReadings
    }

    mutating func apply(_ event: RegistryEvent) {
        switch event {
        case .rotorAdded(let name):
            if !rotors.contains(name) { rotors.append(name) }
        case .rotorRemoved(let name):
            if let i = rotors.firstIndex(of: name) { rotors.remove(at: i) }
            if !rotors.contains(name) { lastReadings[name] = nil }
        case .reading(let r):
            lastReadings[r.name] = r
        case .switchAdded(let d):
            if let i = switches.firstIndex(where: { $0.name == d.name }) { switches[i] = d } else { switches.append(d) }
        case .switchRemoved(let name):
            switches.removeAll { $0.name == name }
        case .stackAdded(let names):
            if !stacks.contains(names) { stacks.append(names) }
        case .stackRemoved(let names):
            if let i = stacks.firstIndex(of: names) { stacks.remove(at: i) }
        case .switchUpdated, .switchLocks, .stackUpdated, .log:
            break
        }
    }

    /// The inventory burst: ADD per rotor, SWITCHADD per switch, STACKADD per stack device,
    /// then (auth on only) the empty presets line, then the last known POINT per rotor.
    /// Rotors without a known reading are returned in `needsQuery`.
    func burst(includePresets: Bool) -> (messages: [ServerMessage], needsQuery: [String]) {
        var out: [ServerMessage] = []
        out += rotors.map { .add($0) }
        out += switches.map { .switchAdd($0) }
        out += stacks.map { .stackAdd($0) }
        if includePresets { out.append(.presetsLine(names: [])) }
        var query: [String] = []
        for name in rotors {
            if let r = lastReadings[name] {
                out.append(.point(rotor: r.name, heading: r.heading, status: r.status, rssi: r.rssi))
            } else if !query.contains(name) {
                query.append(name)
            }
        }
        return (out, query)
    }
}
