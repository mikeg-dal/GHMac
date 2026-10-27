import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

@Suite struct WioProfileXMLTests {
    /// Synthetic profiles in the legacy format (CRLF, attributes sorted, pins 7…0).
    static let inputProfiles = Fixtures.url("server/input/wioProfiles")

    static func input(_ name: String) throws -> Data {
        try Data(contentsOf: inputProfiles.appendingPathComponent(name + ".xml"))
    }

    /// file → (devicename, display type, positions, matrix lockout)
    static let expected: [String: (String, SwitchDisplayType, Int, Bool)] = [
        "amp_toggle": ("Amp Toggle", .bank, 1, false),
        "band_filter_seven": ("Band Filter Seven", .band, 7, false),
        "band_select_eight": ("Band Select 8", .band, 8, false),
        "demo_four_square": ("Demo 4-Square", .map, 5, false),
        "eight_way_select": ("Eight-Way Select", .buttons, 8, false),
        "lockout_map": ("Lockout Map", .map, 6, true),
        "pulse_trio": ("Pulse Trio", .buttons, 3, false),
        "rx_splitter_b": ("RX Splitter B ", .buttons, 9, false), // trailing space kept verbatim
        "split_primary": ("Split Primary", .buttons, 3, false),
        "split_secondary": ("Split Secondary", .buttons, 3, false),
        "test_bank_a": ("Test Bank A", .bank, 9, true),
    ]

    @Test func everyInputProfileParses() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.inputProfiles.path)
            .filter { $0.hasSuffix(".xml") }
        #expect(files.count == Self.expected.count)
        for file in files {
            let base = String(file.dropLast(4))
            let r = WioProfileXML.parse(try Self.input(base))
            #expect(r.errors.isEmpty, "\(file): \(r.errors)")
            #expect(r.warnings.isEmpty, "\(file): \(r.warnings)")
            let p = try #require(r.profile, "\(file)")
            let e = try #require(Self.expected[base], "unexpected file \(file)")
            #expect(p.name == e.0)
            #expect(p.displayType == e.1, "\(file)")
            #expect(p.positions.count == e.2, "\(file)")
            #expect(p.matrixLockout == e.3, "\(file)")
            #expect(!p.virtualSwitch)
            #expect(p.positions.allSatisfy { $0.pins.count == 8 }, "\(file)")
        }
    }

    @Test func pinStatesAndFrequencies() throws {
        let simple = try #require(WioProfileXML.parse(try Self.input("eight_way_select")).profile)
        #expect(simple.positionNames == ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT"])
        #expect(simple.positions[0].pins == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(simple.positions[7].pins == [0, 0, 0, 0, 0, 0, 0, 1])
        let amp = try #require(WioProfileXML.parse(try Self.input("amp_toggle")).profile)
        #expect(amp.positions[0].pins == [-1, -1, -1, -1, -1, -1, -1, 1])
        let mom = try #require(WioProfileXML.parse(try Self.input("pulse_trio")).profile)
        #expect(mom.positions[0].pins[0] == 2)
        #expect(mom.positions[1].heading == 120 && mom.positions[1].beamwidth == 120)
        #expect(mom.momentaryPins == [0, 1, 2])
        let band = try #require(WioProfileXML.parse(try Self.input("band_filter_seven")).profile)
        #expect(band.positions[0].name == "10 M")
        #expect(band.positions[0].lowerMHz == 28.0)
        #expect(band.positions[0].upperMHz == 29.7)
        #expect(band.positions[2].upperMHz == 21.45)
        #expect(band.positions[5].lowerMHz == 1.8)
        let map = try #require(WioProfileXML.parse(try Self.input("demo_four_square")).profile)
        #expect(map.positions[3].heading == 315 && !map.positions[3].bidirectional)
        #expect(map.positions[4].beamwidth == 360 && map.positions[4].bidirectional)
    }

    @Test(arguments: ["eight_way_select", "test_bank_a", "pulse_trio", "band_filter_seven", "rx_splitter_b", "amp_toggle"])
    func rewriteMatchesJDK8Golden(_ name: String) throws {
        let p = try #require(WioProfileXML.parse(try Self.input(name)).profile)
        let golden = try Fixtures.data("server/wio_\(name).xml")
        let out = WioProfileXML.serialize(p)
        #expect(String(decoding: out, as: UTF8.self) == String(decoding: golden, as: UTF8.self))
    }

    /// Existing files (all three root attributes) come back byte-identical with CRLF.
    @Test(arguments: ["band_select_eight", "split_primary", "split_secondary"])
    func javaWrittenFileRoundTripsWithCRLF(_ name: String) throws {
        let data = try Self.input(name)
        let p = try #require(WioProfileXML.parse(data).profile)
        #expect(WioProfileXML.serialize(p, lineEnding: "\r\n") == data)
    }

    static let virtualModel = WioProfile(
        name: "Virtual & Co", displayType: .map, matrixLockout: false, virtualSwitch: true, positions: [
            .init(name: "North", heading: 0, beamwidth: 60, bidirectional: true, virtualEntries: [
                .init(target: "Ant Switch", action: "FIRST"), .init(target: "Tower", action: "#123.5"),
            ]),
            .init(name: "South \"S\"", heading: 180, beamwidth: 45, virtualEntries: [
                .init(target: "Ant <Switch>", action: "TWO"), .init(target: "Tower", action: "$cmd"),
            ]),
            .init(name: "Empty", heading: 90),
        ])

    @Test func virtualProfileMatchesGoldenAndParsesBack() throws {
        let golden = try Fixtures.data("server/wio_virtual.xml")
        #expect(String(decoding: WioProfileXML.serialize(Self.virtualModel), as: UTF8.self)
                == String(decoding: golden, as: UTF8.self))
        let r = WioProfileXML.parse(golden)
        #expect(r.errors.isEmpty)
        #expect(r.profile == Self.virtualModel)
        #expect(r.profile?.virtualEntries(for: "North").map(\.action) == ["FIRST", "#123.5"])
    }

    @Test func escapingDoublesAndShortPinArraysMatchGolden() throws {
        let model = WioProfile(
            name: "Band <&> é \"q\" 'a' \t 📡 \u{1}", displayType: .band, matrixLockout: true, positions: [
                .init(name: "160 M", lowerMHz: 1.8, upperMHz: 2.0, pins: [1, 0, -1, 2, 0, 0, 0, 0]),
                .init(name: "Tiny", heading: 359, beamwidth: 360, bidirectional: true, lowerMHz: 1.0E-4,
                      upperMHz: 1.0E7, pins: [0, 1, 0, 0, 0, 0, 0, 1]),
                .init(name: "Four pins", heading: 10, beamwidth: 20, lowerMHz: 3.5, upperMHz: 3.8, pins: [1, -1, 2, 0]),
            ])
        let golden = try Fixtures.data("server/wio_special.xml")
        #expect(String(decoding: WioProfileXML.serialize(model), as: UTF8.self) == String(decoding: golden, as: UTF8.self))
    }

    static func xml(_ positions: String, root: String = #"displayType="SWITCH""#, name: String = "T") -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <WioDevice \(root)>
        <devicename>\(name)</devicename>
        <positions>
        \(positions)
        </positions>
        </WioDevice>
        """.utf8)
    }

    static func pos(_ name: String, order: String, heading: String = "0", extra: String = "", pins: String = "") -> String {
        #"<position beamwidth="0" bidirectional="false" heading="\#(heading)" lowerFreq="0.0" name="\#(name)" order="\#(order)" upperFreq="0.0"\#(extra)>\#(pins)</position>"#
    }

    @Test func outOfOrderPositionsAreSorted() {
        let r = WioProfileXML.parse(Self.xml(Self.pos("B", order: "1") + Self.pos("C", order: "2") + Self.pos("A", order: "0")))
        #expect(r.errors.isEmpty)
        #expect(r.profile?.positionNames == ["A", "B", "C"])
        #expect(!r.warnings.isEmpty)
    }

    @Test func badNumbersRejectTheProfileWithErrors() {
        let r = WioProfileXML.parse(Self.xml(Self.pos("A", order: "0", heading: "12.5") + Self.pos("B", order: "x")))
        #expect(r.profile == nil)
        #expect(r.errors.count == 2)
        let missing = WioProfileXML.parse(Self.xml(#"<position name="A" order="0"/>"#))
        #expect(missing.profile == nil)
        #expect(missing.errors.count == 4) // heading, beamwidth, lowerFreq, upperFreq
        #expect(WioProfileXML.parse(Data("<WioDevice><positions/></WioDevice>".utf8)).errors == ["Missing <devicename>."])
        #expect(WioProfileXML.parse(Data("not xml".utf8)).profile == nil)
        #expect(WioProfileXML.parse(Data()).profile == nil)
    }

    @Test func unknownDisplayTypeAndPinStateAreTolerated() {
        let pins = #"<pin number="1" state="weird"/><pin number="0" state="on"/>"#
        let r = WioProfileXML.parse(Self.xml(Self.pos("A", order: "0", pins: pins), root: #"displayType="FANCY" hardware="x""#))
        #expect(r.profile?.displayType == .buttons)
        #expect(r.profile?.positions[0].pins == [1, 0])
        #expect(r.warnings.count == 2)
    }

    @Test func pinNumbersBeyondCountGrowTheArray() {
        let r = WioProfileXML.parse(Self.xml(Self.pos("A", order: "0", pins: #"<pin number="3" state="on"/>"#)))
        #expect(r.profile?.positions[0].pins == [0, 0, 0, 1])
        let bad = WioProfileXML.parse(Self.xml(Self.pos("A", order: "0", pins: #"<pin number="-1" state="on"/>"#)))
        #expect(bad.profile == nil)
    }

    @Test func cp1252FileIsReadDespiteUTF8Declaration() {
        var data = Self.xml(Self.pos("Caf\u{E9}", order: "0"), name: "Ant")
        // Re-encode as Cp1252.
        data = Data(Windows1252.encode(String(decoding: data, as: UTF8.self)))
        #expect(String(data: data, encoding: .utf8) == nil)
        let r = WioProfileXML.parse(data)
        #expect(r.profile?.positions.first?.name == "Café")
        // Written back as real UTF-8.
        let out = WioProfileXML.serialize(r.profile!)
        #expect(String(data: out, encoding: .utf8)?.contains("Café") == true)
    }

    @Test func storeLoadsFolderAndReportsBadFiles() async throws {
        let dirs = AppDirectories.temporary(prefix: "test-profiles")
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let store = WioProfileStore(appDirectories: dirs)
        let folder = dirs.subdirectory(WioProfileStore.directoryName)
        for n in ["eight_way_select", "amp_toggle"] {
            try Self.input(n).write(to: folder.file(n + ".xml"))
        }
        try Self.input("eight_way_select").write(to: folder.file("Copy.xml"))
        try Data("<WioDevice/>".utf8).write(to: folder.file("Broken.xml"))
        try Data("ignored".utf8).write(to: folder.file("notes.txt"))
        let issues = await store.reload()
        #expect(await store.profileNames() == ["Amp Toggle", "Eight-Way Select"])
        #expect(issues.contains { $0.file == "Broken.xml" && $0.isError })
        #expect(issues.contains { $0.file == "eight_way_select.xml" && !$0.isError }) // duplicate devicename
        #expect(await store.profile(named: "Amp Toggle")?.displayType == .bank)
        let url = try await store.save(Self.virtualModel, fileName: "Virtual")
        #expect(url.lastPathComponent == "Virtual.xml")
        #expect(await store.profile(named: "Virtual & Co") == Self.virtualModel)
    }
}
