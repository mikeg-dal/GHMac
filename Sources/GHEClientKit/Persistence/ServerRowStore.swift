import Foundation
import GHEKit

/// One row of the Servers dialog as saved in `server.ini`. Fields are the raw text the
/// user typed (the port may be empty or invalid). Passwords are not here (Keychain).
public struct SavedServerRow: Sendable, Hashable {
    public var address: String
    public var port: String
    public var user: String
    /// Terminal Server (TCP) rotor name.
    public var rotorName: String
    public var kind: ServerKind
    /// The row was connected (or connecting/retrying) at quit → reconnect at startup.
    public var autoConnect: Bool

    public init(address: String = "", port: String = "", user: String = "", rotorName: String = "",
                kind: ServerKind = .ghServer, autoConnect: Bool = false) {
        self.address = address; self.port = port; self.user = user; self.rotorName = rotorName
        self.kind = kind; self.autoConnect = autoConnect
    }

    public var isEmpty: Bool { address.isEmpty && port.isEmpty && user.isEmpty && rotorName.isEmpty }
    public var portNumber: UInt16? { JavaString.parseInt(port).flatMap { UInt16(exactly: $0) } }
    public var serverID: ServerID? { portNumber.map { ServerID(host: address, port: $0) } }
}


/// `server.ini`: key `addr␟port␟user␟rotorName␟typeIdx␟rowIdx` (␟ = U+001F), value `true`/`false`.
public enum ServerRowCodec {
    public static let rowCount = 10
    static let us: Character = "\u{1F}"

    /// Decoding: 6-part keys go to their row index, 5-part (older)
    /// keys fill rows in file order. Out-of-range rows are ignored.
    public static func decode(_ p: JavaProperties) -> [SavedServerRow] {
        var rows = Array(repeating: SavedServerRow(), count: rowCount)
        var counter = 0
        for key in p.keys {
            let parts = JavaString.split(key, separator: us)
            guard parts.count == 5 || parts.count == 6 else { continue }
            let index: Int
            if parts.count == 6 {
                guard let i = JavaString.parseInt(parts[5]) else { continue }
                index = i
            } else {
                index = counter
                counter += 1
            }
            guard rows.indices.contains(index) else { continue }
            // setServerComboBox: a bad index leaves the default (GH Server).
            let kind = JavaString.parseInt(parts[4]).flatMap(ServerKind.init(rawValue:)) ?? .ghServer
            rows[index] = SavedServerRow(address: parts[0], port: parts[1], user: parts[2], rotorName: parts[3],
                                         kind: kind, autoConnect: legacyBool(p[key], default: false))
        }
        return rows
    }

    /// Encodes all 10 rows, empty or not.
    public static func encode(_ rows: [SavedServerRow]) -> JavaProperties {
        var p = JavaProperties()
        for (i, r) in rows.prefix(rowCount).enumerated() {
            let key = [r.address, r.port, r.user, r.rotorName, String(r.kind.rawValue), String(i)].joined(separator: "\u{1F}")
            p[key] = String(r.autoConnect)
        }
        return p
    }
}

/// `server.ini` on disk. It is rewritten from scratch on save.
public struct ServerRowStore: Sendable {
    public let file: PropertiesFile

    public init(directory: AppDirectories) {
        file = PropertiesFile(directory, ClientFileName.server, comment: "")
    }

    /// Always 10 rows.
    public func load() -> [SavedServerRow] { ServerRowCodec.decode(file.readOrEmpty()) }

    public func save(_ rows: [SavedServerRow]) throws {
        var padded = Array(rows.prefix(ServerRowCodec.rowCount))
        while padded.count < ServerRowCodec.rowCount { padded.append(SavedServerRow()) }
        try file.write(ServerRowCodec.encode(padded))
    }
}

/// `rotornames.ini`: `ip:port=name` for Terminal Server rotors.
public struct RotorNamesStore: Sendable {
    public let file: PropertiesFile

    public init(directory: AppDirectories) {
        file = PropertiesFile(directory, ClientFileName.rotorNames, comment: "File maps TCP Terminal server names to IP addresses.")
    }

    public static func key(host: String, port: UInt16) -> String { "\(host):\(port)" }

    public func load() -> [String: String] {
        let p = file.readOrEmpty()
        return Dictionary(uniqueKeysWithValues: p.keys.map { ($0, p[$0] ?? "") })
    }

    public func name(host: String, port: UInt16) -> String? { file.read()?[Self.key(host: host, port: port)] }

    public func setName(_ name: String, host: String, port: UInt16) throws {
        try file.update { $0[Self.key(host: host, port: port)] = name }
    }
}
