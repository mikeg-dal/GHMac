import Foundation
import Testing
import GHEKit
@testable import GHEServerKit
import GHESimKit

@Suite struct WIORotorTests {
    private func tx16Payloads(_ fake: FakeWIOBase, to address: Int) -> [String] {
        fake.writes.filter { $0[3] == XBeeAPI.tx16 && $0[6] == UInt8(address) }
            .map { String(decoding: $0[8..<($0.count - 1)], as: UTF8.self) }
    }

    @Test func pollsEvery800msAndReportsHeadingWithRSSI() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 0x2D], rotors: [5: 358.4], clock: clock)
        let base = try await openFakeBase(fake, clock: clock)
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        let readings = StreamTap(try await rotor.start())
        #expect(await eventually { tx16Payloads(fake, to: 5) == ["BI2;"] })   // first poll immediately
        #expect(await eventually { readings.values.first == RotorReading(name: "Tower", heading: 358.4, status: .ok, rssi: -0x2D) })
        await stepClock(clock, by: .milliseconds(1600))
        #expect(await eventually { tx16Payloads(fake, to: 5).count == 3 })
        // TX16 frame ids count 0,1,2…
        let ids = fake.writes.filter { $0[3] == XBeeAPI.tx16 }.map { $0[4] }
        #expect(ids == [0, 1, 2])
        await rotor.close()
    }

    @Test func gotoAndStopAreSentThreeTimesWithoutBlocking() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(rotors: [5: 0], clock: clock)
        let base = try await openFakeBase(fake, clock: clock)
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        _ = try await rotor.start()
        _ = await eventually { tx16Payloads(fake, to: 5).count == 1 }
        await rotor.goTo(.heading(45))         // returns at once
        #expect(await eventually { tx16Payloads(fake, to: 5).filter { $0.hasPrefix("AP2") } == ["AP2045.0\r;"] })
        await clock.advance(by: .milliseconds(500))
        await clock.advance(by: .milliseconds(500))
        #expect(await eventually { tx16Payloads(fake, to: 5).filter { $0.hasPrefix("AP2") }.count == 3 })
        await rotor.stop()
        await clock.advance(by: .milliseconds(500))
        await clock.advance(by: .milliseconds(500))
        #expect(await eventually { tx16Payloads(fake, to: 5).filter { $0 == ";" }.count == 3 })
        await rotor.goTo(.cw)
        await rotor.goTo(.ccw)
        #expect(await eventually { tx16Payloads(fake, to: 5).suffix(2) == ["AB0;", "AA0;"] })
        await rotor.close()
    }

    @Test func errorAfterMoreThanFiveMissedCycles() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(rotors: [5: 120], clock: clock)
        let base = try await openFakeBase(fake, clock: clock)
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        let readings = StreamTap(try await rotor.start())
        #expect(await eventually { readings.values.count == 1 })
        fake.setSilent(true)
        // Cycle 0.8 s still sees cycle 0's reply (counter 0); 1.6…4.8 s count 1…5; 5.6 s is the 6th miss.
        await stepClock(clock, by: .milliseconds(4800))
        #expect(!readings.values.contains { $0.status == .error })
        await stepClock(clock, by: .milliseconds(800))
        #expect(await eventually { readings.values.last == RotorReading(name: "Tower", heading: 120, status: .error, rssi: 0) })
        await rotor.close()
    }

    @Test func closeStopsPolling() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [6: 40], rotors: [5: 0], clock: clock)
        let base = try await openFakeBase(fake, clock: clock)
        let keepAlive = await base.physicalRemote(address: 6)
        await keepAlive.attach()      // keeps the Base open after the rotor goes
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        let readings = StreamTap(try await rotor.start())
        _ = await eventually { tx16Payloads(fake, to: 5).count == 1 }
        await rotor.close()
        #expect(await eventually { readings.isFinished })
        let n = tx16Payloads(fake, to: 5).count
        await stepClock(clock, by: .seconds(3))
        #expect(tx16Payloads(fake, to: 5).count == n)
        await keepAlive.detach()
    }

    @Test func eachRadioPacketIsParsedOnItsOwn() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(remotes: [5: 40], clock: clock)   // no RT-21: we inject packets
        let base = try await openFakeBase(fake, clock: clock)
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        let readings = StreamTap(try await rotor.start())
        fake.injectRaw(XBeeFrame.encode([0x81, 0x10, 5, 0x30, 0] + Array("045.5".utf8)))   // no ';' still parses
        fake.injectRaw(XBeeFrame.encode([0x81, 0x10, 5, 0x30, 0] + Array("12".utf8)))      // fragment: ignored
        fake.injectRaw(XBeeFrame.encode([0x81, 0x10, 5, 0x31, 0] + Array("3.4;".utf8)))
        #expect(await eventually { readings.values.count == 2 })
        #expect(readings.values.map(\.heading) == [45.5, 3.4])
        #expect(readings.values.map(\.rssi) == [-0x30, -0x31])
        await rotor.close()
    }

    @Test func baseLinkLossEndsTheRotorStream() async throws {
        let clock = ManualClock()
        let fake = FakeWIOBase(rotors: [5: 0], clock: clock)
        let base = try await openFakeBase(fake, clock: clock)
        let rotor = WIORotor(name: "Tower", remote: await base.physicalRemote(address: 5), clock: clock)
        let readings = StreamTap(try await rotor.start())
        fake.failLink()
        #expect(await eventually { readings.isFinished })
    }
}
