import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct PhysicalRemoteTests {
    @Test func validateFrameIsSentFirstAndOpenWaitsThreeSeconds() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase()
        let base = WIOBase(portName: "COM7", transport: fake, clock: clock)
        let done = StreamTap(AsyncStream<Bool> { c in Task { try? await base.open(); c.yield(true); c.finish() } })
        #expect(await eventually { fake.writes.count == 1 })
        #expect(fake.writes.first == XBeeFrame.validate)
        await clock.advance(by: .milliseconds(2900))
        #expect(done.values.isEmpty)
        await clock.advance(by: .milliseconds(100))
        #expect(await eventually { done.values == [true] })
        #expect(await base.isAlive)
    }

    @Test func frameIDSequenceStartsAtTwoAndWraps() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 5)
        for i in 0..<12 { await remote.request(mask: [Int8(i % 2), -1, -1, -1, -1, -1, -1, -1]) }
        #expect(await eventually { atFrames(fake, "IO").count == 12 })
        let ids = atFrames(fake, "IO").map { $0[4] }
        #expect(ids == [2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3])   // id 0 gets no reply
    }

    @Test func requestMaskSemantics() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 5)
        await remote.request(mask: [1, 1, 0, -1, -1, -1, -1, 1])
        #expect(await remote.relayByte == 0x83)
        await remote.request(mask: [-1, 0, 1, -1, -1, -1, -1, -1])   // don't-care keeps bits
        #expect(await remote.relayByte == 0x85)
        #expect(await eventually { fake.relayImage(5) == 0x85 })
        await remote.initialize(mask: [0, -1, -1, 1, 2, -1, -1, -1])  // image only, momentary ignored
        #expect(await remote.relayByte == 0x8C)
        #expect(fake.relayImage(5) == 0x85)
    }

    @Test func momentaryPulseLasts500ms() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 5)
        await remote.request(mask: [-1, -1, -1, 1, -1, -1, -1, -1])
        let sleepers = clock.sleeperCount
        let t = Task { await remote.request(mask: [2, -1, -1, -1, -1, -1, -1, -1]) }
        #expect(await eventually { fake.relayImage(5) == 0x09 })
        #expect(await eventually { clock.sleeperCount > sleepers })
        await clock.advance(by: .milliseconds(499))
        #expect(fake.relayImage(5) == 0x09)
        await clock.advance(by: .milliseconds(1))
        await t.value
        #expect(await eventually { fake.relayImage(5) == 0x08 })
        #expect(atFrames(fake, "IO").map(relayByte(of:)) == [0x08, 0x09, 0x08])
    }

    @Test func requestsDuringAPulseWaitTheirTurn() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 5)
        let a = Task { await remote.request(mask: [2, -1, -1, -1, -1, -1, -1, -1]) }
        #expect(await eventually { atFrames(fake, "IO").count == 1 })
        let b = Task { await remote.request(mask: [-1, 1, -1, -1, -1, -1, -1, -1]) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(atFrames(fake, "IO").count == 1)
        await clock.advance(by: .milliseconds(500))
        await a.value; await b.value
        #expect(await eventually { atFrames(fake, "IO").map(relayByte(of:)) == [0x01, 0x00, 0x02] })
    }

    @Test func localAddressZeroUsesLocalATAndReportsZeroRSSI() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase()
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 0)
        let snaps = StreamTap(remote.snapshots.subscribe())
        await remote.request(mask: [-1, -1, -1, -1, -1, -1, -1, 1])
        #expect(await eventually { fake.relayImage(0) == 0x80 })
        #expect(await eventually { snaps.values.last == RemoteSnapshot(relays: [false, false, false, false, false, false, false, true], status: 0, rssi: 0) })
    }

    @Test func noResponseIsDebouncedPastTen() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase()   // remote 9 doesn't exist → status 4
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 9)
        let snaps = StreamTap(remote.snapshots.subscribe())
        // Frame ids 2…9, 0, 1, 2…: id 0 gets no reply, so 12 requests give 11 no-response replies.
        for _ in 0..<11 { await remote.request(mask: [1, -1, -1, -1, -1, -1, -1, -1]) }
        #expect(await eventually { await remote.status == 4 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(snaps.values.isEmpty)    // 10 status-4 replies: still debounced
        await remote.request(mask: [1, -1, -1, -1, -1, -1, -1, -1])
        #expect(await eventually { snaps.values.count == 1 })
        #expect(snaps.values.first?.status == 4)
    }

    @Test func pollRefreshesEvery800msAndQueriesRSSIEveryFifthCycle() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 0x2A])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 5)
        let snaps = StreamTap(remote.snapshots.subscribe())
        await remote.attach()
        fake.clearWrites()
        await stepClock(clock, by: .milliseconds(1900))
        #expect(atFrames(fake, "IO").isEmpty)        // first refresh after 2 s
        await stepClock(clock, by: .milliseconds(100))
        #expect(await eventually { atFrames(fake, "IO").count == 1 })
        await stepClock(clock, by: .milliseconds(800 * 12))
        let writes = fake.writes
        let kinds: [String] = writes.map { f in f.count > 17 && Array(f[16...17]) == Array("DB".utf8) ? "DB" : "IO" }
        // DB follows the IO of every cycle whose counter is a multiple of 5, once status is 0.
        let dbIndices = kinds.enumerated().filter { $0.element == "DB" }.map(\.offset)
        #expect(dbIndices.count >= 2)
        if dbIndices.count >= 2 {
            #expect(dbIndices[1] - dbIndices[0] == 6)   // 5 IO frames + the DB itself
            let db = writes[dbIndices[0]], io = writes[dbIndices[0] - 1]
            #expect(db[4] == io[4])                    // DB reuses the current frame id
        }
        #expect(await eventually { snaps.values.contains { $0.rssi == -0x2A } })
        await remote.detach()
    }

    @Test func pttRequiresCTSAtOpen() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(cts: false)
        let base = WIOBase(portName: "COM9", transport: fake, clock: clock, basePTT: true)
        await #expect(throws: WIOBaseError.pttNotSupported(port: "COM9")) { try await base.open() }
        #expect(!fake.isOpen)
        #expect(WIOBaseError.pttNotSupported(port: "COM9").localizedDescription
                == "The GH Base unit on COM9 does not support Base PTT Mode")
    }

    @Test func pttDropsFramesWhileCTSLow() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40], cts: true)
        let base = try await openFakeBase(fake, clock: clock, ptt: true)
        let remote = await base.physicalRemote(address: 5)
        fake.setCTS(false)
        await remote.request(mask: [1, -1, -1, -1, -1, -1, -1, -1])
        #expect(await eventually { await base.framesDroppedForPTT == 1 })
        #expect(fake.relayImage(5) == 0)
        fake.setCTS(true)
        await remote.attach()
        await stepClock(clock, by: .seconds(2))     // the refresh resends the full image
        #expect(await eventually { fake.relayImage(5) == 0x01 })
        await remote.detach()
    }

    @Test func linkLossEndsRemoteStreamsAndReportsEvent() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let events = StreamTap(base.events.subscribe())
        let remote = await base.physicalRemote(address: 5)
        let snaps = StreamTap(remote.snapshots.subscribe())
        fake.failLink()
        #expect(await eventually { snaps.isFinished })
        #expect(await eventually { events.values.first.map { if case .linkLost = $0 { true } else { false } } == true })
        #expect(await !base.isAlive)
    }

    @Test func lastDetachClosesTheBase() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40, 6: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let r5 = await base.physicalRemote(address: 5)
        let r6 = await base.physicalRemote(address: 6)
        await r5.attach(); await r6.attach()
        await r5.detach()
        #expect(await base.isAlive)
        await r6.detach()
        #expect(await !base.isAlive)
        #expect(!fake.isOpen)
    }

    @Test func garbageAndCorruptRepliesDoNotBreakRouting() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [200: 40])
        let base = try await openFakeBase(fake, clock: clock)
        let remote = await base.physicalRemote(address: 200)
        let snaps = StreamTap(remote.snapshots.subscribe())
        fake.injectRaw([0x00, 0x7E, 0x00])     // partial junk
        fake.injectRaw([0x13, 0x37])
        fake.corruptNextReplies(1)
        await remote.request(mask: [1, -1, -1, -1, -1, -1, -1, -1])
        fake.setSplitDelivery(true)
        await remote.request(mask: [0, 1, -1, -1, -1, -1, -1, -1])
        #expect(await eventually { snaps.values.count == 1 })
        #expect(snaps.values.first?.status == 0)
        #expect(await base.badFrameCount >= 1)
    }
}
