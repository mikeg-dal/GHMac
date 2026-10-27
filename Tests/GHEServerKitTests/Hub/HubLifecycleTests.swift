import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite("Hub lifecycle")
struct HubLifecycleTests {
    @Test func overLimitClientGetsOnlyClose() async throws {
        let f = try await HubFixture.make(registry: MockRegistry(rotors: ["R1"]), maxConnections: 1)
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        try await a.waitForLine { $0 == wire("ADD", "R1") }
        let b = try await f.connect(from: "10.0.0.2")
        try await b.waitUntilClosed()
        // The limit is checked first; no inventory leaks to the rejected socket.
        #expect(await b.receivedLines == ["CLOSE"])
        #expect(await f.hub.connectionCount == 1)
        #expect(await a.isClosed == false)
    }

    @Test func overLimitWithAuthGetsOnlyClose() async throws {
        let f = try await HubFixture.make(authenticate: true, maxConnections: 1)
        let a = try await f.connectAndWait(expectedCount: 1)
        try await a.waitForLine { $0 == "USER:" }
        let b = try await f.connect()
        try await b.waitUntilClosed()
        #expect(await b.receivedLines == ["CLOSE"])
    }

    @Test func freedSlotCanBeReused() async throws {
        let f = try await HubFixture.make(maxConnections: 1)
        let a = try await f.connectAndWait(expectedCount: 1)
        await a.disconnect()
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 0 })
        let b = try await f.connectAndWait(expectedCount: 1)
        try await b.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.stop("R1")]))
    }

    @Test func restartClosesEveryoneAndListensAgain() async throws {
        let f = try await HubFixture.make(registry: MockRegistry(rotors: ["R1"]))
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        try await a.waitForLine { $0 == wire("ADD", "R1") }
        try await b.waitForLine { $0 == wire("ADD", "R1") }
        try await a.send("RESTART")
        try await a.waitUntilClosed()
        try await b.waitUntilClosed()
        #expect(await a.receivedLines.last == "CLOSE")
        #expect(await b.receivedLines.last == "CLOSE")
        let hub = f.hub
        #expect(await eventually { await hub.isRunning })
        #expect(f.server.listener.isListening)
        #expect(f.log.contains("Server stopped."))
        #expect(f.log.logLines.filter { $0 == "Server started." }.count == 2)
        let c = try await f.connect()
        try await c.waitForLine { $0 == wire("ADD", "R1") }
        #expect(await eventually { await hub.connectionCount == 1 })
    }

    @Test func restartCanBeDisabled() async throws {
        let f = try await HubFixture.make(allowRestart: false)
        let a = try await f.connectAndWait(expectedCount: 1)
        try await a.send("RESTART")
        try await a.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.stop("R1")]))
        #expect(await a.isClosed == false)
        #expect(f.log.contains("RESTART refused"))
    }

    @Test func stopSendsCloseToEveryClient() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let a = try await f.connectAndWait(expectedCount: 1)
        try await a.waitForLine { $0 == "USER:" }
        await f.hub.stop()
        try await a.waitUntilClosed()
        #expect(await a.receivedLines == ["USER:", "CLOSE"])
        #expect(await f.hub.isRunning == false)
        #expect(f.server.listener.isListening == false)
    }

    @Test func connectionEventsForTheUI() async throws {
        let f = try await HubFixture.make(maxConnections: 3)
        #expect(await eventually { f.log.events.contains(.running(true)) })
        let a = try await f.connectAndWait(from: "10.0.0.7", expectedCount: 1)
        #expect(await eventually { f.log.lastConnectionCount == 1 })
        let clients = await f.hub.clients
        #expect(clients.map(\.address) == ["10.0.0.7"])
        #expect(clients.first?.authenticated == true)
        #expect(f.log.events.contains { if case .connections(_, 3) = $0 { true } else { false } })
        #expect(f.log.contains("Accepted New Client : \t \t10.0.0.7"))
        await a.disconnect()
        #expect(await eventually { f.log.lastConnectionCount == 0 })
    }

    @Test func registryLogLinesReachTheHubLog() async throws {
        let f = try await HubFixture.make()
        await f.registry.emit(.log("ROTOR CONNECTED: \tR1"))
        #expect(await eventually { f.log.logLines.contains("ROTOR CONNECTED: \tR1") })
    }

    @Test func startTwiceThrows() async throws {
        let f = try await HubFixture.make()
        await #expect(throws: ServerHub.HubError.alreadyRunning) { try await f.hub.start() }
    }
}
