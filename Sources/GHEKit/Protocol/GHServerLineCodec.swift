import Foundation

/// Text form of server → client lines and the client's decoder.
enum GHServerLineCodec {
    static let us = String(GHSeparator.unit)
    static let gs = String(GHSeparator.group)

    // MARK: encode

    static func text(_ message: ServerMessage) -> String {
        switch message {
        case .user: return "USER:"
        case .pass(let challenge): return "PASS:" + challenge
        case .invalidUserPass: return "INVALID USER/PASS"
        case .close: return "CLOSE"
        case .add(let name): return "ADD" + us + name
        case .remove(let name): return "REMOVE" + us + name
        case let .point(rotor, heading, status, rssi):
            return ["POINT", rotor, JavaDouble.string(heading), String(status.rawValue), String(rssi)].joined(separator: us)
        case .stackAdd(let names): return "STACKADD" + us + names.joined(separator: ",")
        case .stackRemove(let names): return "STACKREMOVE" + us + names.joined(separator: ",")
        case let .stack(names, selected, status, rssi):
            // Always four antenna flags on the wire.
            let flags = (0..<4).map { $0 < selected.count ? String(selected[$0]) : "false" }
            return (["STACK", names.joined(separator: ",")] + flags + [String(status), String(rssi)]).joined(separator: us)
        case .switchAdd(let d):
            var s = "SWITCHADD" + us + String(d.displayType) + us + d.name
            for p in d.positions {
                if d.displayType == SwitchDisplayType.band.rawValue {
                    s += us + [p.name, JavaDouble.string(p.lowerMHz), JavaDouble.string(p.upperMHz)].joined(separator: gs)
                } else {
                    s += us + [p.name, String(p.heading), String(p.beamwidth), String(p.bidirectional)].joined(separator: gs)
                }
            }
            return s
        case .switchRemove(let name): return "SWITCHREMOVE" + us + name
        case let .switchUpdate(name, state, status, rssi):
            return ["SWITCHUPDATE", name, state, String(status), String(rssi)].joined(separator: us)
        case let .switchLocks(name, states):
            return (["SWITCHLOCKS", name] + states).joined(separator: us)
        case .presetsLine(let names):
            // Always sent as an empty line.
            return names.isEmpty ? "" : (["LOCATIONS"] + names).joined(separator: us)
        case .popup(let text): return "POPUP" + us + text
        case .tornadoAdd(let t):
            return ["TORNADOADD", t.name, t.rotors.joined(separator: gs), t.positions.joined(separator: gs),
                    t.lower.joined(separator: gs), t.upper.joined(separator: gs)].joined(separator: us)
        case .tornadoRemove(let name): return "TORNADOREMOVE" + us + name
        case .tornado(let t):
            return (["TORNADO", t.name, String(t.status), String(t.rssi), t.position] + t.headings).joined(separator: us)
        case .ignored(let raw): return raw
        }
    }

    // MARK: decode (client dispatch order)

    static func decode(_ line: String) -> ServerMessage {
        decodeOrNil(line) ?? .ignored(line)
    }

    private static func split(_ s: String, _ sep: Character, limit: Int = 0) -> [String] {
        JavaString.split(s, separator: sep, limit: limit)
    }

    private static func field(_ f: [String], _ i: Int) -> String? { i < f.count ? f[i] : nil }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func decodeOrNil(_ line: String) -> ServerMessage? {
        func starts(_ p: String) -> Bool { JavaString.startsWith(line, p) }
        let US = GHSeparator.unit, GS = GHSeparator.group
        if line.isEmpty { return .presetsLine(names: []) } // the empty presets line
        if starts("USER:") { return .user }
        if starts("PASS:") { return field(split(line, ":", limit: 2), 1).map { .pass(challenge: $0) } }
        if line == "INVALID USER/PASS" { return .invalidUserPass }
        if starts("POINT") {
            // A malformed number yields .ignored instead of killing the connection.
            let f = split(line, US)
            guard let name = field(f, 1), let h = field(f, 2), let heading = JavaDouble.parse(h) else { return nil }
            var status = RotorStatus.stopped // legacy servers: status '2' when missing
            var rssi = 0
            if f.count > 3 {
                // Compare the first scalar, not the first grapheme.
                guard let ch = f[3].unicodeScalars.first, let s = RotorStatus(rawValue: Character(ch)) else { return nil }
                status = s
                if f.count > 4 {
                    guard let r = JavaString.parseInt(f[4]) else { return nil }
                    rssi = r
                }
            }
            return .point(rotor: name, heading: heading, status: status, rssi: rssi)
        }
        if starts("STACKADD") {
            return field(split(line, US), 1).map { .stackAdd(split($0, ",")) }
        }
        if starts("STACKREMOVE") {
            return field(split(line, US), 1).map { .stackRemove(split($0, ",")) }
        }
        if !starts("STACK") {
            if starts("TORNADOADD") {
                let f = split(JavaString.trim(line), US)
                guard f.count > 5 else { return nil }
                return .tornadoAdd(TornadoDescriptor(name: f[1], rotors: split(f[2], GS), positions: split(f[3], GS),
                                                     lower: split(f[4], GS), upper: split(f[5], GS)))
            }
            if starts("TORNADOREMOVE") {
                return field(split(JavaString.trim(line), US), 1).map { .tornadoRemove($0) }
            }
            if starts("TORNADO") {
                let f = split(JavaString.trim(line), US)
                guard f.count > 4, split(line, US).count > 3,
                      let status = JavaString.parseInt(f[2]), let rssi = JavaString.parseInt(f[3]) else { return nil }
                return .tornado(TornadoState(name: f[1], status: status, rssi: rssi, position: f[4], headings: Array(f[5...])))
            }
            if starts("SWITCHADD") { return decodeSwitchAdd(split(line, US)) }
            if starts("SWITCHREMOVE") { return field(split(line, US), 1).map { .switchRemove($0) } }
            if starts("SWITCHUPDATE") {
                let f = split(line, US)
                guard f.count > 4, let status = JavaString.parseInt(f[3]), let rssi = JavaString.parseInt(f[4]) else {
                    return nil
                }
                return .switchUpdate(name: f[1], state: f[2], status: status, rssi: rssi)
            }
            if starts("SWITCHLOCKS") {
                let f = split(line, US)
                guard f.count > 1 else { return nil }
                return .switchLocks(name: f[1], states: Array(f[2...]))
            }
            if starts("ADD") { return field(split(line, US), 1).map { .add($0) } }
            if starts("REMOVE") { return field(split(line, US), 1).map { .remove($0) } }
            if starts("LOCATIONS") {
                let f = split(line, US, limit: 2)
                return .presetsLine(names: f.count < 2 ? [] : split(f[1], US))
            }
            if !starts("SERVER_FULL") && starts("CLOSE") { return .close }
            return nil
        }
        // Any other line starting with STACK is a stack update.
        let f = split(line, US)
        guard f.count > 7, !split(f[1], ",").isEmpty,
              let status = JavaString.parseInt(f[6]), let rssi = JavaString.parseInt(f[7]) else { return nil }
        return .stack(names: split(f[1], ","), selected: (2...5).map { JavaString.parseBool(f[$0]) },
                      status: status, rssi: rssi)
    }

    /// SWITCHADD: types 1/2/4 carry `pos␝heading␝beamwidth␝bidirectional`, type 3 `pos␝lower␝upper`.
    /// Missing sub-fields default to 0/false (button and bank panels only use the name); a present
    /// but unparsable number is fatal for map (2) and band (3) switches.
    private static func decodeSwitchAdd(_ f: [String]) -> ServerMessage? {
        guard f.count > 2, let type = JavaString.parseInt(f[1]),
              let name = split(f[2], GHSeparator.group).first else { return nil }
        let strict = type == SwitchDisplayType.map.rawValue || type == SwitchDisplayType.band.rawValue
        var positions: [SwitchPosition] = []
        for entry in f.dropFirst(3) {
            let sub = split(entry, GHSeparator.group)
            var p = SwitchPosition(name: sub.first ?? "")
            if type == SwitchDisplayType.band.rawValue {
                if sub.count > 1 { guard let v = JavaDouble.parse(sub[1]) else { return nil }; p.lowerMHz = v }
                if sub.count > 2 { guard let v = JavaDouble.parse(sub[2]) else { return nil }; p.upperMHz = v }
            } else {
                if sub.count > 1 {
                    if let v = JavaString.parseInt(sub[1]) { p.heading = v } else if strict { return nil }
                }
                if sub.count > 2 {
                    if let v = JavaString.parseInt(sub[2]) { p.beamwidth = v } else if strict { return nil }
                }
                if sub.count > 3 { p.bidirectional = JavaString.parseBool(sub[3]) }
            }
            positions.append(p)
        }
        return .switchAdd(SwitchDescriptor(name: name, displayType: type, positions: positions))
    }
}
