import Testing
import Foundation
import Synchronization
import GHEKit
@testable import GHEClientKit

final class StickyFakeModemPort: ModemControl {
    let lines = Mutex(ModemLines(cts: true, dsr: false))
    let reads = Mutex(0)
    func modemLines() async throws -> ModemLines {
        reads.withLock { $0 += 1 }
        return lines.withLock { $0 }
    }
    func set(cts: Bool? = nil, dsr: Bool? = nil) {
        lines.withLock { l in
            if let cts { l.cts = cts }
            if let dsr { l.dsr = dsr }
        }
    }
}

@Suite struct ModemLineTests {
    @Test func edges() {
        var e = ModemLineEdges()
        #expect(e.update(ModemLines(cts: false, dsr: true)) == [])   // baseline only
        #expect(e.update(ModemLines(cts: true, dsr: true)) == [.pttLock(false)])
        #expect(e.update(ModemLines(cts: false, dsr: true)) == [.pttLock(true), .jumpToSticky])
        #expect(e.update(ModemLines(cts: false, dsr: false)) == [])
        #expect(e.update(ModemLines(cts: false, dsr: true)) == [.jumpToSticky])
        #expect(e.update(ModemLines(cts: false, dsr: true, dcd: true)) == [])
    }

    @Test func pollsEvery20msOnManualClock() async {
        let clock = ManualClock()
        let port = StickyFakeModemPort()
        let m = ModemLineMonitor(port: port, clock: clock)
        let sink = AutomationEventSink(await m.start())
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(port.reads.withLock { $0 } == 1)
        port.set(cts: false)
        await clock.advance(by: .milliseconds(19))
        #expect(port.reads.withLock { $0 } == 1)
        await clock.advance(by: .milliseconds(1))
        #expect(await eventually { sink.events == [.pttLock(true), .jumpToSticky] })
        port.set(cts: true, dsr: true)
        await clock.advance(by: .milliseconds(20))
        #expect(await eventually { sink.events.count == 4 })
        #expect(Array(sink.events.suffix(2)) == [.pttLock(false), .jumpToSticky])
        await m.stop()
    }
}
