import Foundation

/// Text form of client → server commands and the server's command parser.
enum GHClientLineCodec {
    static let us = String(GHSeparator.unit)

    // MARK: encode

    static func text(_ command: ClientCommand) -> String {
        switch command {
        case let .turn(rotor, target):
            let t: String = switch target {
            case .heading(let d): JavaDouble.string(d)
            case .cw: "CW"
            case .ccw: "CCW"
            case .raw(let s): s
            }
            return ["TURN", rotor, t].joined(separator: us)
        case .stop(let rotor): return "STOP" + us + rotor
        case let .setStack(antenna, selected): return ["SET_STACK", antenna, String(selected)].joined(separator: us)
        case let .setSwitch(name, position, on):
            return (["SET_SWITCH", name, position] + (on.map { [String($0)] } ?? [])).joined(separator: us)
        case let .toDec(rotor, lat, lon): return ["TO_DEC", rotor, lat, lon].joined(separator: us)
        case let .toPreset(rotor, preset): return ["TO_PRESET", rotor, preset].joined(separator: us)
        case .lock(let rotor): return "LOCK" + us + rotor
        case .unlock(let rotor): return "UNLOCK" + us + rotor
        case .getHead(let rotor): return "GETHEAD " + rotor // space-separated
        case .getLocations: return "GET_LOCATIONS"
        case .quit: return "QUIT"
        case .restart: return "RESTART"
        case let .tornadoCal(tuner, rotor): return ["TORNADO_CAL", tuner, rotor].joined(separator: us)
        case let .setTornado(tuner, position): return ["SET_TORNADO", tuner, position].joined(separator: us)
        case let .tornadoTurn(tuner, rotor, cw): return ["TORNADOTURN", tuner, rotor, cw ? "CW" : "CCW"].joined(separator: us)
        }
    }

    // MARK: decode (server semantics)

    private static func fields(_ s: String) -> [String] { JavaString.split(s, separator: GHSeparator.unit) }
    private static func crParts(_ s: String) -> [String] { JavaString.split(s, separator: "\r") }

    /// Malformed commands (missing fields) are skipped instead of dropping the client.
    /// Every `\r`-part of a TURN/SET_STACK/SET_SWITCH/STOP line is parsed as that command,
    /// whatever its own keyword is.
    static func decode(_ input: String) -> [ClientCommand] {
        // Strip a trailing CR from every line.
        var units = Array(input.utf16)
        while units.last == 0x0D { units.removeLast() }
        let line = String(decoding: units, as: UTF16.self)
        func starts(_ p: String) -> Bool { JavaString.startsWith(line, p) }

        if starts("TURN") {
            return crParts(line).compactMap { part in
                let f = fields(part)
                guard f.count > 2 else { return nil }
                let rotor = JavaString.trim(f[1])
                if f[2] == "CW" { return .turn(rotor: rotor, .cw) }
                if f[2] == "CCW" { return .turn(rotor: rotor, .ccw) }
                guard let d = JavaDouble.parse(f[2], allowComma: true) else { return nil }
                return .turn(rotor: rotor, .heading(d))
            }
        }
        if starts("SET_STACK") {
            return crParts(line).compactMap { part in
                let f = fields(part)
                guard f.count > 2 else { return nil }
                return .setStack(antenna: JavaString.trim(f[1]), selected: JavaString.parseBool(f[2]))
            }
        }
        if starts("SET_SWITCH") {
            return crParts(line).compactMap { part in
                let f = fields(part)
                guard f.count > 2 else { return nil }
                return .setSwitch(name: f[1], position: f[2], on: f.count > 3 ? JavaString.parseBool(f[3]) : nil)
            }
        }
        if starts("TO_DEC") {
            let f = fields(line)
            guard f.count > 3 else { return [] }
            return [.toDec(rotor: JavaString.trim(f[1]), lat: f[2], lon: f[3])]
        }
        if starts("TO_PRESET") {
            let f = fields(line)
            guard f.count > 2 else { return [] }
            return [.toPreset(rotor: f[1], preset: f[2])]
        }
        if starts("STOP") {
            return crParts(line).compactMap { part in
                let f = fields(part)
                guard f.count > 1 else { return nil }
                return .stop(rotor: JavaString.trim(f[1]))
            }
        }
        if starts("LOCK") {
            let f = fields(line)
            return f.count > 1 ? [.lock(f[1])] : []
        }
        if starts("UNLOCK") {
            let f = fields(line)
            return f.count > 1 ? [.unlock(f[1])] : []
        }
        if starts("GETHEAD") {
            let f = JavaString.split(line, separator: " ")
            return f.count > 1 ? [.getHead(f[1])] : []
        }
        if starts("GET_LOCATIONS") { return [.getLocations] }
        if starts("QUIT") { return [.quit] }
        if starts("RESTART") { return [.restart] }
        return [] // includes TORNADO_CAL / SET_TORNADO / TORNADOTURN, which servers ignore
    }
}
