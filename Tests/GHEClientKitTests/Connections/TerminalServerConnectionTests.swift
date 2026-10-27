import Foundation
import Testing
import GHEKit
@testable import GHEClientKit

@Suite("TerminalServerConnection (direct RT-21) against FakeRT21Device")
struct TerminalServerConnectionTests {
    let id = ServerID(host: "192.0.2.10", port: 6555)   // TEST-NET address; only the fake is ever used

    func make(_ device: FakeRT21Device, clock: ManualClock, leases: EndpointLeases,
              name: String? = nil, poll: TerminalServerConnection.PollCommand = .integer) -> TerminalServerConnection {
        TerminalServerConnection(id: id, rotorName: name, poll: poll,
                                 makeTransport: { _, _ in device.makeTransport() },
                                 leases: leases, clock: clock)
    }

    func singleConnectionDevice(_ clock: ManualClock, heading: Double = 45) -> FakeRT21Device {
        var o = FakeRT21Device.Options()
        o.singleConnection = true
        o.lockOnSecondConnection = true
        return FakeRT21Device(heading: heading, clock: clock, options: o)
    }

    @Test func announcesOneRotorNamedIpPortByDefault() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock)
        let conn = make(device, clock: clock, leases: EndpointLeases())
        let log = EventLog()
        log.start(try await conn.connect())
        #expect(await eventually { log.all.count == 2 })
        #expect(log.all == [.connected, .message(.add("192.0.2.10:6555"))])
        await conn.disconnect()
    }

    @Test func tvT1AndT2PollEverySecondAndReportHeading() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock, heading: 45)
        let conn = make(device, clock: clock, leases: EndpointLeases(), name: "Tower")
        let log = EventLog()
        log.start(try await conn.connect())
        await clock.advance(by: .milliseconds(999))
        #expect(device.rawCommands.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { device.rawCommands == ["AI2"] })
        // `045;` → POINT␟Tower␟45.0␟0 (status 0, RSSI 0).
        #expect(await eventually { log.messages.contains(.point(rotor: "Tower", heading: 45, status: .ok, rssi: 0)) })
        await clock.advance(by: .seconds(1))
        #expect(await eventually { device.rawCommands == ["AI2", "AI2"] })
        await conn.disconnect()
    }

    @Test func tvT3TurnAndTvT4Stop() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock)
        let conn = make(device, clock: clock, leases: EndpointLeases())
        let log = EventLog()
        log.start(try await conn.connect())
        conn.enqueue(.turn(rotor: "x", .heading(6.6)))
        #expect(await eventually { device.rawCommands == ["AP2007\r"] })   // rounded, zero-padded
        conn.enqueue(.turn(rotor: "x", .cw))
        conn.enqueue(.turn(rotor: "x", .ccw))
        conn.enqueue(.turn(rotor: "x", .raw("CW")))
        conn.enqueue(.stop(rotor: "x"))
        #expect(await eventually { device.rawCommands == ["AP2007\r", ""] })   // `;`; CW/CCW sent nothing
        conn.enqueue(.turn(rotor: "x", .raw("123.6")))
        #expect(await eventually { device.rawCommands.last == "AP2124\r" })
        await conn.disconnect()
    }

    @Test func tvT5TenthsReplyParsesWhole() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock, heading: 358.4)
        let conn = make(device, clock: clock, leases: EndpointLeases(), name: "RT21", poll: .tenths)
        let log = EventLog()
        log.start(try await conn.connect())
        await clock.advance(by: .seconds(1))
        #expect(await eventually { device.rawCommands == ["BI2"] })
        // The real unit answered `BI2;` with `358.4;`.
        #expect(await eventually { log.messages.contains(.point(rotor: "RT21", heading: 358.4, status: .ok, rssi: 0)) })
        device.setHeading(123.4)
        await clock.advance(by: .seconds(1))
        #expect(await eventually { log.messages.contains(.point(rotor: "RT21", heading: 123.4, status: .ok, rssi: 0)) })
        await conn.disconnect()
    }

    @Test func linkDropIsLost() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock)
        let leases = EndpointLeases()
        let conn = make(device, clock: clock, leases: leases)
        let log = EventLog()
        log.start(try await conn.connect())
        device.powerCycle()
        // The drop ends the connection at once and frees the lease.
        #expect(await eventually { log.lost && log.hasEnded })
        #expect(await eventually { leases.heldKeys.isEmpty })
    }

    @Test func secondConnectionToTheSameEndpointIsRefusedLocally() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock)
        let leases = EndpointLeases()
        let first = make(device, clock: clock, leases: leases)
        _ = try await first.connect()
        let second = make(device, clock: clock, leases: leases)
        await #expect(throws: TransportError.self) { _ = try await second.connect() }
        // Refused before touching the device: the module never saw a second connection.
        #expect(device.refusedOpens == 0)
        #expect(device.openLinkCount == 1)
        #expect(!device.isLockedUntilPowerCycle)
        await first.disconnect()
        #expect(leases.heldKeys.isEmpty)
        let third = make(device, clock: clock, leases: leases)
        _ = try await third.connect()
        #expect(device.openLinkCount == 1)
        await third.disconnect()
    }

    @Test func managerDrivesATerminalServerRow() async throws {
        let clock = ManualClock()
        let device = singleConnectionDevice(clock, heading: 90)
        let leases = EndpointLeases()
        let env = ConnectionEnvironment(clock: clock, resolve: { $0 }) { req in
            TerminalServerConnection(id: req.id, rotorName: req.rotorName, poll: req.terminalPoll,
                                     makeTransport: { _, _ in device.makeTransport() }, leases: leases, clock: clock)
        }
        let m = await ConnectionManager(environment: env, rows: 2)
        await MainActor.run {
            m.supervisors[0].config = ServerRowConfig(address: "192.0.2.10", port: "6555", kind: .terminalServerTCP,
                                                      rotorName: "Tower")
        }
        await m.supervisors[0].connect()
        #expect(await eventually { @MainActor in m.rotors.first?.name == "Tower" })
        await clock.advance(by: .seconds(1))
        #expect(await eventually { @MainActor in m.rotors.first?.heading == 90 })
        let tower = await MainActor.run { m.rotors[0] }
        await m.turn(tower, to: .heading(180))
        #expect(await eventually { device.rawCommands.contains("AP2180\r") })
        await m.supervisors[0].disconnect()
        #expect(leases.heldKeys.isEmpty)
    }
}
