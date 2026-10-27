import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct WIOSwitchTests {
    static let bank = WioProfile(name: "Bank", displayType: .bank, positions: [
        .init(name: "P1", pins: [1, 0, -1, -1, -1, -1, -1, -1]),
        .init(name: "P2", pins: [-1, 1, -1, -1, -1, -1, -1, -1]),
        .init(name: "P3", pins: [-1, -1, 1, -1, -1, -1, -1, 2]),
    ])

    static let momentary = WioProfile(name: "Mom", displayType: .map, positions: [
        .init(name: "UP", pins: [2, -1, -1, -1, -1, -1, -1, -1]),
        .init(name: "DOWN", pins: [-1, 2, -1, -1, -1, -1, -1, -1]),
    ])

    @Test func bankMaskRule() {
        // All `on` pins of any position → 0, then `on` pins of selected positions → 1; others −1.
        #expect(Self.bank.bankMask(selected: []) == [0, 0, 0, -1, -1, -1, -1, -1])
        #expect(Self.bank.bankMask(selected: ["P1"]) == [1, 0, 0, -1, -1, -1, -1, -1])
        #expect(Self.bank.bankMask(selected: ["P1", "P3"]) == [1, 0, 1, -1, -1, -1, -1, -1])
        #expect(Self.bank.bankMask(selected: ["P2", "P3"]) == [0, 1, 1, -1, -1, -1, -1, -1])
    }

    @Test func profileHelpers() {
        #expect(Self.momentary.isAllMomentary)
        #expect(!Self.bank.isAllMomentary)
        #expect(Self.momentary.momentaryPins == [0, 1])
        #expect(WioProfile.simple().mask(for: "nope") == [0, 0, 0, 0, 0, 0, 0, 0])
        let d = WioProfile.simple().descriptor(deviceName: "Ant Switch")
        #expect(d.name == "Ant Switch" && d.displayType == 1 && d.positions.map(\.name) == ["A", "B", "C", "D", "OFF"])
    }

    @Test func setStateDrivesRelaysAndReportsUpdates() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [7: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let store = InMemorySwitchStateStore()
        let sw = WIOSwitch(name: "Ant Switch", profile: .simple(), remote: await base.physicalRemote(address: 7), persistence: store)
        let updates = StreamTap(await sw.start())
        #expect(sw.currentState == "UNKNOWN")
        await sw.setState("B")
        #expect(sw.currentState == "B")
        #expect(await eventually { fake.relayImage(7) == 0x02 })
        #expect(await eventually { updates.values.last == WIOSwitchUpdate(name: "Ant Switch", state: "B", status: 0, rssi: 0) })
        #expect(await eventually { await store.loadState(forSwitch: "Ant Switch") == "B" })
        await sw.setState("nonexistent")
        #expect(sw.currentState == "B")
        await sw.close()
        #expect(await eventually { updates.isFinished })
    }

    @Test func savedStateRestoresImageWithoutIO() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [7: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 7)
        let sw = WIOSwitch(name: "S", profile: .simple(), remote: remote,
                           persistence: InMemorySwitchStateStore(["S": "C"]))
        _ = await sw.start()
        #expect(sw.currentState == "C")
        #expect(await remote.relayByte == 0x04)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(atFrames(fake, "IO").isEmpty)
        await stepClock(clock, by: .seconds(2))
        #expect(await eventually { fake.relayImage(7) == 0x04 })   // pushed by the refresh
        await sw.close()
    }

    @Test func bankTogglesSelection() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [3: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let store = InMemorySwitchStateStore()
        let sw = WIOSwitch(name: "Bank A", profile: Self.bank, remote: await base.physicalRemote(address: 3), persistence: store)
        _ = await sw.start()
        #expect(sw.currentState == "NONE_SELECTED")
        await sw.setState("P1")
        #expect(sw.currentState == "P1")
        await sw.setState("P3", on: true)
        #expect(sw.currentState == "P1,P3")
        #expect(await eventually { fake.relayImage(3) == 0x05 })
        await sw.setState("P1")            // toggles off
        #expect(sw.currentState == "P3")
        #expect(await eventually { fake.relayImage(3) == 0x04 })
        await sw.setState("P3", on: false)
        #expect(sw.currentState == "NONE_SELECTED")
        await sw.close()
        #expect(await store.loadState(forSwitch: "Bank A") == "NONE_SELECTED")
    }

    @Test func savedBankSelectionIsCleaned() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [3: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 3)
        let sw = WIOSwitch(name: "Bank A", profile: Self.bank, remote: remote,
                           persistence: InMemorySwitchStateStore(["Bank A": "P2,Gone,P3"]))
        _ = await sw.start()
        #expect(sw.currentState == "P2,P3")
        #expect(await remote.relayByte == 0x06)
        await sw.close()
    }

    @Test func allMomentarySwitchReturnsToUnknown() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [4: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let sw = WIOSwitch(name: "Tuner", profile: Self.momentary, remote: await base.physicalRemote(address: 4))
        let updates = StreamTap(await sw.start())
        let t = Task { await sw.setState("UP") }
        #expect(await eventually { updates.values.contains { $0.state == "UP" && $0.status == 0 } })
        await clock.advance(by: .milliseconds(500))
        await t.value
        #expect(await eventually { sw.currentState == "UNKNOWN" })
        #expect(await eventually { updates.values.last?.state == "UNKNOWN" })
        await sw.close()
    }

    @Test func updatesFireOnChangeOrEveryFifthResponse() async throws {
        var gate = UpdateGate(initialStatus: -1)
        let s = RemoteSnapshot(relays: [Bool](repeating: false, count: 8), status: 0, rssi: -40)
        var fired: [Bool] = []
        for _ in 0..<11 { fired.append(gate.accept(s).fire) }
        #expect(fired == [true, false, false, false, false, true, false, false, false, false, true])
        #expect(gate.accept(RemoteSnapshot(relays: s.relays, status: 0, rssi: -41)).fire)
        // The update carries the new values.
        #expect(gate.rssi == -41 && gate.status == 0)
    }

    @Test func virtualSwitchDoesNoIO() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase()
        let base = try await openFakeBase(fake, clock: clock)
        let profile = WioProfile(name: "Presets", virtualSwitch: true, positions: [
            .init(name: "EU", virtualEntries: [.init(target: "Tower", action: "#45")]),
        ])
        let store = InMemorySwitchStateStore()
        let sw = WIOSwitch(name: "V", profile: profile, remote: await base.physicalRemote(address: 0), persistence: store)
        _ = await sw.start()
        await sw.setState("EU")
        #expect(sw.currentState == "EU")
        #expect(await store.loadState(forSwitch: "V") == "EU")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(atFrames(fake, "IO").isEmpty)
        await sw.close()
    }
}
