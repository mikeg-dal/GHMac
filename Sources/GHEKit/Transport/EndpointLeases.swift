import Foundation
import Synchronization

/// Exclusive-use registry: at most one open link per `Endpoint.leaseKey`
/// (serial path or host:port). The RT-21 network module accepts one TCP connection,
/// and a serial port can only be opened once, so a second user is refused up front
/// with `TransportError.endpointBusy(owner)` instead of disturbing the first.
public final class EndpointLeases: Sendable {
    /// Process-wide registry used by the apps.
    public static let shared = EndpointLeases()

    private struct Entry { let token: UInt64; let owner: String }
    private struct State { var next: UInt64 = 0; var held: [String: Entry] = [:] }
    private let state = Mutex(State())

    /// Tests make their own instance.
    public init() {}

    /// Takes the lease for `endpoint`. Throws `endpointBusy(currentOwner)` if someone holds it.
    public func acquire(_ endpoint: Endpoint, owner: String) throws -> EndpointLease {
        try acquire(key: endpoint.leaseKey, owner: owner)
    }

    public func acquire(key: String, owner: String) throws -> EndpointLease {
        let token = try state.withLock { s -> UInt64 in
            if let e = s.held[key] { throw TransportError.endpointBusy(e.owner) }
            s.next += 1
            s.held[key] = Entry(token: s.next, owner: owner)
            return s.next
        }
        return EndpointLease(registry: self, key: key, token: token, owner: owner)
    }

    /// Who holds `endpoint` now, if anyone.
    public func owner(of endpoint: Endpoint) -> String? {
        state.withLock { $0.held[endpoint.leaseKey]?.owner }
    }

    public var heldKeys: Set<String> { state.withLock { Set($0.held.keys) } }

    fileprivate func release(key: String, token: UInt64) {
        state.withLock { s in
            if s.held[key]?.token == token { s.held[key] = nil }
        }
    }
}

/// A held lease. Release it explicitly; it is also released when deallocated.
public final class EndpointLease: Sendable {
    public let key: String
    public let owner: String
    private let token: UInt64
    private let registry: EndpointLeases
    private let released = Mutex(false)

    fileprivate init(registry: EndpointLeases, key: String, token: UInt64, owner: String) {
        self.registry = registry; self.key = key; self.token = token; self.owner = owner
    }

    /// Idempotent.
    public func release() {
        let first = released.withLock { r -> Bool in defer { r = true }; return !r }
        if first { registry.release(key: key, token: token) }
    }

    public var isReleased: Bool { released.withLock { $0 } }

    deinit { release() }
}

/// Wraps any transport so that `open()` first takes the endpoint's lease and `close()`
/// releases it after the inner transport has fully closed.
public final class LeasedTransport: ByteTransport, ModemControl {
    public let inner: any ByteTransport
    public let endpoint: Endpoint
    public let owner: String
    private let leases: EndpointLeases
    private let lease = Mutex<EndpointLease?>(nil)

    public init(_ inner: any ByteTransport, endpoint: Endpoint, owner: String, leases: EndpointLeases = .shared) {
        self.inner = inner; self.endpoint = endpoint; self.owner = owner; self.leases = leases
    }

    public func open() async throws -> AsyncThrowingStream<[UInt8], any Error> {
        // Reopening (reconnect) keeps the lease this wrapper already holds.
        let fresh: EndpointLease?
        if lease.withLock({ $0 }) == nil {
            let l = try leases.acquire(endpoint, owner: owner)
            lease.withLock { $0 = l }
            fresh = l
        } else {
            fresh = nil
        }
        do {
            return try await inner.open()
        } catch {
            if let fresh {
                lease.withLock { if $0 === fresh { $0 = nil } }
                fresh.release()
            }
            throw error
        }
    }

    public func write(_ bytes: [UInt8]) async throws { try await inner.write(bytes) }

    public func close() async {
        await inner.close()
        let l = lease.withLock { l -> EndpointLease? in defer { l = nil }; return l }
        l?.release()
    }

    public func modemLines() async throws -> ModemLines {
        guard let m = inner as? any ModemControl else { throw TransportError.unsupported("modem lines") }
        return try await m.modemLines()
    }

    public var holdsLease: Bool { lease.withLock { $0 != nil } }
}
