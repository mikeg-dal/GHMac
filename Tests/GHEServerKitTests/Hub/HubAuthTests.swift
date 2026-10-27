import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite("Hub authentication")
struct HubAuthTests {
    @Test func authOnSuccess() async throws {
        let registry = MockRegistry(rotors: ["R1"], readings: [RotorReading(name: "R1", heading: 90, status: .ok)])
        let f = try await HubFixture.make(registry: registry, authenticate: true)
        let c = try await f.connect()
        try await c.login(user: "alice", password: HubFixture.alicePassword)
        let lines = try await c.waitForLines(5)
        #expect(lines[0] == "USER:")
        #expect(lines[1].hasPrefix("PASS:") && lines[1].count > 10)
        // Inventory, then the (empty) presets line, then the last known POINT.
        #expect(Array(lines[2...]) == [wire("ADD", "R1"), "", wire("POINT", "R1", "90.0", "0", "0")])
        #expect(await eventually { f.log.contains("Authorized Client : \t \t127.0.0.1 alice") })
        // The auth timer is gone: much later the client is still connected.
        await f.clock.advance(by: .seconds(30))
        #expect(await c.isClosed == false)
        try await c.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.stop("R1")]))
    }

    @Test func spec33VectorIsWhatTheEmulatorSends() {
        // Test vector: the emulator's login uses exactly these hashes.
        let p = GHAuth.passwordHash(user: "alice", password: "secret1")
        #expect(p.map { String(format: "%02x", $0) }.joined() == "5f454adf90338c2d88239a96773cb7feedb36e551a0c5387212a221ccea8601c")
        let r = GHAuth.response(user: "alice", challenge: "0.7316931046151538-81283467123456789011665432101234", passwordHash: p)
        #expect(r.map { String(format: "%02x", $0) }.joined() == "1912ccc6bb389e47bf97c8877c7b6eeba9110f5c1f0ac6cdd345f7d7135a37c7")
    }

    @Test func commandsRightBehindTheDigestAreKept() async throws {
        let f = try await HubFixture.make(registry: MockRegistry(rotors: ["R1"]), authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.send("alice")
        let pass = try await c.waitForLine { $0.hasPrefix("PASS:") }
        let digest = GHAuth.response(user: "alice", challenge: String(pass.dropFirst(5)),
                                     passwordHash: GHAuth.passwordHash(user: "alice", password: HubFixture.alicePassword))
        // The server must cope with digest + command in one chunk.
        try await c.sendRaw(digest + Array("STOP\u{1F}R1\r\n".utf8))
        #expect(await f.waitForCalls([.stop("R1")]))
        try await c.waitForLine { $0 == wire("ADD", "R1") }
    }

    @Test func wrongDigestGetsInvalidThenCloseThenClosed() async throws {
        let f = try await HubFixture.make(registry: MockRegistry(rotors: ["R1"]), authenticate: true)
        let c = try await f.connect()
        try await c.login(user: "alice", password: "wrong!")
        try await c.waitUntilClosed()
        let lines = await c.receivedLines
        #expect(lines.count == 4)
        #expect(Array(lines.dropFirst(2)) == ["INVALID USER/PASS", "CLOSE"])
        let bytes = await c.receivedBytes
        #expect(bytes.suffix(26) == ArraySlice(Array("INVALID USER/PASS\r\nCLOSE\r\n".utf8)))
        #expect(await eventually { f.log.contains("Invalid user/pass: \t \t127.0.0.1") })
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 0 })
    }

    @Test func unknownUserIsRejected() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.login(user: "mallory", password: HubFixture.alicePassword)
        try await c.waitUntilClosed()
        #expect(Array(await c.receivedLines.dropFirst(2)) == ["INVALID USER/PASS", "CLOSE"])
    }

    @Test func emptyUserGetsInvalidAndClose() async throws {
        // The Local Controller's empty user is rejected at once instead of timing out.
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.send("")
        try await c.waitUntilClosed()
        #expect(await c.receivedLines == ["USER:", "INVALID USER/PASS", "CLOSE"])
    }

    @Test func whitespaceOnlyUserIsRejectedToo() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.send("   ")
        try await c.waitUntilClosed()
        #expect(await c.receivedLines == ["USER:", "INVALID USER/PASS", "CLOSE"])
    }

    @Test func keepaliveBeforeUserIsNotAUser() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.sendKeepalive()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await c.receivedLines == ["USER:"])
        try await c.send("alice")
        try await c.waitForLine { $0.hasPrefix("PASS:") }
    }

    @Test func authTimeoutAfterFiveSecondsSendsClose() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        let clock = f.clock
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .milliseconds(4900))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await c.isClosed == false)
        await clock.advance(by: .milliseconds(200))
        try await c.waitUntilClosed()
        #expect(await c.receivedLines == ["USER:", "CLOSE"])   // CLOSE before closing
        #expect(await eventually { f.log.contains("Auth Timout: \t \t127.0.0.1") })
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 0 })
    }

    @Test func authTimeoutAlsoAppliesAfterTheUserName() async throws {
        let f = try await HubFixture.make(authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.send("alice")
        try await c.waitForLine { $0.hasPrefix("PASS:") }
        let clock = f.clock
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .seconds(5))
        try await c.waitUntilClosed()
        #expect(await c.receivedLines.last == "CLOSE")
    }

    @Test func noCommandsBeforeAuthentication() async throws {
        let f = try await HubFixture.make(registry: MockRegistry(rotors: ["R1"]), authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        try await c.send("alice")
        try await c.waitForLine { $0.hasPrefix("PASS:") }
        // 32 bytes of garbage as the "digest"; the STOP must never run.
        try await c.sendRaw(Array(repeating: 0x41, count: 32))
        try? await c.send(wire("STOP", "R1"))
        try await c.waitUntilClosed()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await f.registry.commandCalls.isEmpty)
    }
}
