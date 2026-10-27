import Foundation
import Testing
@testable import GHEKit

@Suite struct ClientLineDecoderTests {
    @Test func acceptsAllThreeTerminators() {
        var d = ClientLineDecoder()
        #expect(d.push(Array("A\nB\r\nC\rD".utf8)) == ["A", "B", "C"])
        #expect(d.push(Array("\n".utf8)) == ["D"])
    }

    @Test func crAtChunkEndFollowedByLFInNextChunk() {
        var d = ClientLineDecoder()
        #expect(d.push(Array("ADD\u{1F}X\r".utf8)) == ["ADD\u{1F}X"])
        #expect(d.push(Array("\nREMOVE\u{1F}X\r".utf8)) == ["REMOVE\u{1F}X"])
        #expect(d.push(Array("\n".utf8)) == [])
        #expect(d.push(Array("\n".utf8)) == [""], "a second LF is a real empty line")
    }

    @Test func emptyLinesAndPartialLines() {
        var d = ClientLineDecoder()
        #expect(d.push([0x0D, 0x0A]) == [""])
        #expect(d.push(Array("POI".utf8)) == [])
        #expect(d.push(Array("NT\r\n".utf8)) == ["POINT"])
        #expect(d.push([]) == [])
    }

    @Test func decodesWindows1252() {
        var d = ClientLineDecoder()
        #expect(d.push([0x41, 0x80, 0xE9, 0x0D, 0x0A]) == ["A€é"])
    }

    @Test func byteAtATimeMatchesWholeChunk() {
        let bytes = GHWire.encode(.add("A")) + GHWire.encode(.close) + Array("X\rY\n".utf8)
        var whole = ClientLineDecoder(), single = ClientLineDecoder()
        let a = whole.push(bytes)
        let b = bytes.flatMap { single.push([$0]) }
        #expect(a == b)
        #expect(a == ["ADD\u{1F}A", "CLOSE", "X", "Y"])
    }
}

@Suite struct ServerInputAssemblerTests {
    let digest: [UInt8] = [0x00, 0x0A, 0x0D, 0x41] + (4..<31).map { UInt8($0 * 7 & 0xFF) } + [0x0A]

    @Test func javaClientLoginSequence() {
        var a = ServerInputAssembler(authenticate: true)
        #expect(a.phase == .awaitingUser)
        #expect(a.push(Array("alice\r\n".utf8)) == [.userName("alice")])
        #expect(a.phase == .awaitingDigest)
        a.expectDigest()
        #expect(digest.count == 32)
        #expect(a.push(digest) == [.digest(digest)])
        #expect(a.phase == .awaitingDigest)
        a.markAuthenticated()
        #expect(a.push(wire("TURN␟R␟90.0␍␊")) == [.line("TURN\u{1F}R\u{1F}90.0")])
    }

    @Test func digestContainingNulCrLfIsTakenRaw() {
        var a = ServerInputAssembler(authenticate: true)
        _ = a.push(Array("bob\r\n".utf8))
        a.expectDigest()
        let events = a.push(digest)
        #expect(events == [.digest(digest)])
    }

    @Test func digestSplitAcrossPushes() {
        var a = ServerInputAssembler(authenticate: true)
        _ = a.push(Array("bob\r\n".utf8))
        a.expectDigest()
        #expect(a.push(Array(digest[0..<1])) == [])
        #expect(a.push(Array(digest[1..<20])) == [])
        #expect(a.push(Array(digest[20...])) == [.digest(digest)])
    }

    @Test func userAndDigestCoalescedInOnePush() {
        var a = ServerInputAssembler(authenticate: true)
        #expect(a.push(Array("alice\r\n".utf8) + digest) == [.userName("alice"), .digest(digest)])
        a.expectDigest() // hub calls this after sending PASS:; must not reset anything
        #expect(a.push([]) == [])
    }

    @Test func commandsAfterDigestAreHeldUntilAuthenticated() {
        var a = ServerInputAssembler(authenticate: true)
        _ = a.push(Array("alice\r\n".utf8))
        #expect(a.push(digest + wire("STOP␟R␍␊")) == [.digest(digest)])
        #expect(a.push(Array(digest.prefix(32))) == [], "no second digest")
        a.markAuthenticated()
        let lines = a.push([])
        #expect(lines.first == .line("STOP\u{1F}R"))
    }

    @Test func nulBytesBeforeUserAndEmptyUserLinesAreSkipped() {
        var a = ServerInputAssembler(authenticate: true)
        #expect(a.push([0, 0]) == [])
        #expect(a.push(Array("\r\n  \r\n".utf8)) == [])
        #expect(a.push([0] + Array(" carol \r\n".utf8)) == [.userName("carol")])
    }

    @Test func nulPingsBetweenCommands() {
        // A NUL that lands in front of a command no longer corrupts it.
        var a = ServerInputAssembler(authenticate: false)
        #expect(a.push([0]) == [])
        #expect(a.push(wire("STOP␟A␍␊") + [0] + wire("STOP␟B␍␊") + [0]) == [.line("STOP\u{1F}A"), .line("STOP\u{1F}B")])
        #expect(a.push([0, 0, 0]) == [])
    }

    @Test func multipleCommandsInOnePushAndSplitAcrossPushes() {
        var a = ServerInputAssembler(authenticate: false)
        let bytes = wire("TURN␟A␟1.0␍␊SET_SWITCH␟S␟20m␍␊STOP␟A␍␊")
        #expect(a.push(Array(bytes[0..<10])) == [])
        #expect(a.push(Array(bytes[10...])) == [.line("TURN\u{1F}A\u{1F}1.0"), .line("SET_SWITCH\u{1F}S\u{1F}20m"), .line("STOP\u{1F}A")])
    }

    @Test func carriageReturnSeparatedRepeatsSurviveFraming() {
        var a = ServerInputAssembler(authenticate: false)
        let events = a.push(wire("TURN␟A␟10␍TURN␟B␟20␍␊"))
        #expect(events == [.line("TURN\u{1F}A\u{1F}10\rTURN\u{1F}B\u{1F}20")])
        guard case .line(let l) = events.first else { return }
        #expect(GHWire.decodeClientLine(l) == [.turn(rotor: "A", .heading(10)), .turn(rotor: "B", .heading(20))])
    }

    @Test func trailingCarriageReturnIsStripped() {
        // "R\r" in a non-final LOCK line is stripped.
        var a = ServerInputAssembler(authenticate: false)
        #expect(a.push(wire("LOCK␟R␍␊GETHEAD R␍␊")) == [.line("LOCK\u{1F}R"), .line("GETHEAD R")])
        #expect(a.push(Array("QUIT\n".utf8)) == [.line("QUIT")])
    }

    @Test func oversizedUnterminatedInputIsDropped() {
        var a = ServerInputAssembler(authenticate: false)
        _ = a.push([UInt8](repeating: 0x41, count: ServerInputAssembler.maxBuffered + 1))
        #expect(a.push(Array("STOP\u{1F}R\n".utf8)) == [.line("STOP\u{1F}R")])
    }
}
