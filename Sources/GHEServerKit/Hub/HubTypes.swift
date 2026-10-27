import Foundation
import GHEKit

/// Listener and client-handling settings of the server hub (`settings_server.ini`).
public struct HubSettings: Sendable, Equatable {
    /// TCP port, for display; the listener itself is bound by whoever builds it.
    public var port: UInt16
    /// Maximum simultaneous connections, authenticated or not. Applies to new accepts.
    public var maxConnections: Int
    /// "Authenticate Users". Sampled per connection when it is accepted.
    public var authenticate: Bool
    /// Whether a client's `RESTART` command is honoured (opt-out).
    public var allowRestart: Bool
    /// Station latitude for `TO_DEC`, degrees north positive.
    public var stationLatitude: Double
    /// Station longitude for `TO_DEC`, degrees **west positive** like TrigUtils.
    public var stationLongitude: Double

    public init(port: UInt16 = ghDefaultServerPort, maxConnections: Int = ghDefaultMaxConnections,
                authenticate: Bool = false, allowRestart: Bool = true,
                stationLatitude: Double = 0, stationLongitude: Double = 0) {
        self.port = port; self.maxConnections = maxConnections; self.authenticate = authenticate
        self.allowRestart = allowRestart; self.stationLatitude = stationLatitude; self.stationLongitude = stationLongitude
    }
}

/// One connected client as shown in the server UI.
public struct HubClientInfo: Sendable, Equatable, Identifiable {
    public var id: UInt64
    /// Peer IP address.
    public var address: String
    public var authenticated: Bool
    /// The user name once authenticated (nil with authentication off).
    public var user: String?
    public init(id: UInt64, address: String, authenticated: Bool, user: String? = nil) {
        self.id = id; self.address = address; self.authenticated = authenticated; self.user = user
    }
}

/// What the server UI needs from the hub: log lines, running state and the connection list.
public enum HubEvent: Sendable, Equatable {
    /// One log-window line.
    case log(String)
    case running(Bool)
    /// Current connections (count = `clients.count`) and the configured maximum.
    case connections(clients: [HubClientInfo], max: Int)
}
