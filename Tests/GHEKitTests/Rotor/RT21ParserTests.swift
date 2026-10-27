import Testing
@testable import GHEKit

@Suite struct RT21ParserTests {
    private func parse(_ s: String) -> [RT21Reply] {
        var p = RT21ReplyParser()
        return p.push(Array(s.utf8))
    }

    @Test func tenthsHeadingFromRealFirmware() {
        // fw 4.13.1 answered BI2; with 358.4;.
        #expect(parse("358.4;") == [.heading(358.4, model: 21)])
        #expect(parse("123.4;") == [.heading(123.4, model: 21)])
        #expect(parse("000.0;") == [.heading(0, model: 21)])
    }

    @Test func integerHeadingRT20() {
        #expect(parse("045;") == [.heading(45, model: 20)])
        #expect(parse("360;") == [.heading(360, model: 20)])
        #expect(parse("007;") == [.heading(7, model: 20)])
    }

    @Test func toleratesJunkSpacesAndNUL() {
        #expect(parse("\0 358.4;") == [.heading(358.4, model: 21)])
        #expect(parse("\r\n045 ;") == [.heading(45, model: 20)])
        #expect(parse("zz123.4;") == [.heading(123.4, model: 21)])
    }

    @Test func emptyFramesAreSilent() {
        #expect(parse(";;").isEmpty)
        #expect(parse(" ;").isEmpty)
    }

    @Test func badNumbersAreNoiseNotTraps() {
        #expect(parse("1.2.3;") == [.noise(Array("1.2.3".utf8))])
        #expect(parse("abc;") == [.noise(Array("abc".utf8))])
        #expect(parse("45;") == [.noise(Array("45".utf8))])
        #expect(parse(".;") == [.noise(Array(".".utf8))])
        #expect(parse("12345;") == [.noise(Array("12345".utf8))])
    }

    @Test func ackInAnyPositionClearsBuffer() {
        // An ACK frame is cleared wherever the ACK is.
        for frame in ["\u{06};", "\u{06}R;", "\u{06}xyz;", "ab\u{06}cd;"] {
            var p = RT21ReplyParser()
            #expect(p.push(Array(frame.utf8)) == [.ack])
            #expect(p.push(Array("358.4;".utf8)) == [.heading(358.4, model: 21)])
        }
    }

    @Test func registerReply() {
        #expect(parse("R\u{01}12;") == [.register(UInt8(ascii: "R"), "12")])
        #expect(parse("T\u{01}256;") == [.register(UInt8(ascii: "T"), "256")])
        #expect(parse("\u{01}5;") == [.noise([0x01, 0x35])])
        // Buffer is clean afterwards.
        var p = RT21ReplyParser()
        _ = p.push(Array("M\u{01}0;".utf8))
        #expect(p.push(Array("045;".utf8)) == [.heading(45, model: 20)])
    }

    @Test func splitChunksReassemble() {
        var p = RT21ReplyParser()
        #expect(p.push(Array("35".utf8)).isEmpty)
        #expect(p.push(Array("8.".utf8)).isEmpty)
        #expect(p.push(Array("4;04".utf8)) == [.heading(358.4, model: 21)])
        #expect(p.push(Array("5;".utf8)) == [.heading(45, model: 20)])
        var q = RT21ReplyParser()
        var out: [RT21Reply] = []
        for b in Array("\u{06};358.4;R\u{01}1;123;".utf8) { out += q.push([b]) }
        #expect(out == [.ack, .heading(358.4, model: 21), .register(UInt8(ascii: "R"), "1"), .heading(123, model: 20)])
    }

    @Test func manyFramesInOneChunk() {
        #expect(parse("358.4;359.0;001;") == [.heading(358.4, model: 21), .heading(359, model: 21), .heading(1, model: 20)])
    }

    @Test func resetDropsPartialFrame() {
        var p = RT21ReplyParser()
        _ = p.push(Array("12".utf8))
        p.reset()
        #expect(p.push(Array("3.5;".utf8)) == [.heading(3.5, model: 21)])
    }

    @Test func overlongGarbageIsFlushed() {
        var p = RT21ReplyParser()
        let out = p.push([UInt8](repeating: 0x41, count: 300))
        #expect(out.count == 1)
        #expect(p.push(Array("045;".utf8)) == [.heading(45, model: 20)])
    }

    @Test func arbitraryBytesNeverTrap() {
        var g = SystemRandomNumberGenerator()
        var p = RT21ReplyParser()
        for _ in 0..<200 {
            let bytes = (0..<Int.random(in: 0..<40, using: &g)).map { _ in UInt8.random(in: 0...255, using: &g) }
            _ = p.push(bytes)
        }
    }
}
