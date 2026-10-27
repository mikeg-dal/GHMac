import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct DemoScenarioTests {
    /// Runs `body` while stepping the manual clock in the background until it finishes.
    private func driving<T: Sendable>(_ clock: ManualClock, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        let stepper = Task {
            while !Task.isCancelled {
                await clock.advance(by: .milliseconds(100))
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { stepper.cancel() }
        return try await task.value
    }

    private func stepUntil(_ clock: ManualClock, limit: Duration = .seconds(30),
                           _ condition: @Sendable () async -> Bool) async -> Bool {
        var elapsed = Duration.zero
        while elapsed < limit {
            if await condition() { return true }
            await clock.advance(by: .milliseconds(100))
            try? await Task.sleep(for: .milliseconds(2))
            elapsed += .milliseconds(100)
        }
        return await condition()
    }

    @Test func panelsCoverEveryDeviceKind() {
        let p = DemoScenario.panels()
        #expect(p.count == DeviceManagerXML.slotCount)
        #expect(p.enumerated().allSatisfy { $0.offset == $0.element.order })
        let types = Set(p.filter { !$0.isEmpty }.compactMap(\.type))
        #expect(types == Set(DeviceType.allCases))
        #expect(p[3].fixedHeading == 999)
        #expect(p[4].cloneOffset == 180)
    }

    @Test func everyDemoDeviceGetsAdded() async throws {
        let clock = ManualClock()
        let scenario = DemoScenario(clock: clock)
        let (registry, _, slots) = scenario.makeRegistry()
        try await driving(clock) { await DemoScenario.connectAll(slots) }
        let ok = await stepUntil(clock) {
            let inv = await registry.inventory()
            return inv.rotors.count == 6 && inv.switches.count == 5 && inv.stacks.count == 1
        }
        let inv = await registry.inventory()
        #expect(ok, "inventory: \(inv.rotors) \(inv.switches.map(\.name)) \(inv.stacks)")
        #expect(Set(inv.rotors) == [DemoScenario.Names.tower1, DemoScenario.Names.tower2, DemoScenario.Names.tower3,
                                    DemoScenario.Names.fixed, DemoScenario.Names.clone, DemoScenario.Names.remoteTower])
        #expect(Set(inv.switches.map(\.name)) == [DemoScenario.Names.antennaSwitch, DemoScenario.Names.bandDecoder,
                                                  DemoScenario.Names.fourSquare, DemoScenario.Names.preamps,
                                                  DemoScenario.Names.beamSelector])
        #expect(inv.stacks == [["Top", "Middle", "Bottom"]])
        #expect(inv.lastReadings[DemoScenario.Names.fixed]?.heading == 999)
        for s in slots.prefix(12) {
            let name = await s.config.name
            #expect(await s.status == .connected, "\(name)")
        }
        for s in slots { await s.disconnect() }
    }

    @Test func turnMovesADemoRotor() async throws {
        let clock = ManualClock()
        let scenario = DemoScenario(clock: clock, degreesPerSecond: 5)
        let (registry, _, slots) = scenario.makeRegistry()
        await slots[0].connect()
        #expect(await stepUntil(clock) { await slots[0].status == .connected })
        await registry.turn(DemoScenario.Names.tower1, .heading(90))
        #expect(await stepUntil(clock, limit: .seconds(5)) { scenario.rotor1.isMoving })
        let reached = await stepUntil(clock, limit: .seconds(20)) {
            abs(scenario.rotor1.heading - 90) < 0.5 && !scenario.rotor1.isMoving
        }
        #expect(reached, "heading \(scenario.rotor1.heading)")
        #expect(await stepUntil(clock) {
            abs((await registry.inventory().lastReadings[DemoScenario.Names.tower1]?.heading ?? 0) - 90) < 0.5
        })
        await slots[0].disconnect()
    }

    @Test func inProcessServerServesTheDemoInventory() async throws {
        let clock = ManualClock()
        let scenario = DemoScenario(clock: clock)
        let server = try await driving(clock) { try await scenario.makeInProcessServer() }
        let client = try await server.connectEmulator()
        let line = try await client.waitForLine(timeout: .seconds(5)) { $0.hasPrefix("ADD") && $0.contains("Tower 1") }
        #expect(line.contains(DemoScenario.Names.tower1))
        await client.disconnect()
        await server.stop()
    }

    @Test func writesLoadableFiles() async throws {
        let dirs = AppDirectories.temporary(prefix: "DemoScenarioTests")
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        try DemoScenario.writeFiles(to: dirs)
        let dm = DeviceManagerXML.load(from: dirs.file(DeviceManagerXML.fileName))
        #expect(dm.panels == DemoScenario.panels())
        let store = WioProfileStore(appDirectories: dirs)
        let issues = await store.reload()
        #expect(issues.isEmpty)
        #expect(await store.profileNames() == DemoProfiles.all.map(\.name).sorted())
        #expect(await store.profile(named: DemoProfiles.bandName) == DemoProfiles.band)
    }
}
