import Testing
@testable import GHEClientKit

@Suite struct BandSwitchSelectorTests {
    let positions = [
        BandSwitchPosition(name: "Yagi", lowerMHz: 14.000, upperMHz: 14.350),
        BandSwitchPosition(name: "Dipole", lowerMHz: 14.000, upperMHz: 14.350),
        BandSwitchPosition(name: "OFF", lowerMHz: 0, upperMHz: 0),
        BandSwitchPosition(name: "Beverage", lowerMHz: 1.800, upperMHz: 2.000),
        BandSwitchPosition(name: "Dummy Load", lowerMHz: 0, upperMHz: 0),
    ]

    func sel(_ cur: String?, _ f: Double, _ locked: Set<String> = []) -> String? {
        BandSwitchSelector.select(positions: positions, current: cur, freqMHz: f, locked: locked)
    }

    @Test func tvB1FirstMatch() { #expect(sel("Beverage", 14.025) == "Yagi") }
    @Test func tvB2StickyManual() { #expect(sel("Dipole", 14.100) == nil) }
    @Test func tvB3() { #expect(sel("Dipole", 1.830) == "Beverage") }
    @Test func tvB4OffSticky() { #expect(sel("OFF", 14.025) == nil) }
    /// Documented rule: DUMMY keeps the position.
    @Test func tvB5DummySticky() { #expect(sel("Dummy Load", 14.025) == nil) }
    /// Nil current → first match.
    @Test func tvB6NilCurrent() { #expect(sel(nil, 14.025) == "Yagi") }
    /// Skip locked, take next match.
    @Test func tvB7LockedSkipped() { #expect(sel("Beverage", 14.025, ["Yagi"]) == "Dipole") }
    @Test func tvB8NoMatch() { #expect(sel("Beverage", 7.050) == nil) }

    @Test func unknownCurrentIsNotInRange() { #expect(sel("Gone", 14.025) == "Yagi") }
    @Test func allMatchesLocked() { #expect(sel("Beverage", 14.025, ["Yagi", "Dipole"]) == nil) }
    @Test func inclusiveEdges() {
        #expect(sel("Beverage", 14.000) == "Yagi")
        #expect(sel("Beverage", 14.350) == "Yagi")
        #expect(sel("Yagi", 14.3501) == nil)
    }

    @Test func offWordRule() {
        #expect(BandSwitchSelector.suspendsAutoSelection("OFF"))
        #expect(BandSwitchSelector.suspendsAutoSelection("off"))
        #expect(BandSwitchSelector.suspendsAutoSelection("Antenna Off"))
        #expect(BandSwitchSelector.suspendsAutoSelection("Off-Air"))
        #expect(!BandSwitchSelector.suspendsAutoSelection("Offset"))
        #expect(!BandSwitchSelector.suspendsAutoSelection("Takeoff"))
        #expect(BandSwitchSelector.suspendsAutoSelection("DUMMY"))
        #expect(BandSwitchSelector.suspendsAutoSelection("my dummyload"))
        #expect(!BandSwitchSelector.suspendsAutoSelection("Yagi"))
    }

    /// Default: first only; empty names ignored; banks set ON.
    @Test func defaultPositions() {
        #expect(DefaultPositionRule.position(in: ["Yagi", "80 Dipole Default", "*Vertical"]) == "80 Dipole Default")
        #expect(DefaultPositionRule.position(in: ["", "Yagi", "*Vertical"]) == "*Vertical")
        #expect(DefaultPositionRule.position(in: ["DEFAULT"]) == "DEFAULT")
        #expect(DefaultPositionRule.position(in: ["Yagi", ""]) == nil)
        #expect(DefaultPositionRule.action(in: ["*Amp"], isBank: true) == .setOn("*Amp"))
        #expect(DefaultPositionRule.action(in: ["*Amp"], isBank: false) == .select("*Amp"))
        #expect(DefaultPositionRule.action(in: ["Amp"], isBank: false) == nil)
    }
}

@Suite struct RadioRoutingTests {
    @Test func n1mmProcessTable() {
        typealias R = RadioRouting
        #expect(R.n1mmProcess(radioNr: "1", vfoSetting: 1)); #expect(!R.n1mmProcess(radioNr: "2", vfoSetting: 1))
        #expect(R.n1mmProcess(radioNr: nil, vfoSetting: 1)); #expect(!R.n1mmProcess(radioNr: "7", vfoSetting: 1))
        #expect(!R.n1mmProcess(radioNr: "3", vfoSetting: 2)); #expect(R.n1mmProcess(radioNr: "4", vfoSetting: 2))
        #expect(R.n1mmProcess(radioNr: nil, vfoSetting: 2)); #expect(!R.n1mmProcess(radioNr: "7", vfoSetting: 2))
        #expect(R.n1mmProcess(radioNr: "1", vfoSetting: 3)); #expect(R.n1mmProcess(radioNr: "2", vfoSetting: 3))
        #expect(R.n1mmProcess(radioNr: nil, vfoSetting: 3)); #expect(!R.n1mmProcess(radioNr: "x", vfoSetting: 3))
        #expect(R.n1mmRadio("3") == 1); #expect(R.n1mmRadio("4") == 2); #expect(R.n1mmRadio("9") == 1)
        #expect(R.n1mmRadio(nil) == 1)
    }

    @Test func winTestOtherRad() {
        #expect(RadioRouting.winTest(rad: 2, setting: 0, freqMHz: 14, band: .m20).isEmpty)
    }
}
