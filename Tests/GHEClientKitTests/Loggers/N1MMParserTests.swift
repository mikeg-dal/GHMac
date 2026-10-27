import Testing
import Foundation
import GHEKit
@testable import GHEClientKit

@Suite struct N1MMRadioVectorTests {
    func ev(_ body: String, _ vfo: Int) -> [LoggerEvent] {
        N1MMRadioParser.events(for: radioInfo(body), vfoSetting: vfo).bandAndFrequency
    }

    @Test func tvN1() {
        #expect(ev("<RadioNr>1</RadioNr><Freq>1402500</Freq><TXFreq>1402500</TXFreq>", 3) ==
                [.frequency(vfo: .a, mhz: 14.025), .band(slot: .a, band: "20M")])
    }
    @Test func tvN2SplitUsesTX() {
        #expect(ev("<RadioNr>1</RadioNr><Freq>1402500</Freq><TXFreq>1403500</TXFreq>", 3) ==
                [.frequency(vfo: .a, mhz: 14.035), .band(slot: .a, band: "20M")])
    }
    @Test func tvN3() {
        #expect(ev("<RadioNr>2</RadioNr><Freq>702500</Freq><TXFreq>702500</TXFreq>", 3) ==
                [.frequency(vfo: .b, mhz: 7.025), .band(slot: .b, band: "40M")])
    }
    /// VFO-B switches still follow radio 2 on a "Radio 1 only" client.
    @Test func tvN4() {
        #expect(ev("<RadioNr>2</RadioNr><Freq>702500</Freq><TXFreq>702500</TXFreq>", 1) ==
                [.frequency(vfo: .b, mhz: 7.025)])
    }
    @Test func tvN5() {
        #expect(ev("<RadioNr>2</RadioNr><Freq>702500</Freq><TXFreq>702500</TXFreq>", 2) ==
                [.frequency(vfo: .b, mhz: 7.025), .band(slot: .b, band: "40M"), .band(slot: .a, band: "40M")])
    }
    @Test func tvN6() {
        #expect(ev("<RadioNr>3</RadioNr><Freq>2102500</Freq>", 1) ==
                [.frequency(vfo: .a, mhz: 21.025), .band(slot: .a, band: "15M"), .band(slot: .b, band: "15M")])
    }
    @Test func tvN7() {
        #expect(ev("<RadioNr>4</RadioNr><Freq>181000</Freq>", 3) ==
                [.frequency(vfo: .b, mhz: 1.81), .band(slot: .b, band: "160M")])
    }
    @Test func tvN8NoRadioNr() {
        #expect(ev("<Freq>1402500</Freq>", 2) == [.frequency(vfo: .a, mhz: 14.025), .band(slot: .a, band: "20M")])
    }
    @Test func tvN9to14() {
        func band(_ tx: String) -> String? {
            for case .band(_, let b) in ev("<RadioNr>1</RadioNr><TXFreq>\(tx)</TXFreq>", 3) { return b }
            return "none"
        }
        #expect(band("533050") == "60M")
        #expect(band("5012500") == "50")
        #expect(ev("<RadioNr>1</RadioNr><TXFreq>5012500</TXFreq>", 3).first == .frequency(vfo: .a, mhz: 50.125))
        #expect(band("14420000") == "144")
        #expect(band("129610000") == "1.2G")
        #expect(band("180000") == "160M")
        #expect(band("179999") == nil)   // "???"
        #expect(band("2990000") == "10M")
        #expect(band("420000") == "80M")
    }
    @Test func tvN15Focus() {
        let text = radioInfo("<FocusEntry>132456</FocusEntry><FocusRadioNr>2</FocusRadioNr><RadioNr>1</RadioNr><Freq>1402500</Freq>")
        let info = N1MMRadioParser.parse(text)
        #expect(info.focusEntry == "132456")
        #expect(info.focusRadioNr == 2)
        #expect(N1MMRadioParser.events(for: text, vfoSetting: 3).contains(.focusRadio(2)))
    }
    /// Comma decimals parse.
    @Test func tvN16Comma() {
        #expect(ev("<RadioNr>1</RadioNr><Freq>14025,00</Freq>", 3) ==
                [.frequency(vfo: .a, mhz: 14.025), .band(slot: .a, band: "20M")])
        #expect(ev("<RadioNr>1</RadioNr><Freq>14025.00</Freq>", 3).first == .frequency(vfo: .a, mhz: 14.025))
    }
    @Test func malformedIsHarmless() {
        #expect(ev("<RadioNr>1</RadioNr><Freq>abc</Freq>", 3).isEmpty)
        // Missing close tag at the end of the text: tolerant, takes the rest.
        #expect(N1MMRadioParser.events(for: "<RadioNr>1</RadioNr><Freq>1402500", vfoSetting: 3)
            .bandAndFrequency.first == .frequency(vfo: .a, mhz: 14.025))
        #expect(N1MMRadioParser.events(for: "", vfoSetting: 3) == [.raw("")])
    }
    @Test func numberParsing() {
        #expect(LoggerText.parseNumber(" 14,025 ") == 14.025)
        #expect(LoggerText.parseNumber("-3") == -3)
        #expect(LoggerText.parseNumber("1.2.3") == nil)
        #expect(LoggerText.parseNumber("1e5") == nil)
        #expect(LoggerText.parseNumber("") == nil)
        #expect(LoggerText.parseNumber(".") == nil)
    }
}

@Suite struct N1MMRotorVectorTests {
    @Test func tvR1() {
        let p = #"<?xml version="1.0" encoding="utf-8"?><N1MMRotor><rotor>Tribander</rotor><goazi>123.0</goazi><offset>0.0</offset><bidirectional>0</bidirectional><freqband>14.0</freqband></N1MMRotor>"#
        #expect(N1MMRotorParser.parse(p) == .goAzimuth(raw: "123.0", rotor: "Tribander"))
        #expect(N1MMRotorParser.events(for: p).withoutRaw == [.status("Rotor: 123.0"), .turnActive(raw: "123.0")])
    }
    /// Stop works.
    @Test func tvR2() {
        let p = #"<?xml version="1.0" encoding="utf-8"?><N1MMRotor><stop><rotor>Tribander</rotor><freqband>14.0</freqband></stop></N1MMRotor>"#
        #expect(N1MMRotorParser.parse(p) == .stop(rotor: "Tribander"))
        #expect(N1MMRotorParser.events(for: p).contains(.stopActive))
    }
    @Test func tvR3R4SO2RFilter() {
        // R3: radio-2 context, focus radio 1 → ignored.
        #expect(!SO2RFilter.accept(activeRadio: 1, thisRadio: 2))
        // R4: main context, focus never received → accepted.
        #expect(SO2RFilter.accept(activeRadio: nil, thisRadio: 1))
        // Radio-2 context with unknown focus also accepts.
        #expect(SO2RFilter.accept(activeRadio: nil, thisRadio: 2))
        #expect(!SO2RFilter.accept(activeRadio: 2, thisRadio: 1))
        #expect(SO2RFilter.accept(activeRadio: 2, thisRadio: 2))
        #expect(SO2RFilter.accept(activeRadio: 2, thisRadio: 1, so2rActive: false))
    }
}
