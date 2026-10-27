import Foundation
import GHEKit

/// Everything needed to open one server connection.
public struct ConnectionRequest: Sendable {
    public var id: ServerID
    public var kind: ServerKind
    public var user: String
    /// P = SHA-256(user ‖ password low bytes); empty for terminal servers.
    public var passwordHash: [UInt8]
    /// Terminal servers: the synthetic rotor's name.
    public var rotorName: String
    public var terminalPoll: TerminalServerConnection.PollCommand
    public var traffic: TrafficSink?

    public init(id: ServerID, kind: ServerKind, user: String = "", passwordHash: [UInt8] = [],
                rotorName: String = "", terminalPoll: TerminalServerConnection.PollCommand = .integer,
                traffic: TrafficSink? = nil) {
        self.id = id; self.kind = kind; self.user = user; self.passwordHash = passwordHash
        self.rotorName = rotorName; self.terminalPoll = terminalPoll; self.traffic = traffic
    }
}

/// Injected services for supervisors: clock, name resolution and connection construction.
public struct ConnectionEnvironment: Sendable {
    public var clock: any GHEClock
    /// Host name → numeric address (Java `InetAddress.getByName(..).getHostAddress()`); nil = unknown host.
    public var resolve: @Sendable (String) async -> String?
    public var makeConnection: @Sendable (ConnectionRequest) -> any ServerConnection

    public init(clock: any GHEClock,
                resolve: @escaping @Sendable (String) async -> String?,
                makeConnection: @escaping @Sendable (ConnectionRequest) -> any ServerConnection) {
        self.clock = clock; self.resolve = resolve; self.makeConnection = makeConnection
    }

    /// Real network: NW TCP for servers, `TCPTransport` behind a lease for terminal servers.
    public static func live(clock: any GHEClock = SystemClock(), leases: EndpointLeases = .shared) -> ConnectionEnvironment {
        ConnectionEnvironment(clock: clock, resolve: HostResolver.resolve) { request in
            switch request.kind {
            case .ghServer:
                return GHServerConnection(id: request.id, user: request.user, passwordHash: request.passwordHash,
                                          connector: NWStreamConnector(), clock: clock, traffic: request.traffic)
            case .terminalServerTCP:
                return TerminalServerConnection(id: request.id, rotorName: request.rotorName, poll: request.terminalPoll,
                                                makeTransport: { TCPTransport(host: $0, port: $1) },
                                                leases: leases, clock: clock, traffic: request.traffic)
            }
        }
    }
}

/// Resolves a host name to a numeric address with `getaddrinfo` (IPv4 preferred).
public enum HostResolver {
    public static func resolve(_ name: String) async -> String? {
        let host = JavaString.trim(name)
        guard !host.isEmpty else { return nil }
        if let numeric = numericAddress(host) { return numeric }
        return await Task.detached { lookup(host) }.value
    }

    /// The text itself if it is already a numeric IPv4/IPv6 address.
    static func numericAddress(_ s: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return s }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return s }
        return nil
    }

    private static func lookup(_ host: String) -> String? {
        for family in [AF_INET, AF_INET6] {
            var hints = addrinfo()
            hints.ai_family = family
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { continue }
            defer { freeaddrinfo(result) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
