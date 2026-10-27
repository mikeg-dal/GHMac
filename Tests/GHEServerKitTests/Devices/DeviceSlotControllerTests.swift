import Foundation
import Synchronization
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct DeviceSlotControllerTests {
    private func statuses(_ c: StreamTap<SlotEvent>) -> [SlotStatus] {
        c.values.compactMap { if case .status(let s) = $0 { s } else { nil } }
    }

    private func env(_ resolver: TablePortResolver, _ factory: RecordingTransportFactory, clock: ManualClock,
                     registry: DeviceRegistry = DeviceRegistry(), profiles: [WioProfile] = [],
                     sources: RotorSourceDirectory = RotorSourceDirectory(), pool: WIOBasePool? = nil) -> DeviceEnvironment {
        DeviceEnvironment(registry: registry, portResolver: resolver, transportFactory: factory, clock: clock,
                          profiles: StaticProfileLookup(profiles), basePool: pool ?? WIOBasePool(clock: clock),
                          rotorSources: sources)
    }

    // MARK: Validation

    @Test func rejectsMissingNameAndNAPort() async {
        let clock = ManualClock()
        let e = env(TablePortResolver(), RecordingTransportFactory { _ in MemoryTransport() }, clock: clock)
        let noName = DeviceSlotController(config: DevicePanelConfig(order: 0, port: "COM5"), environment: e)
        await noName.connect()
        #expect(await noName.status == .error("You must supply a name for this device."))
        // N/A is not a port.
        let na = DeviceSlotController(config: DevicePanelConfig(order: 1, name: "Tower"), environment: e)
        await na.connect()
        #expect(await na.status == .error("You must supply a port for this device."))
        #expect(await !na.isRetrying)
        let wio = DeviceSlotController(config: DevicePanelConfig(order: 2, name: "Sw", port: "COM7", deviceType: "GHE Base",
                                                                 wioAddress: 3), environment: e)
        await wio.connect()
        #expect(await wio.status == .error("You must select a WIO subtype."))
        let unknown = DeviceSlotController(config: DevicePanelConfig(order: 3, name: "Sw", port: "COM7", deviceType: "GHE Base",
                                                                     subType: "Nope", wioAddress: 3), environment: e)
        await unknown.connect()
        #expect(await unknown.status == .error("Unknown WIO subtype Nope."))
    }

    @Test func missingSerialPortIsAnErrorNotARetryLoop() async {
        let clock = ManualClock()
        let e = env(TablePortResolver(), RecordingTransportFactory { _ in MemoryTransport() }, clock: clock)
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "/dev/cu.gone"), environment: e)
        await s.connect()
        #expect(await s.status == .error("Port /dev/cu.gone is not available."))
        #expect(await !s.isRetrying)
    }

    // MARK: RT-21

    @Test func rt21ConnectsOnFirstReadingAndDisconnectRemoves() async throws {
        let clock = ManualClock()
        let dev = FakeRT21Device(heading: 358.4, clock: clock)
        let resolver = TablePortResolver(["COM5": .simulated(id: "rt21")])
        let registry = DeviceRegistry()
        let ev = StreamTap(await registry.subscribe())
        let e = env(resolver, RecordingTransportFactory { _ in dev.makeTransport() }, clock: clock, registry: registry)
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "COM5"), environment: e)
        let se = StreamTap(s.events.subscribe())
        await s.connect()
        // The connect query is answered at once.
        #expect(await eventually { await s.status == .connected })
        #expect(statuses(se) == [.connecting, .connected])
        #expect(await eventually { ev.values.contains(.rotorAdded("Tower")) })
        #expect(await registry.inventory().lastReadings["Tower"]?.heading == 358.4)
        await s.disconnect()
        #expect(await s.status == .disconnected)
        #expect(await eventually { ev.values.contains(.rotorRemoved("Tower")) })
        #expect(dev.openLinkCount == 0)
    }

    @Test func serialCablePullRetriesEverySecondOncePortReappears() async throws {
        let clock = ManualClock()
        let dev = FakeRT21Device(heading: 10, clock: clock)
        let links = Mutex<[FakeDeviceTransport]>([])
        let resolver = TablePortResolver(["COM5": .simulated(id: "rt21")])
        let registry = DeviceRegistry()
        let ev = StreamTap(await registry.subscribe())
        let factory = RecordingTransportFactory { _ in
            let l = dev.makeTransport()
            links.withLock { $0.append(l) }
            return l
        }
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "COM5"),
                                     environment: env(resolver, factory, clock: clock, registry: registry))
        let se = StreamTap(s.events.subscribe())
        await s.connect()
        #expect(await eventually { await s.status == .connected })
        resolver.set("COM5", nil)                              // USB adapter unplugged
        links.withLock { $0 }.last?.drop()
        #expect(await eventually { await s.status == .retrying })
        #expect(statuses(se).suffix(2) == [.error("Connection lost"), .retrying])
        #expect(await eventually { ev.values.contains(.rotorRemoved("Tower")) })
        await stepClock(clock, by: .seconds(5))
        #expect(factory.count == 1)                            // port not listed: no attempt
        resolver.set("COM5", .simulated(id: "rt21"))
        await stepClock(clock, by: .seconds(1))
        #expect(await eventually { await s.status == .connected })
        #expect(factory.count == 2)
        #expect(dev.openLinkCount == 1)
        await s.disconnect()
    }

    @Test func tcpRetriesWithBackoffAndNeverOverlaps() async throws {
        let clock = ManualClock()
        let tracker = TrackingTransport.Tracker()
        let resolver = TablePortResolver(["RT21-NET": .tcp(host: "127.0.0.1", port: 6555)])
        let factory = RecordingTransportFactory { _ in TrackingTransport(tracker) }
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "RT21-NET"),
                                     environment: env(resolver, factory, clock: clock))
        tracker.setFailOpens(true)
        await s.connect()
        #expect(await s.status == .retrying)
        #expect(tracker.opens == 1)
        var expectedOpens = 1
        for delay in [5, 10, 20, 40, 60, 60] {
            await stepClock(clock, by: .seconds(delay - 1), tick: .milliseconds(500))
            #expect(tracker.opens == expectedOpens, "before \(delay) s")
            await stepClock(clock, by: .seconds(1), tick: .milliseconds(500))
            expectedOpens += 1
            let want = expectedOpens
            #expect(await eventually { tracker.opens == want }, "after \(delay) s")
        }
        tracker.setFailOpens(false)
        await stepClock(clock, by: .seconds(60), tick: .seconds(1))
        #expect(await eventually { await s.status != .retrying })
        #expect(tracker.maxConcurrent <= 1)
        await s.disconnect()
        let n = tracker.opens
        await stepClock(clock, by: .seconds(120), tick: .seconds(5))
        #expect(tracker.opens == n)
    }

    @Test func tcpLinkLossReconnectsWithoutOverlap() async throws {
        let clock = ManualClock()
        let tracker = TrackingTransport.Tracker()
        let made = Mutex<[TrackingTransport]>([])
        let resolver = TablePortResolver(["RT21-NET": .tcp(host: "127.0.0.1", port: 6555)])
        let factory = RecordingTransportFactory { _ in
            let t = TrackingTransport(tracker)
            made.withLock { $0.append(t) }
            return t
        }
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "RT21-NET"),
                                     environment: env(resolver, factory, clock: clock))
        await s.connect()
        #expect(await s.status == .connecting)
        made.withLock { $0 }.last?.inner.deliver(Array("100.0;".utf8))
        #expect(await eventually { await s.status == .connected })
        made.withLock { $0 }.last?.fail()
        #expect(await eventually { await s.status == .retrying })
        await stepClock(clock, by: .seconds(5), tick: .milliseconds(500))
        #expect(await eventually { tracker.opens == 2 })
        #expect(tracker.maxConcurrent == 1)
        await s.disconnect()
    }

    @Test func disconnectStopsRetrying() async throws {
        let clock = ManualClock()
        let resolver = TablePortResolver(["COM5": .simulated(id: "x")])
        let t = MemoryTransport()
        let factory = RecordingTransportFactory { _ in t }
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "COM5"),
                                     environment: env(resolver, factory, clock: clock))
        await s.connect()
        t.fail()
        #expect(await eventually { await s.status == .retrying })
        await s.disconnect()
        #expect(await s.status == .disconnected)
        await stepClock(clock, by: .seconds(5))
        #expect(factory.count == 1)
    }

    // MARK: Fixed and Cloned

    @Test func fixedPromptsForHeadingThenConnects() async throws {
        let clock = ManualClock()
        let registry = DeviceRegistry()
        let e = env(TablePortResolver(), RecordingTransportFactory { _ in MemoryTransport() }, clock: clock, registry: registry)
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "40m Fixed", deviceType: "Fixed Antenna",
                                                               fixedHeading: DevicePanelConfig.fixedHeadingUnset), environment: e)
        let se = StreamTap(s.events.subscribe())
        await s.connect()
        #expect(await eventually { se.values.contains(.needsFixedHeading(previous: nil)) })
        #expect(await s.status == .disconnected)
        await s.setFixedHeading(999)
        await s.connect()
        await clock.advance(by: .milliseconds(500))
        #expect(await eventually { await s.status == .connected })
        #expect(await registry.inventory().lastReadings["40m Fixed"] == RotorReading(name: "40m Fixed", heading: 999, status: .fixed))
        await s.disconnect()
        #expect(await s.config.fixedHeading == 999)    // kept
    }

    @Test func cloneNeedsOffsetAndSource() async throws {
        let clock = ManualClock()
        let dev = FakeRT21Device(heading: 100, clock: clock)
        let resolver = TablePortResolver(["COM5": .simulated(id: "rt21")])
        let registry = DeviceRegistry()
        let sources = RotorSourceDirectory()
        let e = env(resolver, RecordingTransportFactory { _ in dev.makeTransport() }, clock: clock, registry: registry, sources: sources)
        let clone = DeviceSlotController(config: DevicePanelConfig(order: 1, name: "Tower 15m", port: "COM5",
                                                                   deviceType: "Cloned Antenna", subType: "RT-21"), environment: e)
        let ce = StreamTap(clone.events.subscribe())
        await clone.connect()
        #expect(await eventually { ce.values.contains(.needsCloneOffset(previous: nil)) })
        await clone.setCloneOffset(200)
        await clone.connect()
        #expect(await eventually { ce.values.filter { $0 == .needsCloneOffset(previous: nil) }.count == 2 })
        await clone.setCloneOffset(-30)
        await clone.connect()
        // The missing source is shown, not hidden in a Retrying loop.
        #expect(await clone.status == .error("Port COM5 does not have a rotor connected to it.\n Did you forget to specify an address for a WIO rotor?"))

        let src = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Tower", port: "COM5"), environment: e)
        await src.connect()
        #expect(await eventually { await src.status == .connected })
        await clone.connect()
        await clock.advance(by: .seconds(2))
        #expect(await eventually { await registry.inventory().lastReadings["Tower 15m"] == RotorReading(name: "Tower 15m", heading: 70, status: .clone) })
        await registry.turn("Tower 15m", .heading(0))
        #expect(await eventually { dev.commands.contains("AP2030.0") })
        // The source goes away: the clone loses its link and waits for it to come back.
        await src.disconnect()
        #expect(await eventually { await clone.status == .retrying })
        await src.connect()
        await stepClock(clock, by: .seconds(1))
        #expect(await eventually { [.connected, .connecting].contains(await clone.status) })
        await clone.disconnect(); await src.disconnect()
    }

    // MARK: WIO

    @Test func wioSwitchValidatesThenConnectsOnStatusZero() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [7: 40], clock: clock)
        let resolver = TablePortResolver(["COM7": .simulated(id: "base")])
        let registry = DeviceRegistry()
        let ev = StreamTap(await registry.subscribe())
        let profile = WioProfile.simple("8 Simple")
        let e = env(resolver, RecordingTransportFactory { _ in fake }, clock: clock, registry: registry, profiles: [profile])
        let s = DeviceSlotController(config: DevicePanelConfig(order: 4, name: "Ant Switch", port: "COM7", deviceType: "GHE Base",
                                                               subType: "8 Simple", wioAddress: 7), environment: e)
        let se = StreamTap(s.events.subscribe())
        let t = Task { await s.connect() }
        #expect(await eventually { await s.status == .validating })
        await stepClock(clock, by: .seconds(3))
        await t.value
        await stepClock(clock, by: .seconds(3))      // remote poll: IO refresh after 2 s → status 0
        #expect(await eventually { await s.status == .connected })
        #expect(statuses(se) == [.validating, .connected])
        #expect(ev.values.contains(.switchAdded(profile.descriptor(deviceName: "Ant Switch"))))
        #expect(await registry.setSwitch("Ant Switch", "C", nil) == .ok)
        #expect(await eventually { fake.relayImage(7) == 0x04 })
        // Base cable pull → every device on it retries.
        fake.failLink()
        #expect(await eventually { await s.status == .retrying })
        #expect(await eventually { ev.values.contains(.switchRemoved("Ant Switch")) })
        await s.disconnect()
    }

    @Test func wioRotorAndStackShareOneBase() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [4: 40], rotors: [5: 45], clock: clock)
        let resolver = TablePortResolver(["COM7": .simulated(id: "base")])
        let registry = DeviceRegistry()
        let factory = RecordingTransportFactory { _ in fake }
        let e = env(resolver, factory, clock: clock, registry: registry)
        let rotor = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Yagi1", port: "COM7", deviceType: "GHE Base",
                                                                   subType: "RT-21", wioAddress: 5), environment: e)
        let stack = DeviceSlotController(config: DevicePanelConfig(order: 1, name: "Yagi1, Yagi2", port: "COM7",
                                                                   deviceType: "GHE Base", subType: "Stack Match (1-4)",
                                                                   wioAddress: 4), environment: e)
        let t1 = Task { await rotor.connect() }
        let t2 = Task { await stack.connect() }
        await stepClock(clock, by: .seconds(3))
        await t1.value; await t2.value
        #expect(factory.count == 1)              // one Base per port
        #expect(fake.openCount == 1)
        await stepClock(clock, by: .seconds(3))
        #expect(await eventually { let a = await rotor.status, b = await stack.status; return a == .connected && b == .connected })
        #expect(await registry.inventory().stacks == [["Yagi1", "Yagi2"]])
        await rotor.disconnect()
        #expect(fake.isOpen)                     // the stack still uses the Base
        await stack.disconnect()
        #expect(await eventually { !fake.isOpen })
    }

    @Test func virtualSwitchNeedsAKnownProfileAndUsesAddressZero() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(clock: clock)
        let resolver = TablePortResolver(["COM7": .simulated(id: "base")])
        let profile = WioProfile(name: "Presets", virtualSwitch: true, positions: [.init(name: "EU")])
        let e = env(resolver, RecordingTransportFactory { _ in fake }, clock: clock, profiles: [profile])
        let bad = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "V", port: "COM7", deviceType: "Virtual Switch",
                                                                 subType: "Gone", wioAddress: 9), environment: e)
        await bad.connect()
        #expect(await bad.status == .error("Unknown WIO subtype Gone."))
        let v = DeviceSlotController(config: DevicePanelConfig(order: 1, name: "V", port: "COM7", deviceType: "Virtual Switch",
                                                               subType: "Presets", wioAddress: 9), environment: e)
        let t = Task { await v.connect() }
        await stepClock(clock, by: .seconds(3))
        await t.value
        await stepClock(clock, by: .seconds(3))
        #expect(await eventually { await v.status == .connected })
        #expect(atFrames(fake, "IO").allSatisfy { $0[3] == XBeeAPI.localAT })   // address 0 = local I/O
        await v.disconnect()
    }

    @Test func pttWithoutCTSIsAnError() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [7: 40], cts: false, clock: clock)
        let resolver = TablePortResolver(["COM7": .simulated(id: "base")])
        let e = env(resolver, RecordingTransportFactory { _ in fake }, clock: clock, profiles: [.simple("8 Simple")])
        let s = DeviceSlotController(config: DevicePanelConfig(order: 0, name: "Sw", port: "COM7", deviceType: "GHE Base",
                                                               subType: "8 Simple", wioAddress: 7, basePTT: true), environment: e)
        await s.connect()
        #expect(await s.status == .error("The GH Base unit on COM7 does not support Base PTT Mode"))
        #expect(await !s.isRetrying)
    }
}
