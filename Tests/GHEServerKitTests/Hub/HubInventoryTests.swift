import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite("Hub inventory and broadcasts")
struct HubInventoryTests {
    static let map = SwitchDescriptor(name: "6-Pack", displayType: 2, positions: [
        SwitchPosition(name: "North", heading: 0, beamwidth: 60),
        SwitchPosition(name: "Omni", heading: 0, beamwidth: 360),
    ])

    @Test func authOffInventoryOrderThenPoint() async throws {
        let registry = MockRegistry(rotors: ["Tower 40m", "Yagi"], switches: [Self.map],
                                    stacks: [["Yagi Top", "Yagi Mid", "Yagi Bot"]],
                                    readings: [RotorReading(name: "Tower 40m", heading: 271, status: .ok)])
        let f = try await HubFixture.make(registry: registry)
        let c = try await f.connect()
        let lines = try await c.waitForLines(5)
        #expect(lines == [
            wire("ADD", "Tower 40m"),
            wire("ADD", "Yagi"),
            wire("SWITCHADD", "2", "6-Pack", "North\u{1D}0\u{1D}60\u{1D}false", "Omni\u{1D}0\u{1D}360\u{1D}false"),
            wire("STACKADD", "Yagi Top,Yagi Mid,Yagi Bot"),
            wire("POINT", "Tower 40m", "271.0", "0", "0"),
        ])
        // The rotor without a known reading is queried.
        #expect(await eventually { await registry.calls == [.query("Yagi")] })

        await registry.emit(.reading(RotorReading(name: "Yagi", heading: 45.3, status: .ok, rssi: -71)))
        try await c.waitForLine { $0 == wire("POINT", "Yagi", "45.3", "0", "-71") }
        // Exact bytes, CR LF terminated.
        let bytes = await c.receivedBytes
        #expect(Array(bytes.prefix(Array("ADD\u{1F}Tower 40m\r\n".utf8).count)) == Array("ADD\u{1F}Tower 40m\r\n".utf8))
    }

    @Test func liveEventsAreBroadcastToEveryClient() async throws {
        let registry = MockRegistry()
        let f = try await HubFixture.make(registry: registry)
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        await registry.emit(.rotorAdded("R1"))
        await registry.emit(.switchAdded(SwitchDescriptor(name: "Band SW", displayType: 3, positions: [
            SwitchPosition(name: "40m", lowerMHz: 7.0, upperMHz: 7.3)])))
        await registry.emit(.switchUpdated(name: "Band SW", state: "40m", status: 0, rssi: -58))
        await registry.emit(.switchLocks(name: "Band SW", states: ["40m", "20m"]))
        await registry.emit(.stackAdded(["A", "B"]))
        await registry.emit(.stackUpdated(names: ["A", "B"], selected: [true, false, false, false], status: 0, rssi: -64))
        await registry.emit(.stackRemoved(["A", "B"]))
        await registry.emit(.switchRemoved("Band SW"))
        await registry.emit(.rotorRemoved("R1"))
        let expected = [
            wire("ADD", "R1"),
            wire("SWITCHADD", "3", "Band SW", "40m\u{1D}7.0\u{1D}7.3"),
            wire("SWITCHUPDATE", "Band SW", "40m", "0", "-58"),
            wire("SWITCHLOCKS", "Band SW", "40m", "20m"),
            wire("STACKADD", "A,B"),
            wire("STACK", "A,B", "true", "false", "false", "false", "0", "-64"),
            wire("STACKREMOVE", "A,B"),
            wire("SWITCHREMOVE", "Band SW"),
            wire("REMOVE", "R1"),
        ]
        #expect(try await a.waitForLines(expected.count) == expected)
        #expect(try await b.waitForLines(expected.count) == expected)
    }

    @Test func laterClientsGetTheMirroredInventory() async throws {
        let registry = MockRegistry(rotors: ["R1"])
        let f = try await HubFixture.make(registry: registry)
        let a = try await f.connectAndWait(expectedCount: 1)
        await registry.emit(.rotorAdded("R2"))
        await registry.emit(.reading(RotorReading(name: "R2", heading: 10, status: .ok)))
        await registry.emit(.rotorRemoved("R1"))
        try await a.waitForLine { $0 == wire("REMOVE", "R1") }
        let b = try await f.connect()
        #expect(try await b.waitForLines(2) == [wire("ADD", "R2"), wire("POINT", "R2", "10.0", "0", "0")])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await b.receivedLines.count == 2)   // no duplicates
    }

    @Test func stackAddAndSwitchLocksNeverReachUnauthenticatedClients() async throws {
        let registry = MockRegistry()
        let f = try await HubFixture.make(registry: registry, authenticate: true)
        let c = try await f.connect()
        try await c.waitForLine { $0 == "USER:" }
        await registry.emit(.stackAdded(["A", "B"]))
        await registry.emit(.switchLocks(name: "SW", states: ["x"]))
        await registry.emit(.stackRemoved(["A", "B"]))
        await registry.emit(.stackAdded(["C"]))
        await registry.emit(.rotorAdded("R1"))
        await registry.emit(.reading(RotorReading(name: "R1", heading: 5, status: .ok)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await c.receivedLines == ["USER:"])
        try await c.login(user: "alice", password: HubFixture.alicePassword)
        let lines = try await c.waitForLines(6)
        #expect(Array(lines.dropFirst(2)) == [wire("ADD", "R1"), wire("STACKADD", "C"), "", wire("POINT", "R1", "5.0", "0", "0")])
    }

    @Test func cp1252NamesOnTheWire() async throws {
        let name = "T\u{FC}rm \u{20AC}"   // "Türm €"
        let registry = MockRegistry(rotors: [name])
        let f = try await HubFixture.make(registry: registry)
        let c = try await f.connect()
        try await c.waitForLine { $0 == wire("ADD", name) }
        let bytes = await c.receivedBytes
        #expect(Array(bytes.prefix(12)) == [0x41, 0x44, 0x44, 0x1F, 0x54, 0xFC, 0x72, 0x6D, 0x20, 0x80, 0x0D, 0x0A])
        // A Cp1252 name in a command reaches the registry decoded.
        try await c.sendRaw([0x54, 0x55, 0x52, 0x4E, 0x1F, 0x54, 0xFC, 0x72, 0x6D, 0x20, 0x80, 0x1F, 0x35, 0x0D, 0x0A])
        #expect(await f.waitForCalls([.turn(name, .heading(5))]))
    }

    @Test func namesWithLineBreaksAreNotSent() async throws {
        let registry = MockRegistry()
        let f = try await HubFixture.make(registry: registry)
        let c = try await f.connectAndWait(expectedCount: 1)
        await registry.emit(.rotorAdded("Evil\r\nCLOSE"))
        await registry.emit(.rotorAdded("Good"))
        try await c.waitForLine { $0 == wire("ADD", "Good") }
        #expect(await c.receivedLines == [wire("ADD", "Good")])
        #expect(f.log.contains("***ERROR***"))
    }

    @Test func droppedConnectionDuringBroadcast() async throws {
        let registry = MockRegistry()
        let f = try await HubFixture.make(registry: registry)
        let a = try await f.connectAndWait(from: "10.0.0.1", expectedCount: 1)
        let b = try await f.connectAndWait(from: "10.0.0.2", expectedCount: 2)
        (a.connection as? MemoryStreamConnection)?.reset()
        for i in 0..<50 { await registry.emit(.reading(RotorReading(name: "R", heading: Double(i), status: .ok))) }
        let lines = try await b.waitForLines(50)
        #expect(lines.last == wire("POINT", "R", "49.0", "0", "0"))
        let hub = f.hub
        #expect(await eventually { await hub.connectionCount == 1 })
        #expect(f.log.contains("Client Disconnected"))
    }
}
