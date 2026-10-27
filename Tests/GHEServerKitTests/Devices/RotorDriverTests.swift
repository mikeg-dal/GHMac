import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

@Suite struct RT21DriverTests {
    @Test func pollsFirstAtTwoSecondsThenEverySecond() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        _ = try await d.start()
        await clock.advance(by: .milliseconds(1999))
        #expect(t.writes.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { asciiWrites(t.writes) == ["BI2;"] })
        await clock.advance(by: .seconds(1))
        await clock.advance(by: .seconds(1))
        #expect(await eventually { asciiWrites(t.writes) == ["BI2;", "BI2;", "BI2;"] })
        await d.close()
        await clock.advance(by: .seconds(3))
        #expect(t.writes.count == 3)
    }

    @Test func addressDigitIsConfigurable() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock, addressDigit: "1")
        _ = try await d.start()
        await d.query()
        await d.goTo(.heading(45))
        #expect(asciiWrites(t.writes) == ["BI1;", "AP1045;AM1;"])
        await d.close()
    }

    @Test func errorStatusAfterMoreThanFiveUnansweredPolls() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        // Polls at 2,3,4,5,6 s: five unanswered, no error yet.
        await clock.advance(by: .seconds(6))
        #expect(await eventually { t.writes.count == 5 })
        try? await Task.sleep(for: .milliseconds(10))
        #expect(readings.values.isEmpty)
        await clock.advance(by: .seconds(1))   // 6th poll → error
        #expect(await eventually { readings.values == [RotorReading(name: "Tower", heading: 0, status: .error)] })
        await clock.advance(by: .seconds(1))   // repeats every poll
        #expect(await eventually { readings.values.count == 2 })
        await d.close()
    }

    @Test func headingResetsCounterAndErrorRepeatsWithLastHeading() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        t.deliver(Array("123.4;".utf8))
        #expect(await eventually { readings.values == [RotorReading(name: "Tower", heading: 123.4, status: .ok)] })
        await clock.advance(by: .seconds(7))   // polls at 2…7: six unanswered
        #expect(await eventually { readings.values.last == RotorReading(name: "Tower", heading: 123.4, status: .error) })
        await d.close()
    }

    @Test func rt20RepliesAlsoResetTheCounter() async throws {
        // The counter is reset on RT-20 replies.
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        for _ in 0..<10 {
            await clock.advance(by: .seconds(1))
            t.deliver(Array("123;".utf8))
            _ = await eventually { readings.values.last?.heading == 123 }
        }
        #expect(readings.values.allSatisfy { $0.status == .ok })
        #expect(await d.model == 20)
        await d.close()
    }

    @Test func gotoFormatDependsOnDetectedModelAndJogNeedsRT21() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        await d.goTo(.heading(45))
        await d.goTo(.cw)          // dropped: model unknown
        await d.goTo(.ccw)
        await d.stop()
        #expect(asciiWrites(t.writes) == ["AP2045;AM2;", ";"])
        t.deliver(Array("358.4;".utf8))
        #expect(await eventually { readings.values.count == 1 })
        t.clearWrites()
        await d.goTo(.heading(45.25))
        await d.goTo(.cw)
        await d.goTo(.ccw)
        await d.goTo(.raw("271,5"))
        await d.goTo(.raw("CW"))
        await d.goTo(.raw("bogus"))
        #expect(asciiWrites(t.writes) == ["AP2045.2\r;", "AB0;", "AA0;", "AP2271.5\r;", "AB0;"])
        await d.close()
    }

    @Test func worksAgainstFakeRT21() async throws {
        let clock = ManualClock()
        let dev = FakeRT21Device(heading: 358.4, clock: clock)
        let d = RT21Driver(name: "Tower", transport: dev.makeTransport(), clock: clock)
        let readings = StreamTap(try await d.start())
        await clock.advance(by: .seconds(2))
        #expect(await eventually { readings.values.first == RotorReading(name: "Tower", heading: 358.4, status: .ok) })
        await d.goTo(.heading(10))
        #expect(await eventually { dev.commands.contains("AP2010.0") })
        await d.close()
    }

    @Test func linkLossEndsTheStream() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = RT21Driver(name: "Tower", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        t.fail()
        #expect(await eventually { readings.isFinished })
        await clock.advance(by: .seconds(3))
        #expect(t.writes.isEmpty)
    }

    @Test func dcu1CommandSet() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = DCU1Driver(name: "Ham IV", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        await clock.advance(by: .seconds(2))
        #expect(await eventually { asciiWrites(t.writes) == ["AI1;"] })
        t.deliver(Array("090;".utf8))
        #expect(await eventually { readings.values.first == RotorReading(name: "Ham IV", heading: 90, status: .ok) })
        t.clearWrites()
        await d.goTo(.heading(7.5))
        await d.goTo(.cw)
        await d.stop()
        #expect(asciiWrites(t.writes) == ["AP1008;AM1;", ";"])
        await d.close()
    }

    @Test func dcu1ReportsErrorWhenSilent() async throws {
        let clock = ManualClock()
        let t = MemoryTransport()
        let d = DCU1Driver(name: "Ham IV", transport: t, clock: clock)
        let readings = StreamTap(try await d.start())
        await clock.advance(by: .seconds(7))
        #expect(await eventually { readings.values.first?.status == .error })
        await d.close()
    }
}

@Suite struct FixedAndClonedTests {
    @Test func fixedReportsStatus7Every2sAndPassesAnyValue() async throws {
        let clock = ManualClock()
        let f = FixedRotor(name: "40m Fixed", heading: 999, clock: clock)
        let readings = StreamTap(try await f.start())
        await clock.advance(by: .milliseconds(499))
        #expect(readings.values.isEmpty)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { readings.values == [RotorReading(name: "40m Fixed", heading: 999, status: .fixed)] })
        await clock.advance(by: .seconds(2))
        #expect(await eventually { readings.values.count == 2 })
        await f.goTo(.heading(10)); await f.stop()
        await f.query()   // '7', not '0'
        #expect(await eventually { readings.values.count == 3 })
        #expect(readings.values.allSatisfy { $0.status == .fixed && $0.heading == 999 })
        await f.close()
        #expect(await eventually { readings.isFinished })
    }

    @Test func cloneOffsetsReadingsAndMasksErrors() async throws {
        let src = ScriptedRotor(name: "Tower")
        let fan = EventBroadcaster<RotorReading>()
        let c = ClonedRotor(name: "Tower 15m", offset: -30, source: src, sourceReadings: fan.subscribe())
        let readings = StreamTap(try await c.start())
        fan.yield(RotorReading(name: "Tower", heading: 10, status: .ok))
        fan.yield(RotorReading(name: "Tower", heading: 200, status: .error))   // masked
        fan.yield(RotorReading(name: "Tower", heading: 350, status: .ok, rssi: -40))
        #expect(await eventually { readings.values.count == 3 })
        #expect(readings.values == [
            RotorReading(name: "Tower 15m", heading: 340, status: .clone),
            RotorReading(name: "Tower 15m", heading: 170, status: .clone),
            RotorReading(name: "Tower 15m", heading: 320, status: .clone),
        ])
    }

    @Test func cloneForwardsCommandsWithOffset() async throws {
        let src = ScriptedRotor(name: "Tower")
        let fan = EventBroadcaster<RotorReading>()
        let c = ClonedRotor(name: "Tower 15m", offset: 30, source: src, sourceReadings: fan.subscribe())
        _ = try await c.start()
        await c.goTo(.heading(10))      // 10 − 30 → 340
        await c.goTo(.heading(200))
        await c.goTo(.cw)
        await c.goTo(.ccw)
        await c.stop()
        await c.query()
        #expect(await src.commands == ["goto 340.0", "goto 170.0", "cw", "ccw", "stop", "query"])
    }

    @Test func cloneUnsubscribesOnCloseAndEndsWithSource() async throws {
        let src = ScriptedRotor(name: "Tower")
        let fan = EventBroadcaster<RotorReading>()
        let c = ClonedRotor(name: "C", offset: 0, source: src, sourceReadings: fan.subscribe())
        let r = StreamTap(try await c.start())
        #expect(fan.subscriberCount == 1)
        await c.close()
        #expect(await eventually { fan.subscriberCount == 0 })
        #expect(await eventually { r.isFinished })

        let c2 = ClonedRotor(name: "C2", offset: 0, source: src, sourceReadings: fan.subscribe())
        let r2 = StreamTap(try await c2.start())
        fan.finish()                                              // source went away
        #expect(await eventually { r2.isFinished })
    }

    @Test func normalisation() {
        #expect(normalizedHeading(-30) == 330)
        #expect(normalizedHeading(360) == 0)
        #expect(normalizedHeading(725) == 5)
        #expect(normalizedHeading(.nan) == 0)
    }
}
