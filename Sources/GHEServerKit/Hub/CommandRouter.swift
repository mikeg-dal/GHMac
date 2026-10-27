import Foundation
import GHEKit

/// What the router needs from the hub: shared rotor locks, logging, presets, restart.
protocol CommandHost: Actor {
    /// Lock gate for TURN/STOP: true if `rotor` is unlocked or locked by `address`.
    func mayControl(_ rotor: String, from address: String) -> Bool
    func lock(_ rotor: String, by address: String)
    func unlock(_ rotor: String, by address: String)
    func log(_ text: String)
    /// RESTART from a client.
    func restartRequested(by address: String) async
    var stationLatitude: Double { get }
    var stationLongitude: Double { get }
}

/// The connection a command came from.
protocol CommandClient: Sendable {
    var address: String { get }
    /// Queues a line to this client only.
    func reply(_ message: ServerMessage)
    /// QUIT: close like an EOF.
    func quit() async
}

/// Turns client command lines into registry calls.
///
/// Parsing uses prefix tests, `\r` splits for TURN/SET_STACK/SET_SWITCH/STOP,
/// Java `split` and `trim` semantics for wire compatibility. Malformed lines are ignored
/// and every line has its trailing CR removed before parsing.
struct CommandRouter: Sendable {
    let registry: any DeviceRegistryProtocol
    let host: any CommandHost

    // MARK: Parsing (pure)

    /// Parses one `\n`-line. Unknown or malformed lines → `[]`.
    static func parse(_ rawLine: String) -> [ClientCommand] {
        // No command keeps a trailing CR; each line is trimmed.
        let line = JavaString.trim(rawLine)
        guard !line.isEmpty else { return [] }
        var out: [ClientCommand] = []
        let starts = { (p: String) in JavaString.startsWith(line, p) }

        if starts("TURN") {
            for part in JavaString.split(line, separator: "\r") { out += parseTurn(part) }
        } else if starts("SET_STACK") {
            for part in JavaString.split(line, separator: "\r") {
                let f = fields(part)
                guard f.count > 2 else { continue }
                out.append(.setStack(antenna: JavaString.trim(f[1]), selected: JavaString.parseBool(f[2])))
            }
        } else if starts("SET_SWITCH") {
            for part in JavaString.split(line, separator: "\r") {
                let f = fields(part)
                guard f.count > 2 else { continue }
                // Switch name is NOT trimmed.
                out.append(.setSwitch(name: f[1], position: f[2], on: f.count > 3 ? JavaString.parseBool(f[3]) : nil))
            }
        }
        if starts("TO_DEC") {
            let f = fields(line)
            if f.count > 3 { out.append(.toDec(rotor: JavaString.trim(f[1]), lat: f[2], lon: f[3])) }
        }
        if starts("TO_PRESET") {
            let f = fields(line)
            if f.count > 2 { out.append(.toPreset(rotor: f[1], preset: f[2])) }
        }
        if starts("STOP") {
            for part in JavaString.split(line, separator: "\r") {
                let f = fields(part)
                if f.count > 1 { out.append(.stop(rotor: JavaString.trim(f[1]))) }
            }
        } else if starts("LOCK") {
            let f = fields(line)
            if f.count > 1 { out.append(.lock(f[1])) }          // untrimmed
        } else if starts("UNLOCK") {
            let f = fields(line)
            if f.count > 1 { out.append(.unlock(f[1])) }
        } else if starts("GETHEAD") {
            let f = JavaString.split(line, separator: " ")       // space-separated
            if f.count > 1 { out.append(.getHead(f[1])) }
        } else if starts("GET_LOCATIONS") {
            out.append(.getLocations)
        } else if starts("QUIT") {
            out.append(.quit)
        } else if starts("RESTART") {
            out.append(.restart)
        }
        return out
    }

    private static func fields(_ s: String) -> [String] { JavaString.split(s, separator: GHSeparator.unit) }

    private static func parseTurn(_ part: String) -> [ClientCommand] {
        let f = fields(part)
        guard f.count > 1 else { return [] }
        let rotor = JavaString.trim(f[1])
        guard f.count > 2 else { return [] }
        switch f[2] {
        case "CW": return [.turn(rotor: rotor, .cw)]
        case "CCW": return [.turn(rotor: rotor, .ccw)]
        default:
            // replace(",", ".") then Double.parseDouble; unparsable → ignored.
            guard let deg = JavaDouble.parse(f[2], allowComma: true) else { return [] }
            return [.turn(rotor: rotor, .heading(deg))]
        }
    }

    // MARK: Execution

    /// Executes one parsed command for `client`. Device calls are awaited, so one client's commands run
    /// strictly in order (the caller runs this off the read path).
    func execute(_ command: ClientCommand, from client: any CommandClient) async {
        let ip = client.address
        switch command {
        case .turn(let rotor, let target):
            if case .heading(let d) = target, !d.isFinite {
                await host.log("TURN ignored (not a finite heading) \t \t\(ip)")
                return
            }
            guard await host.mayControl(rotor, from: ip) else { return }
            await registry.turn(rotor, target)
        case .stop(let rotor):
            guard await host.mayControl(rotor, from: ip) else { return }
            await registry.stop(rotor)
        case .setStack(let antenna, let selected):
            await registry.setStack(antenna, selected)
        case .setSwitch(let name, let position, let on):
            // The registry logs "SET_SWITCH LOCKOUT" itself (it also covers virtual-switch targets).
            _ = await registry.setSwitch(name, position, on)
        case .toDec(let rotor, let latText, let lonText):
            // Not lock-gated.
            guard let lat = JavaDouble.parse(latText, allowComma: true),
                  let lon = JavaDouble.parse(lonText, allowComma: true) else {
                await host.log("TO_DEC: bad coordinates \(latText) \(lonText) \t \t\(ip)")
                return
            }
            let fromLat = await host.stationLatitude, fromLon = await host.stationLongitude
            // No NaN heading (same point, antipode) reaches the rotor.
            guard let heading = TrigUtils.heading(fromLatitude: fromLat, fromLongitude: fromLon,
                                                  toLatitude: lat, toLongitude: lon) else {
                await host.log("TO_DEC: no heading to \(latText) \(lonText) \t \t\(ip)")
                return
            }
            await registry.turn(rotor, .heading(heading))
        case .toPreset:
            // Server presets are not supported; ignore safely.
            break
        case .lock(let rotor):
            await host.lock(rotor, by: ip)
        case .unlock(let rotor):
            await host.unlock(rotor, by: ip)
        case .getHead(let rotor):
            await registry.query(rotor)
        case .getLocations:
            // The (always empty) presets line goes to the requester only.
            client.reply(.presetsLine(names: []))
        case .quit:
            await client.quit()
        case .restart:
            await host.restartRequested(by: ip)
        case .tornadoCal, .setTornado, .tornadoTurn:
            break   // Tornado commands are ignored; parse never yields them.
        }
    }
}
