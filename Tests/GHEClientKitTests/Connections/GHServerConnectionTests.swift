import Foundation
import Testing
import GHEKit
import GHESimKit
@testable import GHEClientKit

@Suite("GHServerConnection against the server emulator")
struct GHServerConnectionTests {
    static let challenge = "0.7316931046151538-81283467123456789011665432101234"
    static let aliceP = GHAuth.passwordHash(user: "alice", password: "secret1")
    let server = ServerID(host: "127.0.0.1", port: 17220)

    func connect(_ emu: JavaServerEmulator, user: String = "alice", hash: [UInt8] = aliceP,
                 clock: ManualClock = ManualClock()) async throws -> (GHServerConnection, EventLog) {
        let conn = GHServerConnection(id: server, user: user, passwordHash: hash,
                                      connector: emu.connector(), clock: clock)
        let log = EventLog()
        log.start(try await conn.connect())
        return (conn, log)
    }

    @Test func digestIsWrittenAloneWithoutTerminator() async throws {
        let emu = JavaServerEmulator(authenticate: true, users: ["alice": Self.aliceP], challenge: Self.challenge,
                                     inventory: [wire("ADD", "Tower 40m")])
        let (conn, log) = try await connect(emu)
        #expect(await eventually { emu.current?.phase == .authenticated })
        let s = try #require(emu.current)
        #expect(s.violations.isEmpty)
        #expect(s.chunks.count == 2)
        #expect(s.chunks[0] == Array("alice\r\n".utf8))
        let digest = s.chunks[1]
        #expect(digest.count == 32)
        // Test vector.
        #expect(digest.map { String(format: "%02x", $0) }.joined()
                == "1912ccc6bb389e47bf97c8877c7b6eeba9110f5c1f0ac6cdd345f7d7135a37c7")
        #expect(await eventually { log.messages.contains(.add("Tower 40m")) })
        #expect(log.all.first == .connected)
        await conn.disconnect()
    }

    @Test func commandsQueuedDuringAuthWaitForThePostAuthLine() async throws {
        let emu = JavaServerEmulator(authenticate: true, users: ["alice": Self.aliceP], challenge: Self.challenge)
        let (conn, _) = try await connect(emu)
        conn.enqueue(.stop(rotor: "Tower 40m"))
        #expect(await eventually { emu.current?.commands.contains(wire("STOP", "Tower 40m")) == true })
        let s = try #require(emu.current)
        #expect(s.violations.isEmpty)
        #expect(s.chunks.count == 3)   // user, digest, STOP — never coalesced
        #expect(s.chunks[2] == Windows1252.encode(wire("STOP", "Tower 40m") + "\r\n"))
        await conn.disconnect()
    }

    @Test func postAuthHoldReleasesCommandsWhenTheServerStaysSilent() async throws {
        let clock = ManualClock()
        let (client, serverEnd) = MemoryStreamConnection.pair()
        let conn = GHServerConnection(id: server, user: "alice", passwordHash: Self.aliceP,
                                      connector: MemoryConnector { _, _ in client }, clock: clock)
        let log = EventLog()
        log.start(try await conn.connect())
        try await serverEnd.send(Array("USER:\r\nPASS:abc\r\n".utf8))
        #expect(await eventually { client.sentChunks.count == 2 })
        conn.enqueue(.turn(rotor: "R", .heading(90)))
        await clock.settle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.sentChunks.count == 2)   // held
        await clock.advance(by: .milliseconds(250))
        #expect(await eventually { client.sentChunks.count == 3 })
        #expect(client.sentChunks[2] == Windows1252.encode(wire("TURN", "R", "90.0") + "\r\n"))
        await conn.disconnect()
    }

    @Test func everyCommandIsItsOwnChunkUnder256BytesWithoutNUL() async throws {
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1")])
        let (conn, log) = try await connect(emu)
        #expect(await eventually { log.messages.contains(.add("R1")) })
        let commands: [ClientCommand] = [
            .turn(rotor: "R1", .heading(271.5)), .turn(rotor: "R1", .cw), .stop(rotor: "R1"),
            .setStack(antenna: "Yagi Mid", selected: true), .setSwitch(name: "Bank A", position: "Amp", on: false),
            .setSwitch(name: "Band SW", position: "20m", on: nil),
            .turn(rotor: String(repeating: "x", count: 300), .heading(1)),   // too long: dropped
            .stop(rotor: "R1"),
        ]
        for c in commands { conn.enqueue(c) }
        #expect(await eventually { emu.current?.commands.count == 7 })
        let s = try #require(emu.current)
        #expect(s.violations.isEmpty)
        #expect(s.chunks.count == 7)
        for chunk in s.chunks {
            #expect(chunk.count < 256)
            #expect(!chunk.contains(0))
            #expect(chunk.suffix(2) == [0x0D, 0x0A])
            #expect(chunk.filter { $0 == 0x0A }.count == 1)
        }
        #expect(s.commands == [wire("TURN", "R1", "271.5"), wire("TURN", "R1", "CW"), wire("STOP", "R1"),
                               wire("SET_STACK", "Yagi Mid", "true"), wire("SET_SWITCH", "Bank A", "Amp", "false"),
                               wire("SET_SWITCH", "Band SW", "20m"), wire("STOP", "R1")])
        await conn.disconnect()
    }

    @Test func keepalivePingsAt10_15_20AndSkipsAfterACommand() async throws {
        let clock = ManualClock()
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1")])
        let (conn, log) = try await connect(emu, clock: clock)
        #expect(await eventually { log.messages.count == 1 })
        let s = try #require(emu.current)
        await clock.advance(by: .milliseconds(9_900))
        #expect(s.pings == 0)
        await clock.advance(by: .milliseconds(100))
        #expect(await eventually { s.pings == 1 })
        await clock.advance(by: .seconds(5))
        #expect(await eventually { s.pings == 2 })
        await clock.advance(by: .seconds(5))
        #expect(await eventually { s.pings == 3 })        // t = 20
        await clock.advance(by: .seconds(1))              // t = 21: a command goes out
        conn.enqueue(.stop(rotor: "R1"))
        #expect(await eventually { s.commands.count == 1 })
        await clock.advance(by: .seconds(4))              // t = 25: command 4 s ago → skipped
        try await Task.sleep(for: .milliseconds(30))
        #expect(s.pings == 3)
        await clock.advance(by: .seconds(5))              // t = 30
        #expect(await eventually { s.pings == 4 })
        #expect(s.violations.isEmpty)
        #expect(s.chunks.filter { $0 == [0] }.count == 4)   // each ping alone
        await conn.disconnect()
    }

    @Test func invalidCredentialsEndTheConnection() async throws {
        let emu = JavaServerEmulator(authenticate: true, users: ["alice": Self.aliceP], challenge: Self.challenge)
        let (_, log) = try await connect(emu, hash: GHAuth.passwordHash(user: "alice", password: "wrong"))
        #expect(await eventually { log.hasEnded })
        #expect(log.all == [.connected, .invalidCredentials])
    }

    @Test func closeFromServerIsReported() async throws {
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1"), "CLOSE"])
        let (_, log) = try await connect(emu)
        #expect(await eventually { log.hasEnded })
        // Tolerance: inventory followed by CLOSE.
        #expect(log.all == [.connected, .message(.add("R1")), .closedByServer])
        #expect(await eventually { emu.current?.sawEOF == true })
    }

    @Test func eofIsAnImmediateLoss() async throws {
        let clock = ManualClock()
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1")])
        let (_, log) = try await connect(emu, clock: clock)
        #expect(await eventually { log.messages.count == 1 })
        await emu.current?.close()
        // No clock advance needed.
        #expect(await eventually { log.lost && log.hasEnded })
    }

    @Test func resetIsALoss() async throws {
        let emu = JavaServerEmulator()
        let (_, log) = try await connect(emu)
        emu.current?.reset()
        #expect(await eventually { log.lost })
    }

    @Test func disconnectSendsAFlushedQuitThenCloses() async throws {
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1")])
        let (conn, log) = try await connect(emu)
        #expect(await eventually { log.messages.count == 1 })
        await conn.disconnect()
        let s = try #require(emu.current)
        #expect(await eventually { s.sawEOF })
        #expect(s.sawQuit)
        #expect(s.chunks.last == Array("QUIT\r\n".utf8))
        #expect(await eventually { log.hasEnded })
    }

    @Test func serverLinesAcrossChunksAndTerminators() async throws {
        let emu = JavaServerEmulator()
        let (conn, log) = try await connect(emu)
        let s = try #require(emu.current)
        let bytes = Windows1252.encode(wire("ADD", "A") + "\n" + wire("ADD", "B") + "\r" + wire("POINT", "A", "12.5", "0", "-70") + "\r\n")
        await s.sendRaw(Array(bytes[0..<5]))
        await s.sendRaw(Array(bytes[5...]))
        #expect(await eventually { log.messages.count == 3 })
        #expect(log.messages == [.add("A"), .add("B"), .point(rotor: "A", heading: 12.5, status: .ok, rssi: -70)])
        await conn.disconnect()
    }
}
