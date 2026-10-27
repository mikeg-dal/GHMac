import Testing
@testable import GHEKit

@Suite struct RT21CommandTests {
    private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

    @Test func fixedCommands() {
        #expect(s(RT21Commands.pollTenths()) == "BI2;")
        #expect(s(RT21Commands.pollInteger(digit: "1")) == "AI1;")
        #expect(s(RT21Commands.pollInteger(digit: "2")) == "AI2;")
        #expect(s(RT21Commands.jog(cw: false)) == "AA0;")
        #expect(s(RT21Commands.jog(cw: true)) == "AB0;")
        #expect(s(RT21Commands.stop) == ";")
    }

    @Test func gotoTenthsBasic() {
        #expect(s(RT21Commands.gotoTenths(45)) == "AP2045.0\r;")
        #expect(s(RT21Commands.gotoTenths(7.4)) == "AP2007.4\r;")
        #expect(s(RT21Commands.gotoTenths(123.4, digit: "1")) == "AP1123.4\r;")
    }

    /// Golden values from Java 8 `new DecimalFormat("000.0").format(d)` (HALF_EVEN on the exact double).
    @Test(arguments: [
        (99.95, "100.0"), (359.96, "360.0"), (0.0, "000.0"), (360.0, "360.0"), (45.25, "045.2"),
        (45.35, "045.4"), (45.45, "045.5"), (0.05, "000.1"), (0.15, "000.1"), (0.25, "000.2"),
        (123.45, "123.5"), (359.95, "359.9"), (12.25, "012.2"), (12.75, "012.8"), (180.05, "180.1"),
    ])
    func gotoTenthsMatchesJavaHalfEven(_ heading: Double, _ java: String) {
        #expect(s(RT21Commands.gotoTenths(heading)) == "AP2\(java)\r;")
    }

    @Test func gotoTenthsNormalisesOutOfRange() {
        // Wrapped into 0…360 instead of "-005.0" / "1234.5".
        #expect(s(RT21Commands.gotoTenths(-5)) == "AP2355.0\r;")
        #expect(s(RT21Commands.gotoTenths(365)) == "AP2005.0\r;")
        #expect(s(RT21Commands.gotoTenths(-0.0)) == "AP2000.0\r;")
        #expect(s(RT21Commands.gotoTenths(720)) == "AP2000.0\r;")
        #expect(s(RT21Commands.gotoTenths(.nan)) == "AP2000.0\r;")
    }

    @Test func gotoWithExecute() {
        #expect(s(RT21Commands.gotoWithExecute(45, digit: "2")) == "AP2045;AM2;")
        #expect(s(RT21Commands.gotoWithExecute(45, digit: "1")) == "AP1045;AM1;")
        #expect(s(RT21Commands.gotoWithExecute(44.5, digit: "1")) == "AP1045;AM1;")   // Math.round half up
        #expect(s(RT21Commands.gotoWithExecute(99.95, digit: "2")) == "AP2100;AM2;")
        #expect(s(RT21Commands.gotoWithExecute(359.96, digit: "2")) == "AP2360;AM2;")
        #expect(s(RT21Commands.gotoWithExecute(0, digit: "2")) == "AP2000;AM2;")
        #expect(s(RT21Commands.gotoWithExecute(360, digit: "2")) == "AP2360;AM2;")
    }

    @Test func gotoTerminal() {
        #expect(s(RT21Commands.gotoTerminal(7.4)) == "AP2007\r;")
        #expect(s(RT21Commands.gotoTerminal(45)) == "AP2045\r;")
        #expect(s(RT21Commands.gotoTerminal(2.5)) == "AP2003\r;")
        #expect(s(RT21Commands.gotoTerminal(359.6)) == "AP2360\r;")
        #expect(s(RT21Commands.gotoTerminal(-1)) == "AP2359\r;")
    }
}
