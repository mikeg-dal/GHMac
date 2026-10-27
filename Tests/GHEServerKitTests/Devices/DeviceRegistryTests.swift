import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct DeviceRegistryTests {
    private func nonLog(_ c: StreamTap<RegistryEvent>) -> [RegistryEvent] {
        c.values.filter { if case .log = $0 { false } else { true } }
    }
    private func logs(_ c: StreamTap<RegistryEvent>) -> [String] {
        c.values.compactMap { if case .log(let s) = $0 { s } else { nil } }
    }

    @Test func rotorIsAddedOnFirstReadingThenRemoved() async throws {
        let reg = DeviceRegistry()
        let ev = StreamTap(await reg.subscribe())
        let r = ScriptedRotor(name: "Tower")
        let err = RotorReading(name: "Tower", heading: 0, status: .error)
        await reg.rotorReading(err, from: r)              // even an error reading adds it
        let ok = RotorReading(name: "Tower", heading: 12.5, status: .ok)
        await reg.rotorReading(ok, from: r)
        #expect(await eventually { nonLog(ev).count == 3 })
        #expect(nonLog(ev) == [.rotorAdded("Tower"), .reading(err), .reading(ok)])
        #expect(await eventually { await r.commands == ["query"] })
        let inv = await reg.inventory()
        #expect(inv.rotors == ["Tower"])
        #expect(inv.lastReadings["Tower"] == ok)
        #expect(await reg.isRotorConnected("Tower"))
        #expect(await !reg.isRotorConnected("tower"))
        await reg.removeRotor(r)
        await reg.removeRotor(r)                          // idempotent
        #expect(await eventually { nonLog(ev).last == .rotorRemoved("Tower") })
        #expect(nonLog(ev).filter { $0 == .rotorRemoved("Tower") }.count == 1)
        #expect(await reg.inventory() == RegistryInventory())
    }

    @Test func commandsRouteByExactName() async throws {
        let reg = DeviceRegistry()
        let a = ScriptedRotor(name: "Tower"), b = ScriptedRotor(name: "Tower 2")
        await reg.rotorReading(RotorReading(name: "Tower", heading: 1, status: .ok), from: a)
        await reg.rotorReading(RotorReading(name: "Tower 2", heading: 1, status: .ok), from: b)
        _ = await eventually { let x = await a.commands.count, y = await b.commands.count; return x == 1 && y == 1 }
        await reg.turn("Tower", .heading(90))
        await reg.turn("tower", .heading(10))    // no match
        await reg.stop("Tower 2")
        await reg.query("Tower")
        await reg.turn("Nope", .cw)
        #expect(await a.commands == ["query", "goto 90.0", "query"])
        #expect(await b.commands == ["query", "stop"])
    }

    // MARK: Switches

    private struct Rig {
        let reg: DeviceRegistry
        let fake: FakeWIOBase
        let base: WIOBase
        let clock: ManualClock
    }

    private func rig() async throws -> Rig {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [1: 40, 2: 40, 3: 40, 4: 40])
        let base = try await openFakeBase(fake, clock: clock)
        return Rig(reg: DeviceRegistry(), fake: fake, base: base, clock: clock)
    }

    private func addSwitch(_ r: Rig, _ name: String, _ profile: WioProfile, address: Int,
                           state: String? = nil) async -> WIOSwitch {
        let store = InMemorySwitchStateStore(state.map { [name: $0] } ?? [:])
        let sw = WIOSwitch(name: name, profile: profile, remote: await r.base.physicalRemote(address: address), persistence: store)
        _ = await sw.start()
        await r.reg.registerSwitch(sw)
        await r.reg.switchUpdate(WIOSwitchUpdate(name: name, state: sw.currentState, status: 0, rssi: -40), from: sw)
        return sw
    }

    @Test func switchIsAddedOnlyOnFirstStatusZeroUpdate() async throws {
        let r = try await rig()
        let ev = StreamTap(await r.reg.subscribe())
        let sw = WIOSwitch(name: "Ant", profile: .simple(), remote: await r.base.physicalRemote(address: 1))
        _ = await sw.start()
        await r.reg.registerSwitch(sw)
        await r.reg.switchUpdate(WIOSwitchUpdate(name: "Ant", state: "UNKNOWN", status: 4, rssi: 0), from: sw)
        #expect(await r.reg.setSwitch("Ant", "A", nil) == .unknownSwitch)
        #expect(await r.reg.inventory().switches.isEmpty)
        await r.reg.switchUpdate(WIOSwitchUpdate(name: "Ant", state: "UNKNOWN", status: 0, rssi: -40), from: sw)
        await r.reg.switchUpdate(WIOSwitchUpdate(name: "Ant", state: "UNKNOWN", status: 4, rssi: 0), from: sw)
        #expect(await eventually { nonLog(ev).count == 3 })
        #expect(nonLog(ev) == [
            .switchAdded(sw.descriptor),
            .switchUpdated(name: "Ant", state: "UNKNOWN", status: 0, rssi: -40),
            .switchUpdated(name: "Ant", state: "UNKNOWN", status: 4, rssi: 0),
        ])
        #expect(await r.reg.inventory().switches == [sw.descriptor])
        #expect(await r.reg.setSwitch("Ant", "B", nil) == .ok)
        #expect(await eventually { r.fake.relayImage(1) == 0x02 })
        await r.reg.removeSwitch(sw)
        #expect(await eventually { nonLog(ev).last == .switchRemoved("Ant") })
        await sw.close()
    }

    @Test func matrixLockoutRefusesPositionsHeldByAnyLockedSwitchExceptOFF() async throws {
        let r = try await rig()
        let ev = StreamTap(await r.reg.subscribe())
        let a = await addSwitch(r, "Radio A", .simple("M", lockout: true), address: 1, state: "A")
        let b = await addSwitch(r, "Radio B", .simple("M", lockout: true), address: 2, state: "OFF")
        let free = await addSwitch(r, "Free", .simple("F"), address: 3, state: "A")
        #expect(await r.reg.setSwitch("Radio B", "A", nil) == .lockedOut)     // held by Radio A
        #expect(await r.reg.setSwitch("Radio B", "a", nil) == .lockedOut)     // ignoring case
        #expect(await eventually { logs(ev).contains("SET_SWITCH LOCKOUT a") })
        #expect(await r.reg.setSwitch("Radio A", "A", nil) == .lockedOut)     // its own state counts too
        #expect(await r.reg.setSwitch("Radio A", "OFF", nil) == .ok)          // OFF always allowed, even though B is OFF
        #expect(a.currentState == "OFF")
        #expect(await r.reg.setSwitch("Radio B", "A", nil) == .ok)
        #expect(b.currentState == "A")
        #expect(await r.reg.setSwitch("Free", "A", nil) == .ok)               // unlocked switches are never refused
        #expect(free.currentState == "A")
        // SWITCHLOCKS follows every update of a locked switch, with every locked switch's state.
        await r.reg.switchUpdate(WIOSwitchUpdate(name: "Radio B", state: "A", status: 0, rssi: -40), from: b)
        #expect(await eventually { nonLog(ev).last == .switchLocks(name: "Radio B", states: ["OFF", "A"]) })
        let before = nonLog(ev).count
        await r.reg.switchUpdate(WIOSwitchUpdate(name: "Free", state: "A", status: 0, rssi: -40), from: free)
        #expect(await eventually { nonLog(ev).count == before + 1 })
        #expect(nonLog(ev).last == .switchUpdated(name: "Free", state: "A", status: 0, rssi: -40))
        for s in [a, b, free] { await s.close() }
    }

    @Test func bankRequestsUseTheFourthField() async throws {
        let r = try await rig()
        let bank = await addSwitch(r, "Bank A", WIOSwitchTests.bank, address: 4)
        #expect(await r.reg.setSwitch("Bank A", "P2", true) == .ok)
        #expect(await r.reg.setSwitch("Bank A", "P3", true) == .ok)
        #expect(bank.currentState == "P2,P3")
        #expect(await r.reg.setSwitch("Bank A", "P2", false) == .ok)
        #expect(bank.currentState == "P3")
        await bank.close()
    }

    @Test func virtualSwitchExecutesEntries() async throws {
        let r = try await rig()
        let ev = StreamTap(await r.reg.subscribe())
        let tower = ScriptedRotor(name: "Tower")
        await r.reg.rotorReading(RotorReading(name: "Tower", heading: 0, status: .ok), from: tower)
        let real = await addSwitch(r, "Ant", .simple(), address: 1, state: "A")
        let locked = await addSwitch(r, "Radio A", .simple("M", lockout: true), address: 2, state: "C")
        let lockedB = await addSwitch(r, "Radio B", .simple("M", lockout: true), address: 3, state: "D")
        let profile = WioProfile(name: "Presets", virtualSwitch: true, positions: [
            .init(name: "EU", virtualEntries: [
                .init(target: "Tower", action: "#45.5"),
                .init(target: "Ant", action: "B"),
                .init(target: "Tower", action: "$CAL"),
                .init(target: "Missing", action: "A"),
                .init(target: "Radio A", action: "D"),     // D is held by Radio B → locked
            ]),
            .init(name: "Night", virtualEntries: [.init(target: "Radio A", action: "OFF")]),
        ])
        let v = await addSwitch(r, "V", profile, address: 0)
        #expect(await r.reg.setSwitch("V", "EU", nil) == .ok)
        // "$CAL" doesn't turn the rotor to 000°.
        #expect(await eventually { await tower.commands == ["query", "goto 45.5"] })
        #expect(real.currentState == "B")
        #expect(locked.currentState == "C")
        #expect(v.currentState == "EU")
        _ = await eventually { logs(ev).contains("      SET VIRTUAL Ant To B") && logs(ev).contains("SET_SWITCH LOCKOUT D") }
        let l = logs(ev)
        #expect(l.contains("***ERROR*** Missing Device is Not Connected"))
        #expect(l.contains("SET_SWITCH LOCKOUT D"))
        #expect(l.contains("      SET VIRTUAL Ant To B"))
        #expect(l.contains { $0.contains("$CAL") && $0.contains("ignored") })
        // OFF passes the lockout from a virtual entry too.
        await lockedB.setState("OFF")
        #expect(await r.reg.setSwitch("V", "Night", nil) == .ok)
        #expect(locked.currentState == "OFF")
        for s in [real, locked, lockedB, v] { await s.close() }
    }

    // MARK: Stacks

    @Test func stackAddedOnStatusZeroRoutesCaseInsensitivelyAndForcesUnconnectedOff() async throws {
        let r = try await rig()
        let ev = StreamTap(await r.reg.subscribe())
        let y1 = ScriptedRotor(name: "Yagi1"), y2 = ScriptedRotor(name: "Yagi2")
        await r.reg.rotorReading(RotorReading(name: "Yagi1", heading: 0, status: .ok), from: y1)
        await r.reg.rotorReading(RotorReading(name: "Yagi2", heading: 0, status: .ok), from: y2)
        let remote = await r.base.physicalRemote(address: 2)
        let reg = r.reg
        let st = WIOStackMatch(name: "Yagi1,Yagi2,Yagi3", type: .stackMatchLow, remote: remote,
                               isRotorConnected: { await reg.isRotorConnected($0) })
        _ = await st.start()
        await reg.registerStack(st)
        await reg.setStack("yagi1", false)   // not added yet: ignored
        #expect(await st.antennas == [true, true, true, true])
        await reg.stackUpdate(WIOStackUpdate(names: st.names, selected: [true, true, true, true], status: 0, rssi: -40), from: st)
        #expect(await eventually { nonLog(ev).contains(.stackAdded(["Yagi1", "Yagi2", "Yagi3"])) })
        #expect(await reg.inventory().stacks == [["Yagi1", "Yagi2", "Yagi3"]])
        await reg.setStack("YAGI2", false)
        // Yagi3 isn't a connected rotor → forced off; Yagi2 toggled off; only Yagi1 left → 0x3.
        #expect(await st.antennas == [true, false, false, true])
        #expect(await eventually { r.fake.relayImage(2) == 0x03 })
        await reg.setStack("Yagi1", false)   // zero antennas → reverted
        #expect(await st.antennas == [true, false, false, true])
        await reg.removeStack(st)
        #expect(await eventually { nonLog(ev).last == .stackRemoved(["Yagi1", "Yagi2", "Yagi3"]) })
        await st.close()
    }

    @Test func ok2zawStackInitialisesAllOnWhenAdded() async throws {
        let r = try await rig()
        let remote = await r.base.physicalRemote(address: 3)
        await remote.request(mask: [0, 0, 0, 0, 1, 1, 1, 1])
        let st = WIOStackMatch(name: "A,B,C", type: .ok2zawLow, remote: remote, isRotorConnected: { _ in true })
        _ = await st.start()
        await r.reg.registerStack(st)
        await r.reg.stackUpdate(WIOStackUpdate(names: st.names, selected: [true, true, true, true], status: 0, rssi: 0), from: st)
        #expect(await eventually { r.fake.relayImage(3) == 0xFF })
        await st.close()
    }
}
