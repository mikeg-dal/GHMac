import Foundation
import Testing
import GHEKit
import GHESimKit
@testable import GHEClientKit

@MainActor
@Suite("ConnectionSupervisor (Servers dialog row)")
struct ConnectionSupervisorTests {
    let a = ServerID(host: "10.0.0.1", port: 17220)

    func row(_ factory: FakeConnectionFactory, clock: ManualClock, config: ServerRowConfig,
             resolve: (@Sendable (String) async -> String?)? = nil) -> ConnectionSupervisor {
        ConnectionSupervisor(id: 0, config: config, environment: factory.environment(clock: clock, resolve: resolve))
    }

    @Test(arguments: ["abc", "", "0", "70000", " 17220"])
    func invalidPort(_ port: String) async {
        let f = FakeConnectionFactory()
        let s = row(f, clock: ManualClock(), config: ServerRowConfig(address: "10.0.0.1", port: port))
        await s.connect()
        #expect(s.state == .disconnected)
        #expect(s.message == "Invalid TCP port")
        #expect(f.total == 0)
    }

    @Test func missingAddress() async {
        let f = FakeConnectionFactory()
        let s = row(f, clock: ManualClock(), config: ServerRowConfig(address: "  ", port: "17220"))
        await s.connect()
        #expect(s.message == "No IP Address")
        #expect(s.state == .disconnected)
    }

    @Test func spaceInPassword() async {
        let f = FakeConnectionFactory()
        let s = row(f, clock: ManualClock(), config: ServerRowConfig(address: "10.0.0.1", port: "17220",
                                                                      user: "alice", password: "a b"))
        await s.connect()
        #expect(s.message == "No spaces in password")
        #expect(f.total == 0)
    }

    @Test func unknownHostStops() async {
        let f = FakeConnectionFactory()
        let s = row(f, clock: ManualClock(), config: ServerRowConfig(address: "nowhere.invalid", port: "17220"),
                    resolve: { _ in nil })
        await s.connect()
        // No connection attempt after "Unknown host".
        #expect(s.message == "Unknown host")
        #expect(s.state == .disconnected)
        #expect(f.total == 0)
    }

    @Test func alreadyConnected() async {
        let f = FakeConnectionFactory()
        let m = ConnectionManager(environment: f.environment(clock: ManualClock()), rows: 2)
        m.supervisors[0].config = ServerRowConfig(address: "10.0.0.1", port: "17220")
        m.supervisors[1].config = ServerRowConfig(address: "10.0.0.1", port: "17220")
        await m.supervisors[0].connect()
        #expect(await eventually { @MainActor in m.supervisors[0].state == .connected })
        await m.supervisors[1].connect()
        #expect(m.supervisors[1].message == "Already Connected")
        #expect(m.supervisors[1].state == .disconnected)
    }

    @Test func passwordHashNotPasswordIsUsed() async {
        let f = FakeConnectionFactory()
        let saved = GHAuth.passwordHash(user: "alice", password: "secret1")
        let m = ConnectionManager(environment: f.environment(clock: ManualClock()), rows: 1)
        m.passwordHashLookup = { $0 == "alice" ? saved : nil }
        var stored: [UInt8]?
        m.didComputePasswordHash = { h, _ in stored = h }
        m.supervisors[0].config = ServerRowConfig(address: "10.0.0.1", port: "17220", user: "alice")
        await m.supervisors[0].connect()
        #expect(f.latest(a)?.request.passwordHash == saved)
        #expect(stored == saved)
        await m.supervisors[0].disconnect()
        m.supervisors[0].config.password = "other22"
        await m.supervisors[0].connect()
        #expect(f.latest(a)?.request.passwordHash == GHAuth.passwordHash(user: "alice", password: "other22"))
    }

    @Test func invalidCredentialsNeverRetry() async throws {
        let clock = ManualClock()
        let f = FakeConnectionFactory()
        let s = row(f, clock: clock, config: ServerRowConfig(address: "10.0.0.1", port: "17220", user: "alice"))
        await s.connect()
        #expect(await eventually { @MainActor in s.state == .connected })
        await f.latest(a)?.push(.invalidCredentials)
        #expect(await eventually { @MainActor in s.state == .disconnected })
        #expect(s.message == "Invalid user/pass")
        await clock.advance(by: .seconds(60))
        #expect(f.count(a) == 1)
    }

    @Test func closeRetriesAfter15Seconds() async throws {
        let clock = ManualClock()
        let f = FakeConnectionFactory()
        let s = row(f, clock: clock, config: ServerRowConfig(address: "10.0.0.1", port: "17220"))
        await s.connect()
        #expect(await eventually { @MainActor in s.state == .connected })
        await f.latest(a)?.push(.closedByServer)
        #expect(await eventually { @MainActor in s.state == .retrying })
        await clock.advance(by: .seconds(14))
        #expect(f.count(a) == 1)
        await clock.advance(by: .seconds(1))
        #expect(await eventually { @MainActor in s.state == .connected })
        #expect(f.count(a) == 2)
    }

    @Test func failedConnectKeepsRetryingEvery15Seconds() async throws {
        let clock = ManualClock()
        let f = FakeConnectionFactory()
        f.setFailing(a, true)
        let s = row(f, clock: clock, config: ServerRowConfig(address: "10.0.0.1", port: "17220"))
        await s.connect()
        #expect(await eventually { @MainActor in s.state == .retrying })
        await clock.advance(by: .seconds(15))
        #expect(await eventually { f.count(a) == 2 })
        #expect(await eventually { @MainActor in s.state == .retrying })
        f.setFailing(a, false)
        await clock.advance(by: .seconds(15))
        #expect(await eventually { @MainActor in s.state == .connected })
        #expect(f.count(a) == 3)
    }

    @Test func userDisconnectWhileRetryingStopsRetries() async throws {
        let clock = ManualClock()
        let f = FakeConnectionFactory()
        let s = row(f, clock: clock, config: ServerRowConfig(address: "10.0.0.1", port: "17220"))
        await s.connect()
        #expect(await eventually { @MainActor in s.state == .connected })
        await f.latest(a)?.push(.lost("EOF"))
        #expect(await eventually { @MainActor in s.state == .retrying })
        await s.toggleNow()
        #expect(s.state == .disconnected)
        await clock.advance(by: .seconds(60))
        #expect(f.count(a) == 1)
    }

    @Test func userDisconnectClosesTheConnection() async throws {
        let f = FakeConnectionFactory()
        let s = row(f, clock: ManualClock(), config: ServerRowConfig(address: "10.0.0.1", port: "17220"))
        await s.toggleNow()
        #expect(await eventually { @MainActor in s.state == .connected })
        await s.toggleNow()
        #expect(s.state == .disconnected)
        #expect(await f.latest(a)?.disconnected == true)
        #expect(s.serverID == nil)
    }

    @Test func endToEndRetryAgainstTheEmulator() async throws {
        let clock = ManualClock()
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1"), "CLOSE"])
        let env = ConnectionEnvironment(clock: clock, resolve: { $0 }) { req in
            GHServerConnection(id: req.id, user: req.user, passwordHash: req.passwordHash,
                               connector: emu.connector(), clock: clock)
        }
        let m = ConnectionManager(environment: env, rows: 1)
        m.supervisors[0].config = ServerRowConfig(address: "127.0.0.1", port: "17220")
        await m.supervisors[0].connect()
        #expect(await eventually { @MainActor in m.supervisors[0].state == .retrying })
        #expect(m.rotors.map(\.name) == ["R1"])
        #expect(m.rotors[0].isConnected == false)
        await clock.advance(by: .seconds(15))
        #expect(await eventually { emu.sessions.count == 2 })
        await m.supervisors[0].disconnect()
    }
}
