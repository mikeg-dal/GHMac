import Foundation
import GHEKit
import GHEServerKit

/// A small scripted device registry for `-GHESimulator demo`: five rotors (normal, normal, fixed at 999,
/// a clone, one not responding), a button switch, a band switch, a map switch, an on/off bank and a
/// stack match. Everything is in memory. Swap for the shared DemoScenario when it lands.
actor DemoRegistry: DeviceRegistryProtocol {
    nonisolated struct Rotor: Sendable {
        enum Kind: Sendable { case normal, fixed, clone(of: String, offset: Double), dead }
        var name: String
        var kind: Kind
        var heading: Double
        var target: Double?
        var continuous: Int = 0          // +1 CW, -1 CCW (TURN CW/CCW)
        var rssi: Int
    }

    static let rotorNames = ["TH6", "4L40", "Fixed", "TH6-Clone", "Tower2"]
    /// Degrees per second while turning (fast so the UI tests don't wait).
    static let speed = 60.0

    private let broadcaster = EventBroadcaster<RegistryEvent>()
    private var rotors: [String: Rotor] = [:]
    private var order: [String] = []
    private var switches: [SwitchDescriptor] = []
    private var switchStates: [String: String] = [:]
    private var stackNames = ["TH6", "TH6-Clone"]
    private var stackSelected = [true, false]
    private var tick: Task<Void, Never>?

    init() {
        let list = [
            Rotor(name: "TH6", kind: .normal, heading: 45, rssi: -52),
            Rotor(name: "4L40", kind: .normal, heading: 300, rssi: 0),
            Rotor(name: "Fixed", kind: .fixed, heading: 999, rssi: 0),
            Rotor(name: "TH6-Clone", kind: .clone(of: "TH6", offset: 180), heading: 225, rssi: 0),
            Rotor(name: "Tower2", kind: .dead, heading: 123, rssi: -88),
        ]
        for r in list { rotors[r.name] = r; order.append(r.name) }
        switches = [
            SwitchDescriptor(name: "AntSwitch", displayType: 1, positions: ["Default", "TH6", "4L40", "Dipole", "OFF"].map {
                SwitchPosition(name: $0)
            }),
            SwitchDescriptor(name: "BandSW", displayType: 3, positions: [
                SwitchPosition(name: "160M", lowerMHz: 1.8, upperMHz: 2.0),
                SwitchPosition(name: "80M", lowerMHz: 3.5, upperMHz: 4.0),
                SwitchPosition(name: "40M", lowerMHz: 7.0, upperMHz: 7.3),
                SwitchPosition(name: "20M", lowerMHz: 14.0, upperMHz: 14.35),
                SwitchPosition(name: "15M", lowerMHz: 21.0, upperMHz: 21.45),
                SwitchPosition(name: "10M", lowerMHz: 28.0, upperMHz: 29.7),
                SwitchPosition(name: "OFF", lowerMHz: 0, upperMHz: 0),
            ]),
            SwitchDescriptor(name: "4Square", displayType: 2, positions: [
                SwitchPosition(name: "N", heading: 0, beamwidth: 90),
                SwitchPosition(name: "E", heading: 90, beamwidth: 90),
                SwitchPosition(name: "S", heading: 180, beamwidth: 90),
                SwitchPosition(name: "W", heading: 270, beamwidth: 90),
                SwitchPosition(name: "Omni", heading: 0, beamwidth: 360),
            ]),
            SwitchDescriptor(name: "Bank", displayType: 4, positions: ["Preamp", "Filter", "PTT LOCK", "Amp"].map {
                SwitchPosition(name: $0)
            }),
        ]
        switchStates = ["AntSwitch": "TH6", "BandSW": "20M", "4Square": "N", "Bank": "Filter"]
    }

    func start() {
        guard tick == nil else { return }
        tick = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                n += 1
                await self?.step(seconds: 0.25, emitReadings: n % 4 == 0, emitSwitches: n % 8 == 0)
            }
        }
    }

    // MARK: DeviceRegistryProtocol

    func subscribe() -> AsyncStream<RegistryEvent> { broadcaster.subscribe() }

    func inventory() -> RegistryInventory {
        var inv = RegistryInventory()
        inv.rotors = order
        inv.switches = switches
        inv.stacks = [stackNames]
        for name in order { inv.lastReadings[name] = reading(name) }
        return inv
    }

    func turn(_ rotor: String, _ target: TurnTarget) async {
        guard var r = rotors[rotor] else { return }
        switch r.kind {
        case .fixed, .dead: return
        case .clone(let source, let offset):
            if case .heading(let h) = target { await turn(source, .heading(Self.wrap(h - offset))) }
            else { await turn(source, target) }
            return
        case .normal: break
        }
        switch target {
        case .heading(let h): r.target = Self.wrap(h); r.continuous = 0
        case .raw(let s): if let h = JavaDouble.parse(s, allowComma: true) { r.target = Self.wrap(h); r.continuous = 0 }
        case .cw: r.continuous = 1; r.target = nil
        case .ccw: r.continuous = -1; r.target = nil
        }
        rotors[rotor] = r
        emitReading(rotor)
    }

    func stop(_ rotor: String) async {
        if case .clone(let source, _) = rotors[rotor]?.kind { await stop(source); return }
        rotors[rotor]?.target = nil
        rotors[rotor]?.continuous = 0
        emitReading(rotor)
    }

    func query(_ rotor: String) async { emitReading(rotor) }

    func setStack(_ antenna: String, _ selected: Bool) async {
        guard let i = stackNames.firstIndex(of: antenna) else { return }
        stackSelected[i] = selected
        emitStack()
    }

    func setSwitch(_ name: String, _ position: String, _ on: Bool?) async -> SwitchCommandResult {
        guard let d = switches.first(where: { $0.name == name }) else { return .unknownSwitch }
        if d.displayType == 4 {
            var set = Set(JavaString.split(switchStates[name] ?? "", separator: ",").filter { !$0.isEmpty && $0 != "NONE_SELECTED" })
            if on ?? !set.contains(position) { set.insert(position) } else { set.remove(position) }
            let ordered = d.positions.map(\.name).filter(set.contains)
            switchStates[name] = ordered.isEmpty ? "NONE_SELECTED" : ordered.joined(separator: ",")
        } else {
            switchStates[name] = position
        }
        // The real server echoes after the relay answers; a short delay makes the round trip visible.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.emitSwitch(name)
        }
        return .ok
    }

    // MARK: Simulation

    private func step(seconds: Double, emitReadings: Bool, emitSwitches: Bool) {
        for name in order {
            guard var r = rotors[name], case .normal = r.kind else { continue }
            let maxStep = Self.speed * seconds
            if let t = r.target {
                let d = Self.signedDelta(from: r.heading, to: t)
                if abs(d) <= maxStep { r.heading = t; r.target = nil } else { r.heading = Self.wrap(r.heading + (d > 0 ? maxStep : -maxStep)) }
                rotors[name] = r
                emitReading(name)
            } else if r.continuous != 0 {
                r.heading = Self.wrap(r.heading + Double(r.continuous) * maxStep)
                rotors[name] = r
                emitReading(name)
            }
        }
        // Clones follow their source.
        for name in order {
            guard var r = rotors[name], case .clone(let source, let offset) = r.kind, let s = rotors[source] else { continue }
            let h = Self.wrap(s.heading + offset)
            if h != r.heading { r.heading = h; rotors[name] = r; emitReading(name) }
        }
        if emitReadings { for name in order { emitReading(name) } }
        if emitSwitches {
            for s in switches { emitSwitch(s.name) }
            emitStack()
        }
    }

    private func reading(_ name: String) -> RotorReading? {
        guard let r = rotors[name] else { return nil }
        let status: RotorStatus
        switch r.kind {
        case .fixed: status = .fixed
        case .dead: status = .error
        case .clone(let source, _):
            let s = rotors[source]
            status = (s?.target != nil || s?.continuous != 0) ? movingStatus(s!) : .clone
        case .normal: status = (r.target != nil || r.continuous != 0) ? movingStatus(r) : .ok
        }
        return RotorReading(name: name, heading: (r.heading * 10).rounded() / 10, status: status, rssi: r.rssi)
    }

    private func movingStatus(_ r: Rotor) -> RotorStatus {
        if r.continuous != 0 { return r.continuous > 0 ? .turningCW : .turningCCW }
        guard let t = r.target else { return .ok }
        return Self.signedDelta(from: r.heading, to: t) >= 0 ? .turningCW : .turningCCW
    }

    private func emitReading(_ name: String) {
        if let r = reading(name) { broadcaster.yield(.reading(r)) }
    }

    private func emitSwitch(_ name: String) {
        guard let state = switchStates[name] else { return }
        broadcaster.yield(.switchUpdated(name: name, state: state, status: 0, rssi: name == "AntSwitch" ? -61 : 0))
    }

    private func emitStack() {
        broadcaster.yield(.stackUpdated(names: stackNames, selected: stackSelected + [false, false], status: 0, rssi: -70))
    }

    nonisolated static func wrap(_ h: Double) -> Double {
        let v = h.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }

    /// Shortest signed angle from `a` to `b` (positive = clockwise).
    nonisolated static func signedDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
