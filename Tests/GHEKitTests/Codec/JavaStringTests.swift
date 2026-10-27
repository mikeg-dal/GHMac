import Testing
@testable import GHEKit

@Suite struct JavaStringTests {
    @Test func splitDropsTrailingEmptiesForLimitZero() {
        #expect(JavaString.split("a,b,,", separator: ",") == ["a", "b"])
        #expect(JavaString.split(",a,,b", separator: ",") == ["", "a", "", "b"])
        #expect(JavaString.split(",,,", separator: ",") == [])
        #expect(JavaString.split("", separator: ",") == [""])
        #expect(JavaString.split("abc", separator: ",") == ["abc"])
        #expect(JavaString.split("SWITCHLOCKS\u{1F}SW\u{1F}\u{1F}", separator: "\u{1F}") == ["SWITCHLOCKS", "SW"])
    }

    @Test func splitWithPositiveLimit() {
        #expect(JavaString.split("PASS:0.5:x", separator: ":", limit: 2) == ["PASS", "0.5:x"])
        #expect(JavaString.split("PASS:", separator: ":", limit: 2) == ["PASS", ""])
        #expect(JavaString.split("a,b,c", separator: ",", limit: 1) == ["a,b,c"])
        #expect(JavaString.split("a,,", separator: ",", limit: 5) == ["a", "", ""])
    }

    @Test func splitWithNegativeLimitKeepsTrailingEmpties() {
        #expect(JavaString.split("a,,", separator: ",", limit: -1) == ["a", "", ""])
    }

    @Test func splitOnCarriageReturnIgnoresGraphemeClusters() {
        // "\r\n" is one Swift Character; Java splits UTF-16 units.
        #expect(JavaString.split("TURN\r\nX", separator: "\r") == ["TURN", "\nX"])
        #expect(JavaString.split("a\r", separator: "\r") == ["a"])
    }

    @Test func trimStripsControlCharsAndSpaces() {
        #expect(JavaString.trim("\0\t alice \r\n\u{1F}") == "alice")
        #expect(JavaString.trim("\u{A0}x\u{A0}") == "\u{A0}x\u{A0}")
        #expect(JavaString.trim("   ") == "")
    }

    @Test func parseBoolAndInt() {
        #expect(JavaString.parseBool("TRUE"))
        #expect(!JavaString.parseBool("yes"))
        #expect(!JavaString.parseBool(" true"))
        #expect(JavaString.parseInt("-71") == -71)
        #expect(JavaString.parseInt("+5") == 5)
        #expect(JavaString.parseInt(" 5") == nil)
        #expect(JavaString.parseInt("2147483648") == nil)
        #expect(JavaString.parseInt("") == nil)
    }
}
