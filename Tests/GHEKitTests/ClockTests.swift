import Testing
import GHEKit

@Suite struct ManualClockTests {
    @Test func advanceWakesSleepersInOrder() async {
        let clock = ManualClock()
        let log = Log()
        let t1 = Task { try? await clock.sleep(for: .seconds(2)); await log.add(2) }
        let t2 = Task { try? await clock.sleep(for: .seconds(1)); await log.add(1) }
        #expect(await eventually { clock.sleeperCount == 2 })
        await clock.advance(by: .milliseconds(1500))
        #expect(await log.items == [1])
        await clock.advance(by: .seconds(1))
        _ = await (t1.value, t2.value)
        #expect(await log.items == [1, 2])
    }

    @Test func periodicLoopRunsExpectedTimes() async {
        let clock = ManualClock()
        let log = Log()
        let t = Task {
            try? await clock.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await log.add(1)
                do { try await clock.sleep(for: .seconds(1)) } catch { break }
            }
        }
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .seconds(5))
        #expect(await log.items.count == 4)  // at 2,3,4,5 s
        t.cancel()
    }

    @Test func broadcasterFansOut() async {
        let b = EventBroadcaster<Int>()
        let s1 = b.subscribe(), s2 = b.subscribe()
        b.yield(7); b.finish()
        var a: [Int] = [], c: [Int] = []
        for await x in s1 { a.append(x) }
        for await x in s2 { c.append(x) }
        #expect(a == [7] && c == [7])
    }
}

actor Log { var items: [Int] = []; func add(_ i: Int) { items.append(i) } }
