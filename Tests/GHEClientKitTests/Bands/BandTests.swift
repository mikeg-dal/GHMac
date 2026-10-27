import Testing
@testable import GHEClientKit

@Suite struct BandClassifyTests {
    /// Every lower edge: exactly at the edge → that band; just below → the previous one.
    @Test func fullEdgeTable() {
        var previous: Band? = nil
        for (edge, band) in Band.lowerEdgesKHz {
            #expect(Band.classify(kHz: edge) == band, "\(edge)")
            #expect(Band.classify(kHz: edge - 0.01) == previous, "below \(edge)")
            #expect(Band.classify(mhz: edge / 1000) == band, "MHz \(edge)")
            previous = band
        }
        #expect(Band.classify(kHz: 1_799.99) == nil)
        #expect(Band.classify(kHz: 0) == nil)
        #expect(Band.classify(kHz: .nan) == nil)
        #expect(Band.classify(kHz: 99_000_000) == .g47)
    }

    @Test func legacyNames() {
        #expect(Band.allCases.map(\.rawValue) == ["160M", "80M", "60M", "40M", "30M", "20M", "17M", "15M", "12M", "10M",
                                                  "50", "144", "222", "432", "902", "1.2G", "2.3G", "3.4G", "5.7G",
                                                  "10G", "24G", "47G"])
        #expect(Band.legacyString(nil) == "???")
    }

    /// Lower edges only.
    @Test func lowerEdgeOnlyReplicated() {
        #expect(Band.classify(kHz: 29_900) == .m10)
        #expect(Band.classify(kHz: 4_200) == .m80)
        #expect(Band.classify(kHz: 49_990) == .m10)
        #expect(Band.classify(kHz: 148_000) == .m2)
    }

    /// N3FJP 5.3305 MHz is 60M.
    @Test func n3fjpSixtyMetres() {
        #expect(N3FJPParser.band(mhz: 5.3305) == .m60)
        #expect(N3FJPParser.band(mhz: 1.8) == .m160)
        #expect(N3FJPParser.band(mhz: 1.7999) == nil)
        #expect(N3FJPParser.band(mhz: 1296.1) == .g1_2)
    }

    @Test func scopes() {
        #expect(BandScope.hfContest.columns.map(\.rawValue) == ["160M", "80M", "40M", "20M", "15M", "10M", "50"])
        #expect(BandScope.hfAll.columns.map(\.rawValue) ==
                ["160M", "80M", "60M", "40M", "30M", "20M", "17M", "15M", "12M", "10M", "50"])
        #expect(BandScope.vhf.columns.map(\.rawValue) ==
                ["50", "144", "222", "432", "902", "1.2G", "2.3G", "3.4G", "5.7G", "10G", "24G", "47G"])
        #expect(BandScope.allCases.allSatisfy { $0.columns.contains(.m6) })
        #expect(BandScope.allCases.filter { $0.columns.contains(.m60) } == [.hfAll])
        #expect(BandScope(settingsValue: "hfall") == .hfAll)
        #expect(BandScope(settingsValue: "VHF") == .vhf)
        #expect(BandScope(settingsValue: nil) == .hfContest)
        #expect(BandScope(settingsValue: "junk") == .hfContest)
        #expect(BandScope.hfContest.settingsValue == "hfcontest")
    }
}

@Suite struct BandStateTests {
    @Test func startsAllAndShowsEverything() {
        let s = BandState()
        #expect(s.a == "ALL" && s.b == "ALL")
        #expect(s.isVisible(deviceBands: []))
    }

    /// ALL in slot B also shows everything. Any case.
    @Test func allOnEitherSlot() {
        #expect(BandState(a: "20M", b: "ALL").isVisible(deviceBands: ["40M"]))
        #expect(BandState(a: "All", b: "20M").isVisible(deviceBands: ["40M"]))
        #expect(BandState(a: "20M", b: "all").isVisible(deviceBands: []))
    }

    @Test func unionOfSlots() {
        let s = BandState(a: "20M", b: "40M")
        #expect(s.isVisible(deviceBands: ["20M"]))
        #expect(s.isVisible(deviceBands: ["40M"]))
        #expect(!s.isVisible(deviceBands: ["15M"]))
        #expect(!s.isVisible(deviceBands: ["20m"]))   // case-sensitive like Set.contains
        #expect(!BandState(a: "???", b: "???").isVisible(deviceBands: ["20M", "???x"]))
    }

    @Test func changeDetection() {
        var s = BandState()
        let c1 = s.apply(.band(slot: .a, band: "20M"))
        let c2 = s.apply(.band(slot: .a, band: "20M"))
        let c3 = s.apply(.band(slot: .b, band: nil))
        let c4 = s.apply(.raw("x"))
        #expect(c1 && !c2 && c3 && !c4)
        #expect(s.b == "???")
    }
}

@Suite struct ManualBandTests {
    @Test func table() {
        let expected: [String: Double] = [
            "160M": 1.801, "80M": 3.501, "60M": 5.331, "40M": 7.001, "30M": 10.101, "20M": 14.001,
            "17M": 18.070, "15M": 21.001, "12M": 24.900, "10M": 28.001, "50": 50.100, "144": 144.100,
            "222": 222.100, "432": 432.100, "902": 902.100, "1.2G": 1296.0, "2.3G": 2304.0, "3.4G": 3456.0,
            "5.7G": 5760.0, "10G": 10000.0, "24G": 24192.0, "47G": 47088.0,
        ]
        for (b, f) in expected { #expect(ManualBandFrequencies.mhz(for: b) == f, "\(b)") }
        #expect(ManualBandFrequencies.mhz(for: "160m") == 1.801)
        #expect(ManualBandFrequencies.mhz(for: "ALL") == 0.0)
        #expect(ManualBandFrequencies.mhz(for: "junk") == 0.0)
    }

    @Test func tvM1() {
        let ev = ManualBandFrequencies.events(forPick: "60M")
        #expect(ev == [.band(slot: .a, band: "60M"), .band(slot: .b, band: "60M"), .frequency(vfo: .a, mhz: 5.331)])
        var s = BandState()
        ev.forEach { s.apply($0) }
        #expect(s == BandState(a: "60M", b: "60M"))
    }

    @Test func tvM2() {
        let ev = ManualBandFrequencies.events(forPick: "ALL")
        #expect(ev.last == .frequency(vfo: .a, mhz: 0.0))
        var s = BandState(a: "20M", b: "20M")
        ev.forEach { s.apply($0) }
        #expect(s.isVisible(deviceBands: []))
    }
}
