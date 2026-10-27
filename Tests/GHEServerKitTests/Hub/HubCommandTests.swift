import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite("Hub commands")
struct HubCommandTests {
    @Test func nulPingsBetweenCommands() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.sendKeepalive()
        try await c.send(wire("TURN", "R1", "10"))
        try await c.sendKeepalive()
        try await c.sendKeepalive()
        try await c.send(wire("STOP", "R1"))
        // A NUL glued in front of a command no longer kills it.
        try await c.sendRaw([0x00] + Array("STOP\u{1F}R2\r\n".utf8))
        #expect(await f.waitForCalls([.turn("R1", .heading(10)), .stop("R1"), .stop("R2")]))
        #expect(await c.isClosed == false)
    }

    @Test func coalescedCommandsInOneChunk() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.sendCoalesced([wire("TURN", "R1", "10"), wire("STOP", "R1"), wire("TURN", "R2", "CW")])
        #expect(await f.waitForCalls([.turn("R1", .heading(10)), .stop("R1"), .turn("R2", .cw)]))
        // Every command is echoed to the log in arrival order.
        let echoes = f.log.logLines.filter { $0.hasSuffix("\t \t127.0.0.1") && !$0.hasPrefix("Accepted") }
        #expect(echoes == [wire("TURN", "R1", "10") + "\t \t127.0.0.1", wire("STOP", "R1") + "\t \t127.0.0.1",
                           wire("TURN", "R2", "CW") + "\t \t127.0.0.1"])
    }

    @Test func commandSplitAcrossTwoChunks() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.sendSplit(wire("TURN", "R1", "271.5"), at: 6)   // line buffering
        try await c.sendSplit(wire("STOP", "R1"), at: 8)            // split between CR and LF
        #expect(await f.waitForCalls([.turn("R1", .heading(271.5)), .stop("R1")]))
    }

    @Test func malformedLinesDoNotDropTheClient() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        for bad in ["TURN", wire("TURN", "R1"), wire("TURN", "R1", "abc"), wire("TURN", "R1", ""), "TO_DEC",
                    wire("TO_DEC", "R1", "x", "y"), "LOCK", "UNLOCK", "GETHEAD", "SET_STACK", "SET_SWITCH",
                    wire("SET_SWITCH", "SW"), "STOP", "garbage", "\u{1F}\u{1F}", wire("TURN", "R1", "NaN"),
                    wire("TURN", "R1", "Infinity"), wire("TORNADOTURN", "T", "R1", "CW"), wire("TORNADO_CAL", "T", "R1"),
                    wire("SET_TORNADO", "T", "P")] {
            try await c.send(bad)
        }
        try await c.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.stop("R1")]))
        #expect(await c.isClosed == false)
        #expect(await f.hub.connectionCount == 1)
    }

    @Test func turnTargetForms() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.send(wire("TURN", "R1", "271,5"))
        try await c.send(wire("TURN", "R1", "123d"))
        try await c.send(wire("TURN", "R1", "CW"))
        try await c.send(wire("TURN", "R1", "CCW"))
        try await c.send(wire("TURN", " R1 ", " 1e2 "))
        try await c.send(wire("TURN", "R1", "1") + "\r" + wire("TURN", "R2", "2"))   // bare-CR batch
        #expect(await f.waitForCalls([
            .turn("R1", .heading(271.5)), .turn("R1", .heading(123)), .turn("R1", .cw), .turn("R1", .ccw),
            .turn("R1", .heading(100)), .turn("R1", .heading(1)), .turn("R2", .heading(2)),
        ]))
    }

    @Test func setStackPassesNameAndJavaBoolean() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.send(wire("SET_STACK", " yagi MID ", "TRUE"))
        try await c.send(wire("SET_STACK", "Yagi Top", "yes"))
        #expect(await f.waitForCalls([.setStack("yagi MID", true), .setStack("Yagi Top", false)]))
    }

    @Test func setSwitchBankAndLockout() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.send(wire("SET_SWITCH", "Band SW", "20m"))
        try await c.send(wire("SET_SWITCH", "Bank A", "Amp", "false"))
        #expect(await f.waitForCalls([.setSwitch("Band SW", "20m", nil), .setSwitch("Bank A", "Amp", false)]))
        await f.registry.setSwitchResult(.lockedOut)
        try await c.send(wire("SET_SWITCH", "Band SW", "40m"))
        #expect(await f.waitForCalls([.setSwitch("Band SW", "20m", nil), .setSwitch("Bank A", "Amp", false),
                                      .setSwitch("Band SW", "40m", nil)]))
    }

    @Test func toDecUsesStationLocationWestPositive() async throws {
        let f = try await HubFixture.make(latitude: 41.7147, longitude: 72.7272)   // W1AW, 72.7°W
        let c = try await f.connect()
        try await c.send(wire("TO_DEC", "R1", "51,5074", "0.1278"))                // London, 0.13°W
        let expected = try #require(TrigUtils.heading(fromLatitude: 41.7147, fromLongitude: 72.7272,
                                                      toLatitude: 51.5074, toLongitude: 0.1278))
        #expect(await f.waitForCalls([.turn("R1", .heading(expected))]))
        #expect(abs(expected - 52.2) < 0.1)
        // Same point → ignored.
        try await c.send(wire("TO_DEC", "R1", "41.7147", "72.7272"))
        try await c.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.turn("R1", .heading(expected)), .stop("R1")]))
    }

    @Test func toPresetIsIgnoredSafely() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.send(wire("TO_PRESET", "R1", "Home"))
        try await c.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.stop("R1")]))
        #expect(await c.isClosed == false)
    }

    @Test func getHeadIsSpaceSeparated() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connect()
        try await c.send("GETHEAD Tower 40m")
        #expect(await eventually { await f.registry.calls == [.query("Tower")] })
    }

    @Test func getLocationsAnswersOnlyTheRequester() async throws {
        let f = try await HubFixture.make()
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        try await a.send("GET_LOCATIONS")
        #expect(try await a.waitForLines(1) == [""])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await b.receivedLines.isEmpty)   // requester only
    }

    @Test func lockGatesTurnAndStopByIP() async throws {
        let f = try await HubFixture.make()
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        try await a.send(wire("LOCK", "R1"))
        let hub = f.hub
        #expect(await eventually { await hub.rotorLocks == ["R1": "10.0.0.1"] })
        try await b.send(wire("TURN", "R1", "10"))
        try await b.send(wire("STOP", "R1"))
        try await b.send(wire("UNLOCK", "R1"))          // not the owner: no effect
        try await b.send(wire("SET_STACK", "S", "true")) // not gated
        #expect(await f.waitForCalls([.setStack("S", true)]))
        try await a.send(wire("TURN", "R1", "20"))
        #expect(await f.waitForCalls([.setStack("S", true), .turn("R1", .heading(20))]))
        // Another connection from the same IP shares the lock…
        let a2 = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 3)
        try await a2.send(wire("STOP", "R1"))
        #expect(await f.waitForCalls([.setStack("S", true), .turn("R1", .heading(20)), .stop("R1")]))
        // …and the first one from that IP to disconnect releases it.
        await a2.disconnect()
        #expect(await eventually { await hub.rotorLocks.isEmpty })
        try await b.send(wire("TURN", "R1", "30"))
        #expect(await f.waitForCalls([.setStack("S", true), .turn("R1", .heading(20)), .stop("R1"), .turn("R1", .heading(30))]))
        _ = a
    }

    @Test func unlockByOwner() async throws {
        let f = try await HubFixture.make()
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        try await a.send(wire("LOCK", "R1"))
        try await a.send(wire("UNLOCK", "R1"))
        try await a.send(wire("STOP", "R9"))
        #expect(await f.waitForCalls([.stop("R9")]))
        #expect(await f.hub.rotorLocks.isEmpty)
    }

    @Test func perClientOrderingWithASlowDevice() async throws {
        let registry = MockRegistry()
        await registry.setSlowRotor("Slow")
        let f = try await HubFixture.make(registry: registry)
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        try await a.send(wire("TURN", "Slow", "1"))
        try await a.send(wire("TURN", "R2", "2"))
        try await a.send(wire("STOP", "Slow"))
        // Reading is not blocked: the third command is already echoed while the first one runs…
        #expect(await eventually { f.log.logLines.contains(wire("STOP", "Slow") + "\t \t10.0.0.1") })
        // …and another client's command runs meanwhile.
        try await b.send(wire("STOP", "Other"))
        #expect(await f.waitForCalls([.turn("Slow", .heading(1)), .stop("Other")]))
        // Client A's later commands wait for its first one.
        await registry.gate.open()
        #expect(await f.waitForCalls([.turn("Slow", .heading(1)), .stop("Other"), .turnFinished("Slow"),
                                      .turn("R2", .heading(2)), .stop("Slow")]))
    }

    @Test func quitClosesWithoutCloseLine() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connectAndWait(expectedCount: 1)
        try await c.send("QUIT")
        try await c.waitUntilClosed()
        #expect(await c.receivedLines.isEmpty)
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 0 })
        #expect(f.log.contains("Disconnecting:"))
        #expect(f.log.contains("Client Disconnected \t \t127.0.0.1"))
    }

    @Test func eofIsCleanedUpLikeQuit() async throws {
        let f = try await HubFixture.make()
        let c = try await f.connectAndWait(expectedCount: 1)
        try await c.send(wire("STOP", "R1"))
        await c.disconnect()   // QUIT is never flushed
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 0 })
        #expect(await f.waitForCalls([.stop("R1")]))   // commands before EOF still run
        #expect(await eventually { f.log.contains("Client Disconnected") })
    }
}
