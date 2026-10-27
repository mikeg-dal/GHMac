import Foundation
import GHEKit

/// `settings_server.ini`, a Java Properties file with header `#Settings for server UI`.
public struct ServerSettings: Sendable, Equatable {
    public static let fileName = "settings_server.ini"
    public static let header = "Settings for server UI"

    public var port = 17220
    public var maxConnections = 4
    /// Station location (west-positive longitude, as TrigUtils expects).
    public var lat = 0.0
    public var lon = 0.0
    public var authenticate = false
    public var serverLogging = false
    public var rotorUiVisible = false
    public var serverWindowWidth = 500
    public var serverWindowHeight = 200
    public var serverWindowX = 0
    public var serverWindowY = 0
    public var serverMinimized = false
    /// The document as loaded: keeps unknown keys and key order for re-saving.
    public var document = JavaProperties()

    public init() {}

    /// Reads keys with their defaults. A bad value falls back to that key's default.
    public init(properties p: JavaProperties) {
        document = p
        func int(_ k: String, _ d: Int) -> Int { p[k].flatMap(JavaString.parseInt) ?? d }
        func dbl(_ k: String, _ d: Double) -> Double { p[k].flatMap { JavaDouble.parse($0) } ?? d }
        func bool(_ k: String) -> Bool { p[k].map(JavaString.parseBool) ?? false }
        port = int("port", 17220)
        if !(1...65535).contains(port) { port = 17220 }   // never listen on port 0
        maxConnections = int("maxConnections", 4)
        lat = dbl("lat", 0)
        lon = dbl("lon", 0)
        authenticate = bool("authenticate")
        serverLogging = bool("serverLogging")
        rotorUiVisible = bool("rotorUiVisible")
        serverWindowWidth = int("serverWindowWidth", 500)
        serverWindowHeight = int("serverWindowHeight", 200)
        serverWindowX = int("serverWindowX", 0)
        serverWindowY = int("serverWindowY", 0)
        serverMinimized = bool("serverMinimized")
    }

    /// The loaded document with every known key set.
    public var properties: JavaProperties {
        var p = document
        p["port"] = String(port)
        p["maxConnections"] = String(maxConnections)
        p["lat"] = JavaDouble.string(lat)
        p["lon"] = JavaDouble.string(lon)
        p["authenticate"] = String(authenticate)
        p["serverLogging"] = String(serverLogging)
        p["rotorUiVisible"] = String(rotorUiVisible)
        p["serverWindowWidth"] = String(serverWindowWidth)
        p["serverWindowHeight"] = String(serverWindowHeight)
        p["serverWindowX"] = String(serverWindowX)
        p["serverWindowY"] = String(serverWindowY)
        p["serverMinimized"] = String(serverMinimized)
        return p
    }

    public func serialized(date: Date = Date()) -> Data {
        properties.serialized(comment: Self.header, date: date)
    }

    public static func parse(_ data: Data) -> ServerSettings {
        ServerSettings(properties: JavaProperties.parse(data))
    }

    /// The folder is created first and a missing file simply means defaults.
    public static func load(from dirs: AppDirectories) -> ServerSettings {
        dirs.ensureExists()
        guard let data = try? Data(contentsOf: dirs.file(fileName)) else { return ServerSettings() }
        return parse(data)
    }

    public func save(to dirs: AppDirectories, date: Date = Date()) throws {
        try AtomicFile.write(serialized(date: date), to: dirs.file(Self.fileName))
    }
}
