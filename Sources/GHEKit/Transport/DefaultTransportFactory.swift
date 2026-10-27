import Foundation

/// Builds real transports: `.serial` → `POSIXSerialTransport`, `.tcp` → `TCPTransport`,
/// `.simulated` → whatever `simulated` returns (fake devices in simulator mode).
/// With `leases` set, every transport is wrapped in a `LeasedTransport`.
public struct DefaultTransportFactory: TransportFactory {
    public let leases: EndpointLeases?
    public let owner: String
    public let simulated: @Sendable (String) -> (any ByteTransport)?

    public init(leases: EndpointLeases? = .shared, owner: String = "GHMac",
                simulated: @escaping @Sendable (String) -> (any ByteTransport)? = { _ in nil }) {
        self.leases = leases; self.owner = owner; self.simulated = simulated
    }

    public func make(_ endpoint: Endpoint) -> any ByteTransport { make(endpoint, owner: owner) }

    /// Same as `make(_:)` with a specific owner description for busy messages ("Rotor 3").
    public func make(_ endpoint: Endpoint, owner: String) -> any ByteTransport {
        let raw: any ByteTransport
        switch endpoint {
        case .serial(let path, let settings): raw = POSIXSerialTransport(path: path, settings: settings)
        case .tcp(let host, let port): raw = TCPTransport(host: host, port: port)
        case .simulated(let id):
            raw = simulated(id) ?? MemoryTransport(openError: { TransportError.openFailed("no simulated device \"\(id)\"") })
        }
        guard let leases else { return raw }
        return LeasedTransport(raw, endpoint: endpoint, owner: owner, leases: leases)
    }
}
