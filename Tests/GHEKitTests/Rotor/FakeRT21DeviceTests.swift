import Testing
@testable import GHEKit

/// Reads chunks until `count` replies have been parsed (or the stream ends).
private func replies(_ it: inout AsyncThrowingStream<[UInt8], any Error>.Iterator, count: Int) async throws -> [RT21Reply] {
    var p = RT21ReplyParser()
    var out: [RT21Reply] = []
    while out.count < count, let chunk = try await it.next() { out += p.push(chunk) }
    return out
}

@Suite struct FakeRT21DeviceTests {
    @Test func answersPollsLikeFirmware() async throws {
        let dev = FakeRT21Device(heading: 358.4, clock: ManualClock())
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("BI2;".utf8))
        try await t.write(Array("AI2;".utf8))
        try await t.write(Array("BI1;".utf8))
        #expect(try await replies(&it, count: 3) == [.heading(358.4, model: 21), .heading(358, model: 20), .heading(358.4, model: 21)])
        #expect(dev.commands == ["BI2", "AI2", "BI1"])
    }

    @Test func exactReplyBytes() async throws {
        let dev = FakeRT21Device(heading: 5, clock: ManualClock())
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("BI2;".utf8))
        #expect(try await it.next() == Array("005.0;".utf8))
        try await t.write(Array("AI1;".utf8))
        #expect(try await it.next() == Array("005;".utf8))
    }

    @Test func gotoTenthsMovesOnClock() async throws {
        let clock = ManualClock()
        var o = FakeRT21Device.Options(); o.degreesPerSecond = 10
        let dev = FakeRT21Device(heading: 0, clock: clock, options: o)
        let t = dev.makeTransport()
        _ = try await t.open()
        try await t.write(RT21Commands.gotoTenths(45))
        #expect(dev.rawCommands == ["AP2045.0\r"])
        #expect(dev.isMoving)
        await clock.advance(by: .seconds(2))
        #expect(abs(dev.heading - 20) < 1e-9)
        await clock.advance(by: .seconds(10))
        #expect(dev.heading == 45)
        #expect(!dev.isMoving)
    }

    @Test func setThenExecuteAndTerminalForms() async throws {
        let clock = ManualClock()
        var o = FakeRT21Device.Options(); o.degreesPerSecond = 100
        let dev = FakeRT21Device(heading: 0, clock: clock, options: o)
        let t = dev.makeTransport()
        _ = try await t.open()
        try await t.write(Array("AP2045;".utf8))
        await clock.advance(by: .seconds(5))
        #expect(dev.heading == 0)   // not executed yet
        try await t.write(Array("AM2;".utf8))
        await clock.advance(by: .seconds(5))
        #expect(dev.heading == 45)
        try await t.write(RT21Commands.gotoWithExecute(90, digit: "1"))
        await clock.advance(by: .seconds(5))
        #expect(dev.heading == 90)
        try await t.write(RT21Commands.gotoTerminal(7.4))
        await clock.advance(by: .seconds(5))
        #expect(dev.heading == 7)
        #expect(dev.commands == ["AP2045", "AM2", "AP1090", "AM1", "AP2007"])
    }

    @Test func jogUntilStop() async throws {
        let clock = ManualClock()
        let dev = FakeRT21Device(heading: 100, clock: clock)   // 6 °/s
        let t = dev.makeTransport()
        _ = try await t.open()
        try await t.write(RT21Commands.jog(cw: true))
        await clock.advance(by: .seconds(5))
        #expect(abs(dev.heading - 130) < 1e-9)
        try await t.write(RT21Commands.stop)
        await clock.advance(by: .seconds(5))
        #expect(abs(dev.heading - 130) < 1e-9)
        try await t.write(RT21Commands.jog(cw: false))
        await clock.advance(by: .seconds(100))
        #expect(dev.heading == 0)   // CCW limit
        #expect(dev.commands == ["AB0", "", "AA0"])
    }

    @Test func silentAndDelayedReplies() async throws {
        let clock = ManualClock()
        var o = FakeRT21Device.Options(); o.replyDelay = .milliseconds(300)
        let dev = FakeRT21Device(heading: 12.3, clock: clock, options: o)
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("BI2;".utf8))
        await clock.settle()
        #expect(clock.sleeperCount == 1)
        await clock.advance(by: .milliseconds(300))
        #expect(try await it.next() == Array("012.3;".utf8))

        dev.options.silent = true
        dev.options.replyDelay = .zero
        try await t.write(Array("BI2;".utf8))
        await t.close()
        #expect(try await it.next() == nil)   // nothing was delivered before close
    }

    @Test func noiseAndSplitRepliesStillParse() async throws {
        var o = FakeRT21Device.Options(); o.injectNoise = true; o.splitReplies = true
        let dev = FakeRT21Device(heading: 358.4, clock: ManualClock(), options: o)
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("BI2;".utf8))
        #expect(try await replies(&it, count: 3) == [.ack, .register(UInt8(ascii: "R"), "1"), .heading(358.4, model: 21)])
    }

    @Test func registerRead() async throws {
        let dev = FakeRT21Device(clock: ManualClock())
        dev.setRegister("T", "256")
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("RT1;".utf8))
        #expect(try await replies(&it, count: 1) == [.register(UInt8(ascii: "T"), "256")])
    }

    @Test func singleConnectionRefusesSecondOpen() async throws {
        let dev = FakeDevices.rt21NetworkModule(heading: 1, clock: ManualClock())
        let a = dev.makeTransport(), b = dev.makeTransport()
        _ = try await a.open()
        await #expect(throws: TransportError.self) { _ = try await b.open() }
        #expect(dev.refusedOpens == 1)
        #expect(!dev.isLockedUntilPowerCycle)
        await a.close()
        _ = try await b.open()
        #expect(dev.openLinkCount == 1)
        await b.close()
    }

    @Test func misuseLocksUntilPowerCycle() async throws {
        let dev = FakeDevices.rt21NetworkModule(heading: 1, clock: ManualClock(), lockOnSecondConnection: true)
        let a = dev.makeTransport(), b = dev.makeTransport()
        let stream = try await a.open()
        await #expect(throws: TransportError.self) { _ = try await b.open() }
        #expect(dev.isLockedUntilPowerCycle)
        try await a.write(Array("BI2;".utf8))   // locked: no reply
        await a.close()
        await #expect(throws: TransportError.self) { _ = try await a.open() }   // still locked after close
        var it = stream.makeAsyncIterator()
        #expect(try await it.next() == nil)

        dev.powerCycle()
        #expect(!dev.isLockedUntilPowerCycle)
        var it2 = try await b.open().makeAsyncIterator()
        try await b.write(Array("BI2;".utf8))
        #expect(try await it2.next() == Array("001.0;".utf8))
    }

    @Test func powerCycleDropsOpenLinkWithLinkLost() async throws {
        let dev = FakeRT21Device(clock: ManualClock())
        let t = dev.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        dev.powerCycle()
        await #expect(throws: TransportError.linkLost) { _ = try await it.next() }
        #expect(dev.openLinkCount == 0)
        await #expect(throws: TransportError.notOpen) { try await t.write([0x3B]) }
    }

    @Test func streamConnectionAdapter() async throws {
        let dev = FakeRT21Device(heading: 45, clock: ManualClock())
        let conn = try await dev.connector().connect(host: "10.0.0.5", port: 6555)
        #expect(conn.peerAddress == "10.0.0.5")
        try await conn.send(Array("AI2;".utf8))
        var it = conn.incoming.makeAsyncIterator()
        #expect(try await it.next() == Array("045;".utf8))
        await conn.close()
    }

    @Test func dcu1Personality() async throws {
        let clock = ManualClock()
        let dcu = FakeDCU1Device(heading: 10, clock: clock, degreesPerSecond: 10)
        let t = dcu.makeTransport()
        var it = try await t.open().makeAsyncIterator()
        try await t.write(Array("BI1;".utf8))      // unsupported: no reply
        try await t.write(Array("AA0;".utf8))      // no jog
        try await t.write(Array("AI1;".utf8))
        #expect(try await it.next() == Array("010;".utf8))
        #expect(!dcu.isMoving)
        try await t.write(RT21Commands.gotoWithExecute(30, digit: "1"))
        await clock.advance(by: .seconds(1))
        #expect(dcu.heading == 20)
        await clock.advance(by: .seconds(5))
        try await t.write(Array("AI1;".utf8))
        #expect(try await it.next() == Array("030;".utf8))
    }

    @Test func memoryTransportFakeLoop() async throws {
        // Lead-owned MemoryTransport driven by a tiny closure device.
        let box = MemoryBox()
        let mt = MemoryTransport(onWrite: { bytes in if bytes == Array("BI2;".utf8) { box.t?.deliver(Array("358.4;".utf8)) } })
        box.t = mt
        var it = try await mt.open().makeAsyncIterator()
        try await mt.write(RT21Commands.pollTenths())
        #expect(try await replies(&it, count: 1) == [.heading(358.4, model: 21)])
        #expect(mt.writes == [Array("BI2;".utf8)])
        mt.fail()
        await #expect(throws: TransportError.linkLost) { _ = try await it.next() }
    }
}

private final class MemoryBox: @unchecked Sendable { var t: MemoryTransport? }
