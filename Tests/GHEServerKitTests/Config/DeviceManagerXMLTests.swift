import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

@Suite struct DeviceManagerXMLTests {
    /// The rows scripts/golden/server/ServerGolden.java writes into dm_golden.xml.
    static let goldenPanels: [DevicePanelConfig] = [
        .init(order: 0, name: "Tower", port: "RT21-NET", deviceType: "RT-21", initialState: true),
        .init(order: 1, name: "40m Fixed", deviceType: "Fixed Antenna", initialState: true, fixedHeading: 999.0),
        .init(order: 2, name: "Tower 15m", port: "COM5", deviceType: "Cloned Antenna", subType: "RT-21",
              initialState: true, cloneOffset: -30.0),
        .init(order: 3, name: "Yagi1,Yagi2,Yagi3", port: "COM7", deviceType: "GHE Base", subType: "Stack Match (1-4)",
              wioAddress: 4, basePTT: true, initialState: true),
        .init(order: 4, name: "A&B <x> \"q\" 'a' é€\ttab", port: "/dev/cu.usbserial-A1", deviceType: "GHE Base",
              subType: "8 Simple", wioAddress: 255, basePTT: true),
        .init(order: 5, name: "Fixed unset", deviceType: "Fixed Antenna"),
        .init(order: 6, name: "Clone unset", port: "COM5", deviceType: "Cloned Antenna", subType: "RT-21"),
        .init(order: 7, name: "Tiny", deviceType: "Fixed Antenna", fixedHeading: 1.0E-4),
        .init(order: 8, name: "Clone 12.5", port: "COM5", deviceType: "Cloned Antenna", subType: "RT-21",
              wioAddress: 3, cloneOffset: 12.5),
        .init(order: 9, name: "DCU", port: "COM9", deviceType: "DCU-1"),
        .init(order: 10, name: "Virt", port: "COM7", deviceType: "Virtual Switch", subType: "8 Simple",
              wioAddress: 0, basePTT: true),
        .init(order: 11, name: "line1\nline2\r"),
        .init(order: 12, name: "Emoji 📡 >"),
        .init(order: 13, name: "Big", deviceType: "Fixed Antenna", fixedHeading: 12345678.9),
    ]

    @Test func serializeMatchesJDK8DOMGolden() throws {
        let golden = try Fixtures.data("server/dm_golden.xml")
        let out = DeviceManagerXML.serialize(Self.goldenPanels)
        #expect(String(decoding: out, as: UTF8.self) == String(decoding: golden, as: UTF8.self))
    }

    @Test func goldenRoundTrips() throws {
        let golden = try Fixtures.data("server/dm_golden.xml")
        let r = DeviceManagerXML.parse(golden)
        #expect(r.warnings.isEmpty)
        #expect(r.panels.count == 100)
        #expect(r.panels[11].name == "line1\nline2\r")
        #expect(r.panels[12].name == "Emoji 📡 >")
        #expect(r.panels[4].wioAddress == 255)
        #expect(r.panels[5].fixedHeading == DevicePanelConfig.fixedHeadingUnset)
        #expect(r.panels[2].cloneOffset == -30.0)
        #expect(DeviceManagerXML.serialize(r.panels) == golden)
        #expect(r.referencedPorts == ["RT21-NET", "N/A", "COM5", "COM7", "/dev/cu.usbserial-A1", "COM9"])
    }

    /// A first-run file: 50 blank rows, CRLF.
    @Test func blankWindowsFileLoadsInto100Slots() throws {
        let url = Fixtures.url("server/input/device_list_blank.xml")
        let r = DeviceManagerXML.load(from: url)
        #expect(r.warnings.isEmpty)
        #expect(r.panels.count == 100)
        #expect(r.panels.enumerated().allSatisfy { $0.offset == $0.element.order })
        #expect(r.panels.allSatisfy { $0.isEmpty && $0.type == .rt21 && $0.port == "N/A" && $0.wioAddress == nil && !$0.initialState })
        #expect(r.panels == DeviceManagerXML.blankPanels())
        // An existing file (CRLF) comes back byte-identical for its 50 rows.
        let fifty = DeviceManagerXML.serialize(Array(r.panels.prefix(50)), lineEnding: "\r\n")
        let original = try Data(contentsOf: url)
        let text = String(decoding: fifty, as: UTF8.self)
        let rows = text.components(separatedBy: "\r\n").prefix(52).joined(separator: "\r\n")
        #expect(String(decoding: original, as: UTF8.self).hasPrefix(rows))
    }

    static func doc(_ panels: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<DeviceManager>\n\(panels)\n</DeviceManager>\n".utf8)
    }

    @Test func missingEmptyOrBadOrderIsTolerated() {
        let r = DeviceManagerXML.parse(Self.doc("""
        <panel name="A" port="COM1" deviceType="RT-21"/>
        <panel name="B" order="" deviceType="RT-21"/>
        <panel name="C" order="x" deviceType="RT-21"/>
        <panel name="D" order="150" deviceType="RT-21"/>
        <panel name="E" order="-1" deviceType="RT-21"/>
        <panel name="F" order="99" deviceType="WIO 8" wioAddress="7" busAddress="3" color="red"/>
        <panel name="G" order="0" deviceType="WIO 6" wioAddress="300"/>
        """))
        #expect(r.panels.count == 100)
        #expect(r.panels[1].name == "B")
        #expect(r.panels[2].name == "C")
        #expect(r.panels[99].name == "F")
        #expect(r.panels[99].type == .gheBase)
        #expect(r.panels[99].wioAddress == 7)
        #expect(r.panels[99].extraAttributes == ["busAddress": "3", "color": "red"])
        #expect(r.panels[0].name == "G") // later duplicate wins
        #expect(r.panels[0].type == .gheBase)
        #expect(r.panels[0].wioAddress == nil)
        #expect(!r.panels.contains { $0.name == "D" || $0.name == "E" })
        // bad order, 150, -1, duplicate 0, bad wio address
        #expect(r.warnings.count == 5)
        // Unknown attributes survive a write.
        let text = String(decoding: DeviceManagerXML.serialize(r.panels), as: UTF8.self)
        #expect(text.contains(#"<panel basePTT="false" busAddress="3" color="red" deviceType="GHE Base" initialState="false" name="F" order="99" port="N/A" subType="N/A" wioAddress="7"/>"#))
    }

    @Test func namesAreKeptVerbatim() {
        // Names are kept as written ("A+B" is not URL-decoded).
        let r = DeviceManagerXML.parse(Self.doc(#"<panel name="A+B%20C" order="0" deviceType="RT-21"/>"#))
        #expect(r.panels[0].name == "A+B%20C")
    }

    @Test func malformedOrMissingFileGivesBlankRows() {
        let bad = DeviceManagerXML.parse(Data("<DeviceManager><panel".utf8))
        #expect(bad.panels == DeviceManagerXML.blankPanels())
        #expect(bad.warnings.count == 1)
        let missing = DeviceManagerXML.load(from: URL(fileURLWithPath: "/nonexistent/DeviceManager.xml"))
        #expect(missing.panels == DeviceManagerXML.blankPanels())
        #expect(missing.warnings.isEmpty)
    }

    @Test func sentinelsAreWrittenOnlyForTheirTypes() {
        let rows: [DevicePanelConfig] = [
            .init(order: 0, name: "F", deviceType: "Fixed Antenna"),
            .init(order: 1, name: "C", deviceType: "Cloned Antenna", cloneOffset: nil),
            .init(order: 2, name: "R", deviceType: "RT-21", fixedHeading: 10, cloneOffset: 5),
        ]
        let lines = String(decoding: DeviceManagerXML.serialize(rows), as: UTF8.self).components(separatedBy: "\n")
        #expect(lines[2].contains(#"fixedHeading="-123456.0""#))
        #expect(lines[3].contains(#"cloneOffset="-654321.0""#))
        #expect(!lines[4].contains("fixedHeading") && !lines[4].contains("cloneOffset"))
        #expect(lines.count == 104) // decl + root + 100 rows + close + trailing ""
    }

    @Test func writeIsAtomicAndReadable() throws {
        let dirs = AppDirectories.temporary(prefix: "test-dm")
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let url = dirs.file(DeviceManagerXML.fileName)
        try DeviceManagerXML.write(Self.goldenPanels, to: url)
        let back = DeviceManagerXML.load(from: url).panels
        #expect(back[3] == Self.goldenPanels[3])
        #expect(back[13].fixedHeading == 12345678.9)
    }
}
