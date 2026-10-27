import Foundation
import Testing
@testable import GHEKit

@Suite struct JavaPropertiesTests {
    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func storeEntryLinesMatchJava8() throws {
        for row in try fixtureRows("java8/props_entries.txt") {
            let key = Hex.utf8(row[0]), value = Hex.utf8(row[1])
            var p = JavaProperties()
            p[key] = value
            let data = p.serialized(comment: nil)
            let body = [UInt8](data).drop { $0 != 0x0A }.dropFirst() // drop "#date\n"
            #expect(Hex.string(body) == row[2], "key \(key.debugDescription)")
        }
    }

    @Test func storeCommentsMatchJava8() throws {
        for row in try fixtureRows("java8/props_comments.txt") {
            let comment = Hex.utf8(row[0])
            let data = [UInt8](JavaProperties().serialized(comment: comment))
            // Drop the trailing "#<date>\n" line.
            let withoutNewline = data.dropLast()
            let lastLineStart = withoutNewline.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            #expect(Hex.string(data[..<lastLineStart]) == row[1], "comment \(comment.debugDescription)")
        }
    }

    @Test func storeFullFileMatchesJava8AsLineSet() throws {
        let javaData = try Fixtures.data("java8/props_store.properties")
        let javaLines = lines(javaData)
        // Load Java's file, store it again: same comment, same set of entry lines.
        let loaded = JavaProperties.parse(javaData)
        #expect(loaded.keys.count == 17)
        let ours = lines(loaded.serialized(comment: "Settings for server UI"))
        #expect(ours[0] == javaLines[0])
        #expect(ours[1].hasPrefix("#") && javaLines[1].hasPrefix("#"))
        #expect(Set(ours.dropFirst(2)) == Set(javaLines.dropFirst(2)))
        #expect(loaded["Tower 40m\u{1E}:17220"] == "true")
        #expect(loaded["key with spaces"] == "  leading and trailing  ")
        #expect(loaded["emoji"] == "\u{1F600}")
        #expect(loaded[""] == "empty key")
    }

    @Test func loadMatchesJava8() throws {
        let p = JavaProperties.parse(try Fixtures.data("java8/props_load_input.properties"))
        let expected = try fixtureRows("java8/props_load_expected.txt").map { (Hex.utf8($0[0]), Hex.utf8($0[1])) }
        #expect(Set(p.keys) == Set(expected.map(\.0)))
        for (k, v) in expected {
            #expect(p[k] == v, "key \(k.debugDescription): java=\(v.debugDescription) swift=\(String(describing: p[k]?.debugDescription))")
        }
        // File order is preserved, duplicates keep their first position.
        #expect(p.keys.first == "simple")
    }

    @Test func malformedUnicodeEscapeStopsLoadingLikeJava() {
        let p = JavaProperties.parse(Data("a=1\nb=\\u12G4\nc=3\n".utf8))
        #expect(p.keys == ["a"])
    }

    /// Exact for US zones and GMT. Foundation canonicalises "UTC" to GMT and abbreviates many
    /// non-US zones as "GMT+n", so those only compare the rest of the text.
    @Test func dateHeaderMatchesJava8ForUSAndGMTZones() throws {
        let strict: Set<String> = ["America/Los_Angeles", "America/New_York", "America/Chicago", "America/Denver", "GMT"]
        for row in try fixtureRows("java8/date_tostring.txt") {
            let tz = TimeZone(identifier: row[0])!
            let date = Date(timeIntervalSince1970: Double(Int64(row[1])!) / 1000)
            let ours = JavaDate.string(date, timeZone: tz)
            if strict.contains(row[0]) {
                #expect(ours == row[2], "\(row[0])")
            } else {
                // Same text apart from the zone abbreviation.
                let strip = { (s: String) in s.split(separator: " ").enumerated().filter { $0.offset != 4 }.map(\.element) }
                #expect(strip(ours) == strip(row[2]), "\(row[0])")
            }
        }
    }

    @Test func roundTripPreservesOrderAndUnknownKeys() {
        var p = JavaProperties()
        p["port"] = "17220"
        p["custom.unknown"] = "kept"
        p["name\u{1E}:17220"] = "é € 中"
        let back = JavaProperties.parse(p.serialized(comment: "Settings for server UI"))
        #expect(back == p)
        #expect(back.keys == ["port", "custom.unknown", "name\u{1E}:17220"])
        p["port"] = nil
        #expect(p.keys == ["custom.unknown", "name\u{1E}:17220"])
    }
}
