import Testing
@testable import GHEKit

@Suite struct EndpointLeaseTests {
    let rt21 = Endpoint.tcp(host: "Rotor.Example", port: 6555)

    @Test func secondAcquireIsBusyWithOwner() throws {
        let leases = EndpointLeases()
        let a = try leases.acquire(rt21, owner: "Rotor 1")
        #expect(throws: TransportError.endpointBusy("Rotor 1")) {
            try leases.acquire(.tcp(host: "rotor.example", port: 6555), owner: "Terminal Server")
        }
        #expect(leases.owner(of: rt21) == "Rotor 1")
        a.release()
        a.release()   // idempotent
        #expect(leases.owner(of: rt21) == nil)
        let b = try leases.acquire(rt21, owner: "Terminal Server")
        a.release()   // a stale lease never frees someone else's
        #expect(leases.owner(of: rt21) == "Terminal Server")
        b.release()
    }

    @Test func differentEndpointsAreIndependent() throws {
        let leases = EndpointLeases()
        let a = try leases.acquire(rt21, owner: "a")
        let b = try leases.acquire(.tcp(host: "rotor.example", port: 6556), owner: "b")
        let c = try leases.acquire(.serial(path: "/dev/cu.x", .rotor), owner: "c")
        #expect(leases.heldKeys.count == 3)
        _ = (a, b, c)
    }

    @Test func leaseReleasedOnDeinit() throws {
        let leases = EndpointLeases()
        do { _ = try leases.acquire(rt21, owner: "temp") }
        #expect(leases.owner(of: rt21) == nil)
    }

    @Test func leasedTransportHoldsLeaseWhileOpen() async throws {
        let leases = EndpointLeases()
        let ep = Endpoint.simulated(id: "rt21")
        let one = LeasedTransport(MemoryTransport(), endpoint: ep, owner: "Server rotor", leases: leases)
        let two = LeasedTransport(MemoryTransport(), endpoint: ep, owner: "Client terminal", leases: leases)
        _ = try await one.open()
        #expect(one.holdsLease)
        await #expect(throws: TransportError.endpointBusy("Server rotor")) { _ = try await two.open() }
        _ = try await one.open()   // reopen keeps the lease
        await one.close()
        #expect(!one.holdsLease)
        _ = try await two.open()
        #expect(leases.owner(of: ep) == "Client terminal")
        await two.close()
        #expect(leases.heldKeys.isEmpty)
    }

    @Test func failedOpenReleasesLease() async throws {
        let leases = EndpointLeases()
        let ep = Endpoint.simulated(id: "x")
        let t = LeasedTransport(MemoryTransport(openError: { TransportError.openFailed("nope") }),
                                endpoint: ep, owner: "o", leases: leases)
        await #expect(throws: TransportError.openFailed("nope")) { _ = try await t.open() }
        #expect(leases.heldKeys.isEmpty)
    }

    @Test func factoryWrapsAndResolvesSimulated() async throws {
        let leases = EndpointLeases()
        let dev = FakeRT21Device(heading: 10)
        let f = FakeDevices.factory(["rt21": dev], leases: leases)
        let t = f.make(.simulated(id: "rt21"))
        #expect(t is LeasedTransport)
        _ = try await t.open()
        await #expect(throws: TransportError.endpointBusy("GHMac")) { _ = try await f.make(.simulated(id: "rt21")).open() }
        await t.close()
        await #expect(throws: (any Error).self) { _ = try await f.make(.simulated(id: "missing")).open() }
        // Real transports are only constructed, never opened, here.
        #expect(DefaultTransportFactory(leases: nil).make(.tcp(host: "127.0.0.1", port: 1)) is TCPTransport)
        #expect(DefaultTransportFactory(leases: nil).make(.serial(path: "/dev/null", .rotor)) is POSIXSerialTransport)
    }
}
