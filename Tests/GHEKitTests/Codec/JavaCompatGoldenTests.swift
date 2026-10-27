import Foundation
import Testing
@testable import GHEKit

/// Compares the Java-compat helpers with output captured from a real Java 8 JRE
/// (scripts/golden/gen.sh → Tests/Fixtures/java8).
@Suite struct JavaCompatGoldenTests {
    @Test func doubleToStringMatchesJava8() throws {
        let rows = try fixtureRows("java8/double_tostring.txt")
        #expect(rows.count >= 10_000)
        var mismatches: [String] = []
        var nonShortest = 0
        for row in rows {
            let bits = UInt64(row[0], radix: 16)!
            let value = Double(bitPattern: bits)
            let got = JavaDouble.string(value)
            if value.isFinite && value != 0
                && Self.significantDigits(row[1]).count > JavaDoubleFormatter.shortestDigits(abs(value)).digits.count {
                // Java 8 printed more digits than needed: require round-trip equivalence,
                // both through Swift's parser and through our Java parseDouble emulation.
                nonShortest += 1
                let viaSwift = Double(got.replacingOccurrences(of: "E", with: "e"))
                let viaJava = JavaDouble.parse(got)
                if viaSwift?.bitPattern != bits || viaJava?.bitPattern != bits || JavaDouble.parse(row[1])?.bitPattern != bits {
                    mismatches.append("\(row[0]): java=\(row[1]) swift=\(got) (not round-trip equivalent)")
                }
            } else if got != row[1] {
                mismatches.append("\(row[0]): java=\(row[1]) swift=\(got)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(10))")
        print("Golden doubles: \(rows.count) values, \(nonShortest) Java-8 non-shortest cases")
        // 608 of 16,552 in the current fixture, almost all from the random-bit-pattern samples.
        #expect(nonShortest <= 608, "more Java-8 non-shortest cases than expected")
    }

    /// Wire headings (0…360 in 0.1 steps, both ways Java computes them) must match Java 8 byte for byte.
    @Test func headingGridMatchesJava8Exactly() throws {
        var java: [UInt64: String] = [:]
        for row in try fixtureRows("java8/double_tostring.txt") { java[UInt64(row[0], radix: 16)!] = row[1] }
        for i in 0...3600 {
            for v in [Double(i) / 10.0, Double(i) * 0.1] {
                let want = try #require(java[v.bitPattern])
                #expect(JavaDouble.string(v) == want, "\(i)")
            }
        }
    }

    /// Significant digits of a Java double string ("-1.2300E-5" → "123").
    static func significantDigits(_ s: String) -> String {
        let mantissa = s.split(separator: "E").first.map(String.init) ?? s
        var d = mantissa.filter { $0.isNumber }
        while d.hasPrefix("0") { d.removeFirst() }
        while d.hasSuffix("0") { d.removeLast() }
        return d
    }

    @Test func doubleToStringKnownValues() {
        #expect(JavaDouble.string(271) == "271.0")
        #expect(JavaDouble.string(0.0001) == "1.0E-4")
        #expect(JavaDouble.string(0.001) == "0.001")
        #expect(JavaDouble.string(1e7) == "1.0E7")
        #expect(JavaDouble.string(-0.0) == "-0.0")
        #expect(JavaDouble.string(.nan) == "NaN")
        #expect(JavaDouble.string(-.infinity) == "-Infinity")
        #expect(JavaDouble.string(359.99999999999994) == "359.99999999999994")
        #expect(JavaDouble.string(358.4) == "358.4")
    }

    @Test func parseDoubleMatchesJava8() throws {
        for row in try fixtureRows("java8/double_parse.txt") {
            let input = Hex.utf8(row[0])
            let got = JavaDouble.parse(input)
            if row[1] == "ERR" {
                #expect(got == nil, "\(input.debugDescription) should fail, got \(String(describing: got))")
            } else {
                let want = Double(bitPattern: UInt64(row[1], radix: 16)!)
                #expect(got.map { $0.bitPattern == want.bitPattern || ($0.isNaN && want.isNaN) } == true,
                        "\(input.debugDescription): java=\(want) swift=\(String(describing: got))")
            }
        }
    }

    @Test func parseDoubleCommaOption() {
        #expect(JavaDouble.parse("271,5") == nil)
        #expect(JavaDouble.parse("271,5", allowComma: true) == 271.5)
        #expect(JavaDouble.parse(" 1,5d ", allowComma: true) == 1.5)
    }

    @Test func cp1252DecodeMatchesJava8() throws {
        let rows = try fixtureRows("java8/cp1252_decode.txt")
        #expect(rows.count == 256)
        for row in rows {
            let b = UInt8(row[0], radix: 16)!
            let want = UInt16(row[1], radix: 16)!
            #expect(Array(Windows1252.decode([b]).utf16) == [want], "byte \(row[0])")
        }
        #expect(Windows1252.table.count == 256)
    }

    @Test func cp1252EncodeMatchesJava8() throws {
        for row in try fixtureRows("java8/cp1252_encode.txt") {
            let scalar = Unicode.Scalar(UInt32(row[0], radix: 16)!)!
            #expect(Windows1252.encode(String(scalar)) == Hex.bytes(row[1]), "U+\(row[0])")
        }
    }

    @Test func cp1252RoundTripsAllDefinedBytes() {
        let defined = (0...255).map(UInt8.init).filter { ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains($0) }
        #expect(Windows1252.encode(Windows1252.decode(defined)) == defined)
        #expect(Windows1252.encode("Tower 40m ☃") == Array("Tower 40m ?".utf8))
    }

    @Test func urlEncoderMatchesJava8() throws {
        for row in try fixtureRows("java8/url_encode.txt") {
            let input = Hex.utf8(row[0])
            let want = row.count > 1 ? row[1] : ""
            #expect(JavaURLCoding.encode(input) == want, "\(input.debugDescription)")
            #expect(JavaURLCoding.decode(want) == input)
        }
    }

    @Test func urlDecoderMatchesJava8() throws {
        for row in try fixtureRows("java8/url_decode.txt") {
            #expect(JavaURLCoding.decode(row[0]) == Hex.utf8(row[1]), "\(row[0])")
        }
        // Where Java throws, we keep the text.
        #expect(JavaURLCoding.decode("100%") == "100%")
        #expect(JavaURLCoding.decode("%zz") == "%zz")
    }
}
