import Testing
import Foundation
import GHEKit
@testable import GHEClientKit

@Suite struct WinTestVectorTests {
    static let w1Hex = "534554415a494d5554483a202253544e312220222220323730ef00"

    func packet(_ text: String) -> [UInt8] {
        let b = Array(text.utf8)
        return b + [WinTestPacket.checksum(of: b), 0]
    }

    @Test func checksumRule() {
        let w1 = automationBytes(hex: Self.w1Hex)
        #expect(w1 == packet(#"SETAZIMUTH: "STN1" "" 270"#))
        #expect(WinTestPacket.checksum(of: Array(#"STATUS: "STN1" "" 0 1 1 0 140250 0 "CW" 0 "CW" 70250"#.utf8)) == 0xD4)
        #expect(WinTestPacket.checksum(of: Array(#"STATUS: "STN1" "" 0 1 1 1 140250 0 "CW" 0 "CW" 70250"#.utf8)) == 0xD5)
        let p = WinTestPacket(bytes: w1)
        #expect(p?.checksumValid == true)
        #expect(p?.verb == "SETAZIMUTH")
        #expect(p?.station == "STN1")
    }

    @Test func tvW1() {
        let ev = WinTestParser.events(for: automationBytes(hex: Self.w1Hex), filter: WinTestFilter())
        #expect(ev.withoutRaw == [.status("Rotor: 270"), .turnActive(raw: "270")])
    }

    @Test func tvW2StationFilter() {
        let ev = WinTestParser.events(for: automationBytes(hex: Self.w1Hex),
                                      filter: WinTestFilter(stationFilterEnabled: true, stationName: "STN2"))
        #expect(ev.withoutRaw == [.status(#"Station name does not match "STN2""#)])
    }

    /// Filter text ignored while the checkbox is off.
    @Test func filterOnlyWhenEnabled() {
        let ev = WinTestParser.events(for: automationBytes(hex: Self.w1Hex),
                                      filter: WinTestFilter(stationFilterEnabled: false, stationName: "STN2"))
        #expect(ev.contains(.turnActive(raw: "270")))
    }

    @Test func tvW3() {
        let b = Array(#"STATUS: "STN1" "" 0 1 1 0 140250 0 "CW" 0 "CW" 70250"#.utf8) + [0xD4, 0]
        let ev = WinTestParser.events(for: b, filter: WinTestFilter(selectedRadio: 0))
        #expect(ev.bandAndFrequency == [.frequency(vfo: .a, mhz: 14.025), .band(slot: .a, band: "20M"),
                                        .band(slot: .b, band: "20M")])
    }

    @Test func tvW4() {
        let b = Array(#"STATUS: "STN1" "" 0 1 1 1 140250 0 "CW" 0 "CW" 70250"#.utf8) + [0xD5, 0]
        let ev = WinTestParser.events(for: b, filter: WinTestFilter(selectedRadio: 3))
        #expect(ev.bandAndFrequency == [.frequency(vfo: .b, mhz: 7.025), .band(slot: .b, band: "40M")])
    }

    @Test func tvW5() {
        let b = Array(#"STATUS: "STN1" "" 0 1 1 1 140250 0 "CW" 0 "CW" 70250"#.utf8) + [0xD5, 0]
        let ev = WinTestParser.events(for: b, filter: WinTestFilter(selectedRadio: 1))
        #expect(ev.bandAndFrequency == [.frequency(vfo: .b, mhz: 7.025)])
    }

    @Test func badChecksumAcceptedButReported() {
        var b = automationBytes(hex: Self.w1Hex); b[b.count - 2] = 0x80
        let ev = WinTestParser.events(for: b, filter: WinTestFilter())
        #expect(ev.contains(.turnActive(raw: "270")))
        #expect(ev.contains(.status("Win-Test checksum mismatch (accepted)")))
    }

    @Test func grammarIsolated() {
        let s = WinTestStatusGrammar().parse(#"STATUS: "STN1" "" 0 1 1 1 140250 0 "CW" 0 "CW" 70250"#)
        #expect(s?.station == "STN1"); #expect(s?.rad == 1); #expect(s?.freq1 == 140250); #expect(s?.freq2 == 70250)
        #expect(WinTestStatusGrammar().parse(#"STATUS: "STN1" "" junk"#) == nil)
        #expect(WinTestPacket(bytes: [0, 0]) == nil)
    }
}

@Suite struct N3FJPVectorTests {
    @Test func tvF1() {
        let ev = N3FJPParser.events(for: "<CMD><READBMFRESPONSE><BAND>20</BAND><MODE>CW</MODE><FREQ>14.025</FREQ></CMD>")
        #expect(ev.bandAndFrequency == [.frequency(vfo: .a, mhz: 14.025), .frequency(vfo: .b, mhz: 14.025),
                                        .band(slot: .a, band: "20M")])
    }
    @Test func tvF2() {
        let ev = N3FJPParser.events(for: "<CMD><READBMFRESPONSE><FREQ>5.3305</FREQ></CMD>")
        #expect(ev.contains(.band(slot: .a, band: "60M")))
        #expect(N3FJPParser.events(for: "<CMD><FREQ>14,025</FREQ></CMD>").contains(.band(slot: .a, band: "20M")))
    }
    @Test func lineFramer() {
        var f = N3FJPLineFramer()
        #expect(f.push(Array("a\r\nb\r".utf8)) == ["a", "b"])
        #expect(f.push(Array("\nc".utf8)) == [])
        #expect(f.push(Array("\nd\ne".utf8)) == ["c", "d"])
        #expect(f.flush() == "e")
        #expect(f.flush() == nil)
    }
}
