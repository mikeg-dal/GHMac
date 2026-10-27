import Foundation
import Testing
import GHEKit
import GHESimKit
@testable import GHEClientKit

@MainActor
@Suite("ConnectionManager inventory and routing")
struct ConnectionManagerTests {
    let a = ServerID(host: "10.0.0.1", port: 17220)
    let b = ServerID(host: "10.0.0.2", port: 17220)

    /// A manager with `servers` connected through fake connections.
    func connected(_ servers: [ServerID]) async -> (ConnectionManager, FakeConnectionFactory) {
        let f = FakeConnectionFactory()
        let m = ConnectionManager(environment: f.environment(clock: ManualClock()), rows: max(servers.count, 1))
        for (i, s) in servers.enumerated() {
            m.supervisors[i].config = ServerRowConfig(address: s.host, port: String(s.port))
            await m.supervisors[i].connect()
        }
        _ = await eventually { @MainActor in m.supervisors.prefix(servers.count).allSatisfy { $0.state == .connected } }
        return (m, f)
    }

    func feed(_ m: ConnectionManager, _ server: ServerID, _ lines: [String]) {
        for l in lines { m.apply(GHWire.decodeServerLine(l), from: server) }
    }

    // MARK: Examples

    @Test func everySpecExampleDecodesIntoModels() {
        let m = ConnectionManager(environment: FakeConnectionFactory().environment(clock: ManualClock()), rows: 1)
        feed(m, a, [
            wire("ADD", "Tower 40m"),
            wire("ADD", "Wio Yagi"),
            wire("ADD", "Yagi Top"), wire("ADD", "Yagi Mid"), wire("ADD", "Yagi Bot"),
            wire("POINT", "Tower 40m", "271.0", "0", "0"),
            wire("POINT", "Wio Yagi", "45.3", "0", "-71"),
            wire("STACKADD", "Yagi Top,Yagi Mid,Yagi Bot"),
            wire("STACK", "Yagi Top,Yagi Mid,Yagi Bot", "true", "false", "true", "false", "0", "-64"),
            wire("SWITCHADD", "2", "6-Pack", "North\(gs)0\(gs)60\(gs)false", "Omni\(gs)0\(gs)360\(gs)false"),
            wire("SWITCHADD", "3", "Band SW", "40m\(gs)7.0\(gs)7.3", "20m\(gs)14.0\(gs)14.35"),
            wire("SWITCHUPDATE", "Band SW", "20m", "0", "-58"),
            wire("SWITCHLOCKS", "Band SW", "20m", "40m"),
            "",
        ])
        #expect(m.rotors.map(\.name) == ["Tower 40m", "Wio Yagi", "Yagi Bot", "Yagi Mid", "Yagi Top"])
        let tower = m.rotor(ItemKey(server: a, name: "Tower 40m"))!
        #expect(tower.heading == 271.0 && tower.status == .ok && tower.rssi == 0)
        let wio = m.rotor(ItemKey(server: a, name: "Wio Yagi"))!
        #expect(wio.heading == 45.3 && wio.rssi == -71)
        #expect(m.stacks.map(\.name) == ["Yagi Bot", "Yagi Mid", "Yagi Top"])
        #expect(m.rotor(ItemKey(server: a, name: "Yagi Top"))!.stackSelected == true)
        #expect(m.rotor(ItemKey(server: a, name: "Yagi Mid"))!.stackSelected == false)
        #expect(m.rotor(ItemKey(server: a, name: "Yagi Bot"))!.stackSelected == true)
        #expect(m.rotor(ItemKey(server: a, name: "Yagi Bot"))!.stackRSSI == -64)
        #expect(m.stack(ItemKey(server: a, name: "Yagi Bot"))!.selected)
        #expect(tower.stackSelected == nil)
        let map = m.switchItem(ItemKey(server: a, name: "6-Pack"))!
        #expect(map.displayType == .map)
        #expect(map.descriptor.positions[1] == SwitchPosition(name: "Omni", heading: 0, beamwidth: 360))
        let band = m.switchItem(ItemKey(server: a, name: "Band SW"))!
        #expect(band.displayType == .band)
        #expect(band.descriptor.positions[1].upperMHz == 14.35)
        #expect(band.selectedPosition == "20m" && band.status == 0 && band.rssi == -58)
        #expect(band.locks == ["20m", "40m"])
        #expect(band.isLocked("40m") && !band.isLocked("off"))
        #expect(m.presetNames[a] == [])
        #expect(m.rssiEntries().map(\.line).contains("Wio Yagi  -71dBm   [ROTOR]"))
        #expect(m.rssiEntries(showAll: true).count == 5 + 2 + 3)

        feed(m, a, [wire("REMOVE", "Tower 40m"), wire("SWITCHREMOVE", "6-Pack"), wire("STACKREMOVE", "Yagi Top,Yagi Mid,Yagi Bot")])
        #expect(m.rotor(ItemKey(server: a, name: "Tower 40m")) == nil)
        #expect(m.switches.map(\.name) == ["Band SW"])
        #expect(m.stacks.isEmpty)
        #expect(m.rotor(ItemKey(server: a, name: "Yagi Top"))!.stackSelected == nil)
    }

    @Test func pointWithoutStatusDefaultsToStoppedAndBadLinesAreIgnored() {
        let m = ConnectionManager(environment: FakeConnectionFactory().environment(clock: ManualClock()), rows: 1)
        feed(m, a, [wire("ADD", "R:1"), wire("POINT", "R:1", "12.0"), wire("POINT", "R:1", "abc", "0", "0")])
        let r = m.rotor(ItemKey(server: a, name: "R:1"))!   // ':' in a name still routes
        #expect(r.heading == 12.0)
        #expect(r.status == .stopped)
    }

    @Test(arguments: [(1, SwitchDisplayType.buttons), (2, .map), (3, .band), (4, .bank), (9, .buttons)])
    func switchAddTypes(_ type: Int, _ expected: SwitchDisplayType) {
        let m = ConnectionManager(environment: FakeConnectionFactory().environment(clock: ManualClock()), rows: 1)
        let pos = type == 3 ? "A\(gs)1.8\(gs)2.0" : "A\(gs)90\(gs)30\(gs)true"
        feed(m, a, [wire("SWITCHADD", String(type), "SW", pos, type == 3 ? "B\(gs)3.5\(gs)4.0" : "B\(gs)270\(gs)30\(gs)false")])
        let s = m.switchItem(ItemKey(server: a, name: "SW"))!
        #expect(s.displayType == expected)
        #expect(s.descriptor.displayType == type)
        #expect(s.positionNames == ["A", "B"])
        #expect(s.status == -1 && s.state == nil)
        if type == 3 { #expect(s.descriptor.positions[0].lowerMHz == 1.8) }
        if type == 2 { #expect(s.descriptor.positions[0].heading == 90 && s.descriptor.positions[0].bidirectional) }
    }

    @Test func switchUpdateBankListNoneSelectedAndUnknown() {
        let m = ConnectionManager(environment: FakeConnectionFactory().environment(clock: ManualClock()), rows: 1)
        feed(m, a, [
            wire("SWITCHADD", "4", "Bank A", "Amp\(gs)0\(gs)0\(gs)false", "Preamp\(gs)0\(gs)0\(gs)false", "PTT\(gs)0\(gs)0\(gs)false"),
            wire("SWITCHADD", "1", "Ant", "Yagi\(gs)0\(gs)0\(gs)false", "Dipole\(gs)0\(gs)0\(gs)false"),
            wire("SWITCHUPDATE", "Bank A", "Amp,PTT", "0", "0"),
            wire("SWITCHUPDATE", "Ant", "Dipole", "0", "-80"),
        ])
        let bank = m.switchItem(ItemKey(server: a, name: "Bank A"))!
        let ant = m.switchItem(ItemKey(server: a, name: "Ant"))!
        #expect(bank.selected == ["Amp", "PTT"])
        #expect(ant.selectedPosition == "Dipole" && ant.rssi == -80)
        feed(m, a, [wire("SWITCHUPDATE", "Bank A", "NONE_SELECTED", "0", "0"),
                    wire("SWITCHUPDATE", "Ant", "UNKNOWN", "4", "0")])
        #expect(bank.selected.isEmpty)
        #expect(ant.selectedPosition == nil && ant.isUnknown && ant.status == 4)
        feed(m, a, [wire("SWITCHLOCKS", "Ant", "Yagi"), wire("SWITCHLOCKS", "Ant")])
        #expect(ant.locks == [])
        feed(m, a, [wire("SWITCHLOCKS", "Ant", "Yagi", "OFF")])
        #expect(ant.isLocked("Yagi") && !ant.isLocked("OFF") && !ant.isLocked("Dipole"))
    }

    @Test func tornadoMessagesParseForParity() {
        let m = ConnectionManager(environment: FakeConnectionFactory().environment(clock: ManualClock()), rows: 1)
        feed(m, a, [wire("TORNADOADD", "Tuner", "R1\(gs)R2", "P1\(gs)P2", "7.0\(gs)14.0", "7.3\(gs)14.35"),
                    wire("TORNADO", "Tuner", "0", "-60", "P2", "90", "270")])
        let t = m.tornado(ItemKey(server: a, name: "Tuner"))!
        #expect(t.descriptor.rotors == ["R1", "R2"])
        #expect(t.state?.position == "P2" && t.state?.headings == ["90", "270"])
        feed(m, a, [wire("TORNADOREMOVE", "Tuner")])
        #expect(m.tornados.isEmpty)
    }

    // MARK: Routing

    @Test func gangedTurnsAndStops() async throws {
        let (m, f) = await connected([a, b])
        feed(m, a, [wire("ADD", "R1"), wire("ADD", "R2")])
        feed(m, b, [wire("ADD", "R3")])
        let r1 = m.rotor(ItemKey(server: a, name: "R1"))!
        let r2 = m.rotor(ItemKey(server: a, name: "R2"))!
        let r3 = m.rotor(ItemKey(server: b, name: "R3"))!
        r1.isActive = true; r3.isActive = true
        let ca = f.latest(a)!.sent, cb = f.latest(b)!.sent

        m.turn(r1, to: .heading(90))
        #expect(ca.all == [.turn(rotor: "R1", .heading(90))])
        #expect(cb.all == [.turn(rotor: "R3", .heading(90))])

        ca.clear(); cb.clear()
        m.turn(r2, to: .cw)   // not active: only itself
        #expect(ca.all == [.turn(rotor: "R2", .cw)])
        #expect(cb.all.isEmpty)

        ca.clear()
        m.stop(r3)
        #expect(ca.all == [.stop(rotor: "R1")])
        #expect(cb.all == [.stop(rotor: "R3")])

        // Visibility hook: R3 hidden → not ganged; a hidden active rotor commanded alone.
        ca.clear(); cb.clear()
        m.isVisible = { $0.name != "R3" }
        m.turn(r1, to: .heading(10))
        #expect(ca.all == [.turn(rotor: "R1", .heading(10))])
        #expect(cb.all.isEmpty)
        m.turn(r3, to: .heading(20))
        #expect(cb.all == [.turn(rotor: "R3", .heading(20))])
        #expect(ca.all.count == 1)
    }

    @Test func activeCommandsGoOnlyToOwners() async throws {
        let (m, f) = await connected([a, b])
        feed(m, a, [wire("ADD", "R1")])
        feed(m, b, [wire("ADD", "R3"), wire("ADD", "R4")])
        m.rotor(ItemKey(server: a, name: "R1"))!.isActive = true
        m.rotor(ItemKey(server: b, name: "R3"))!.isActive = true
        m.turnActive(raw: "123")
        m.stopActive()
        #expect(f.latest(a)!.sent.all == [.turn(rotor: "R1", .raw("123")), .stop(rotor: "R1")])
        #expect(f.latest(b)!.sent.all == [.turn(rotor: "R3", .raw("123")), .stop(rotor: "R3")])
    }

    @Test func switchStackAndTornadoCommandsRouteToTheOwningServer() async throws {
        let (m, f) = await connected([a, b])
        feed(m, a, [wire("SWITCHADD", "4", "Bank A", "Amp\(gs)0\(gs)0\(gs)false"), wire("ADD", "Yagi")])
        feed(m, b, [wire("SWITCHADD", "4", "Bank A", "Amp\(gs)0\(gs)0\(gs)false"),
                    wire("TORNADOADD", "Tuner", "R1", "P1", "7.0", "7.3")])
        m.setSwitch(m.switchItem(ItemKey(server: b, name: "Bank A"))!, position: "Amp", on: true)
        m.setStack(ItemKey(server: a, name: "Yagi"), selected: true)
        let t = m.tornado(ItemKey(server: b, name: "Tuner"))!
        m.setTornado(t, position: "P1"); m.tornadoTurn(t, rotor: "R1", cw: false); m.tornadoCalibrate(t, rotor: "R1")
        #expect(f.latest(a)!.sent.all == [.setStack(antenna: "Yagi", selected: true)])
        #expect(f.latest(b)!.sent.all == [.setSwitch(name: "Bank A", position: "Amp", on: true),
                                          .setTornado(tuner: "Tuner", position: "P1"),
                                          .tornadoTurn(tuner: "Tuner", rotor: "R1", cw: false),
                                          .tornadoCal(tuner: "Tuner", rotor: "R1")])
    }

    @Test func sameNameOnSamePortOfTwoHostsStaysSeparate() async throws {
        let (m, f) = await connected([a, b])
        feed(m, a, [wire("ADD", "Tower"), wire("SWITCHADD", "1", "Ant", "Yagi\(gs)0\(gs)0\(gs)false")])
        feed(m, b, [wire("ADD", "Tower"), wire("SWITCHADD", "1", "Ant", "Yagi\(gs)0\(gs)0\(gs)false")])
        #expect(m.rotors.count == 2)
        #expect(m.switches.count == 2)
        feed(m, b, [wire("POINT", "Tower", "200.0", "0", "0")])
        #expect(m.rotor(ItemKey(server: a, name: "Tower"))!.heading == nil)
        #expect(m.rotor(ItemKey(server: b, name: "Tower"))!.heading == 200)
        // Both keep the same file key.
        #expect(m.rotors.allSatisfy { $0.key.legacyKey == "Tower\u{1E}:17220" })
        m.turn(m.rotor(ItemKey(server: a, name: "Tower"))!, to: .heading(5))
        #expect(f.latest(a)!.sent.all == [.turn(rotor: "Tower", .heading(5))])
        #expect(f.latest(b)!.sent.all.isEmpty)
    }

    @Test func lossGreysOnlyThatServerAndUserDisconnectRemovesIt() async throws {
        let (m, f) = await connected([a, b])
        feed(m, a, [wire("ADD", "R1"), wire("SWITCHADD", "1", "SW", "X\(gs)0\(gs)0\(gs)false"), wire("STACKADD", "R1")])
        feed(m, b, [wire("ADD", "R2"), wire("SWITCHADD", "1", "SW", "X\(gs)0\(gs)0\(gs)false")])
        m.rotor(ItemKey(server: a, name: "R1"))!.isActive = true
        await f.latest(a)!.push(.lost("EOF"))
        #expect(await eventually { @MainActor in m.supervisors[0].state == .retrying })
        #expect(m.rotor(ItemKey(server: a, name: "R1"))!.isConnected == false)
        #expect(m.rotor(ItemKey(server: a, name: "R1"))!.canTurn == false)
        #expect(m.rotor(ItemKey(server: b, name: "R2"))!.isConnected)
        #expect(m.switches.map(\.key.server) == [b])
        #expect(m.stack(ItemKey(server: a, name: "R1"))!.isConnected == false)
        // Commands to a down server are dropped.
        #expect(!m.send(.stop(rotor: "R1"), to: a))

        // Reconnect: inventory comes back; the active flag survives.
        await m.supervisors[0].disconnect()
        #expect(m.rotors.map(\.key.server) == [b])
        #expect(m.stacks.isEmpty)
        await m.supervisors[0].connect()
        #expect(await eventually { @MainActor in m.supervisors[0].state == .connected })
        await f.latest(a)!.push(line: wire("ADD", "R1"))
        #expect(await eventually { @MainActor in m.rotor(ItemKey(server: a, name: "R1")) != nil })
        #expect(m.rotor(ItemKey(server: a, name: "R1"))!.isActive)
        #expect(m.rotor(ItemKey(server: a, name: "R1"))!.isConnected)
    }

    @Test func gangedTurnsOnTheWireAreSeparateChunks() async throws {
        let emu = JavaServerEmulator(inventory: [wire("ADD", "R1"), wire("ADD", "R2"), wire("ADD", "R3")])
        let clock = ManualClock()
        let env = ConnectionEnvironment(clock: clock, resolve: { $0 }) { req in
            GHServerConnection(id: req.id, user: req.user, passwordHash: req.passwordHash, connector: emu.connector(), clock: clock)
        }
        let m = ConnectionManager(environment: env, rows: 1)
        m.supervisors[0].config = ServerRowConfig(address: "127.0.0.1", port: "17220")
        await m.supervisors[0].connect()
        #expect(await eventually { @MainActor in m.rotors.count == 3 })
        for r in m.rotors { r.isActive = true }
        m.turn(m.rotors[0], to: .heading(271.5))
        #expect(await eventually { emu.current?.commands.count == 3 })
        let s = try #require(emu.current)
        #expect(s.violations.isEmpty)
        #expect(s.chunks.count == 3)
        #expect(Set(s.commands) == [wire("TURN", "R1", "271.5"), wire("TURN", "R2", "271.5"), wire("TURN", "R3", "271.5")])
        await m.disconnectAll()
        #expect(await eventually { s.sawQuit && s.sawEOF })
    }
}
