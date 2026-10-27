import Foundation
import GHEKit

/// `ports.ini`: every key is an extra port name.
///
/// Mac extension: a value of the form `host:port` (stored as `host\:port`; a bare `:` reads the
/// same) makes that key a TCP endpoint, e.g. `RT21-NET=192.168.70.13\:6555`. `RemoteAntenna`
/// means a TCP base.
public struct PortsIni: Sendable, Equatable {
    public static let fileName = "ports.ini"
    public static let remoteAntennaKey = "RemoteAntenna"
    public static let header = "File stores additional ports used in device manager"

    public var properties: JavaProperties

    public init(properties: JavaProperties = JavaProperties()) { self.properties = properties }

    public static func parse(_ data: Data) -> PortsIni { PortsIni(properties: JavaProperties.parse(data)) }

    /// A missing file means no extra ports.
    public static func load(from dirs: AppDirectories) -> PortsIni {
        guard let data = try? Data(contentsOf: dirs.file(fileName)) else { return PortsIni() }
        return parse(data)
    }

    public func save(to dirs: AppDirectories, date: Date = Date()) throws {
        try AtomicFile.write(properties.serialized(comment: Self.header, date: date), to: dirs.file(Self.fileName))
    }

    /// Keys in file order.
    public var portNames: [String] { properties.keys }

    /// The TCP target of a key whose value is `host:port`, else nil.
    public func tcpTarget(for key: String) -> (host: String, port: UInt16)? {
        properties[key].flatMap(Self.parseHostPort)
    }

    /// A serial device path given as a value (`MyRotor=/dev/cu.usbserial-A1`), else nil.
    public func serialAlias(for key: String) -> String? {
        guard let v = properties[key].map(JavaString.trim), v.hasPrefix("/dev/") else { return nil }
        return v
    }

    /// `host:port`, `[v6addr]:port`; port 1…65535; host without spaces. Anything else → nil.
    public static func parseHostPort(_ value: String) -> (host: String, port: UInt16)? {
        let v = JavaString.trim(value)
        guard let colon = v.lastIndex(of: ":") else { return nil }
        var host = String(v[..<colon])
        let portText = String(v[v.index(after: colon)...])
        guard let n = Int(portText), portText.allSatisfy(\.isASCII), (1...65535).contains(n) else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        // A bare IPv6 address without brackets would be ambiguous.
        if host.contains(":") && !v.hasPrefix("[") { return nil }
        return (host, UInt16(n))
    }
}
