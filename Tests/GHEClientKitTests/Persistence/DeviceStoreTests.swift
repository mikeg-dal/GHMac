import Foundation
import Testing
import GHEKit
@testable import GHEClientKit

@Suite("per-device ini files")
struct DeviceStoreTests {
    private let tower = PersistenceFixtures.tower

    private func tempDir() -> AppDirectories { AppDirectories.temporary(prefix: "test-dev") }

    @Test("Properties output matches JDK 8 for U+001E/U+001F keys")
    func propertiesGolden() throws {
        let java = try PersistenceFixtures.data("props_device.properties")
        let p = JavaProperties.parse(java)
        #expect(p[PersistenceFixtures.tower] == "160M 80M 40M 20M 15M 10M 50 ")
        #expect(p[PersistenceFixtures.yagi] == "")
        #expect(p[PersistenceFixtures.bandSwitch + "\u{1F}20m"] == "Red")
        #expect(p["Odd key=:#! x"] == "value with \\ backslash and  spaces ")
        let swift = p.serialized(comment: "File stores rotor names and bands for tray display:")
        #expect(PersistenceFixtures.bodyLines(swift) == PersistenceFixtures.bodyLines(java))
        let text = String(decoding: swift, as: UTF8.self)
        #expect(text.contains("Tower\\ 40m\\u001E\\:17220=160M 80M 40M 20M 15M 10M 50 \n"))
    }

    @Test("rotor colours: Integer.toString(argb,16) incl. negative hex (JDK 8 golden)")
    func colors() throws {
        let lines = String(decoding: try PersistenceFixtures.data("colors.txt"), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 7)
        for line in lines {
            let f = line.split(separator: " ").map(String.init)
            let rgb = try #require(UInt32(f[0], radix: 16))
            #expect(LegacyColorCodec.encode(rgb) == f[1])
            #expect(LegacyColorCodec.decode(f[1]) == UInt32(f[2], radix: 16))
        }
        #expect(LegacyColorCodec.encode(nil) == "default")
        #expect(LegacyColorCodec.decode("default") == nil)
        #expect(LegacyColorCodec.decode("null") == nil)
        #expect(LegacyColorCodec.decode("") == nil)
        #expect(LegacyColorCodec.decode("zz") == nil)
        #expect(LegacyColorCodec.decode("ff8000") == 0xFF8000)
    }

    @Test("band list format: tokens with trailing space")
    func bandList() {
        #expect(LegacyBandList.encode(["160M", "50"]) == "160M 50 ")
        #expect(LegacyBandList.decode("Rotor 40M 20M All Order ") == ["Rotor", "40M", "20M", "All", "Order"])
        #expect(LegacyBandList.decode("") == [])
        #expect(LegacyBandList.bands(in: ["Rotor", "20M", "50", "All"]) == [.m20, .m6])
        #expect(LegacyBandList.hfUnionVHF.count == 25)
    }

    @Test("rotor defaults when files are missing / keys are missing")
    func rotorDefaults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let store = RotorDeviceStore(directory: dir, randomPriority: { 321 })
        let s = store.load(key: tower, scope: .hfContest)
        #expect(s.trayBands == LegacyBandList.hfUnionVHF)
        #expect(s.mapBands == LegacyBandList.hfUnionVHF)
        #expect(s.active == false)
        #expect(s.priority == 321)
        #expect(s.mapPriority == 321)
        #expect(s.beamWidth == 35)
        #expect(s.color == nil)

        // Files exist but hold another rotor only.
        try store.save(key: "Other\u{1E}:1", s)
        let t = store.load(key: tower, scope: .vhf)
        #expect(t.trayBands == LegacyBandList.vhfArray)
        #expect(t.mapBands == [])
        // The default random range is 100…600.
        let real = RotorDeviceStore(directory: dir)
        for _ in 0..<50 { #expect((100...600).contains(real.load(key: "New\u{1E}:2", scope: .hfAll).priority)) }
    }

    @Test("rotor save/load round trip and file contents")
    func rotorRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let store = RotorDeviceStore(directory: dir, randomPriority: { 100 })
        let item = ItemKey(server: ServerID(host: "10.0.0.1", port: 17220), name: "Tower 40m")
        #expect(item.legacyKey == tower)
        let s = RotorDeviceSettings(trayBands: ["160M", "20M"], mapBands: ["20M"], active: true, priority: 5,
                                    mapPriority: 9, beamWidth: 60, color: 0x00FF00)
        try store.save(item, s)
        #expect(store.load(item, scope: .hfContest) == s)
        let bands = String(decoding: try Data(contentsOf: dir.file("rotorbands.ini")), as: UTF8.self)
        #expect(bands.hasPrefix("#File stores rotor names and bands for tray display:\n#"))
        #expect(bands.contains("Tower\\ 40m\\u001E\\:17220=160M 20M \n"))
        let colors = String(decoding: try Data(contentsOf: dir.file("rotorcolors.ini")), as: UTF8.self)
        #expect(colors.contains("=-ff0100\n"))
        #expect(MisnamedPropertiesFile.exactNames(in: dir).contains("mappriority.ini"))
        // loadOrCreate persists the defaults.
        _ = try store.loadOrCreate(key: "Fresh\u{1E}:3", scope: .hfAll)
        #expect(PropertiesFile(dir, "rotorpriority.ini", comment: nil).read()?["Fresh\u{1E}:3"] == "100")
    }

    @Test("map priority read from mapPriority.ini, written to mappriority.ini")
    func mapPriorityDualRead() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        var legacy = JavaProperties()
        legacy[tower] = "7"
        try PropertiesFile(dir, "mapPriority.ini", comment: "x").write(legacy)
        let store = RotorDeviceStore(directory: dir, randomPriority: { 200 })
        var s = store.load(key: tower, scope: .hfContest)
        #expect(s.mapPriority == 7)
        s.mapPriority = 8
        try store.save(key: tower, s)
        let names = MisnamedPropertiesFile.exactNames(in: dir)
        #expect(names.contains("mappriority.ini"))
        #expect(!names.contains("mapPriority.ini"))
        #expect(store.load(key: tower, scope: .hfContest).mapPriority == 8)
    }

    @Test("switch status read from switchtatus.ini too, written to switchstatus.ini")
    func switchStatusDualRead() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let sw = PersistenceFixtures.bandSwitch
        var stale = JavaProperties(); stale[sw] = "false"
        try PropertiesFile(dir, "switchstatus.ini", comment: nil).write(stale)
        var real = JavaProperties(); real[sw] = "true"
        try PropertiesFile(dir, "switchtatus.ini", comment: nil).write(real)
        let store = SwitchDeviceStore(directory: dir, randomPriority: { 150 })
        var s = store.load(key: sw, scope: .hfAll)
        #expect(s.active == true) // the misspelled file wins
        #expect(s.priority == 150)
        #expect(s.bands == LegacyBandList.hfUnionVHF)
        s.active = false
        s.bands = ["20M", "40M"]
        try store.save(key: sw, s)
        let names = MisnamedPropertiesFile.exactNames(in: dir)
        #expect(names.contains("switchstatus.ini") && !names.contains("switchtatus.ini"))
        #expect(store.load(key: sw, scope: .hfAll) == s)
    }

    @Test("button colours saved on every change")
    func buttonColors() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let store = ButtonColorStore(directory: dir)
        let sw = PersistenceFixtures.bandSwitch
        try store.set(.orange, switchKey: sw, position: "20m")
        try store.set(.black, switchKey: sw, position: "40m")
        #expect(store.color(switchKey: sw, position: "20m") == .orange)
        let text = String(decoding: try Data(contentsOf: dir.file("buttoncolors.ini")), as: UTF8.self)
        #expect(text.hasPrefix("#File stores Switch Button Colors\n"))
        #expect(text.contains("Band\\ SW\\u001E\\:17220\\u001F20m=Orange\n"))
        try store.set(nil, switchKey: sw, position: "20m")
        #expect(store.load() == [ButtonColorStore.key(switchKey: sw, position: "40m"): .black])
        try PropertiesFile(dir, "buttoncolors.ini", comment: nil).update { $0["x"] = "Purple" }
        #expect(store.load().count == 1)
    }

    @Test("rotor map window and visibility")
    func rotorMap() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let store = RotorMapStore(directory: dir)
        #expect(store.load() == RotorMapSettings(background: nil, x: 0, y: 0, width: 500, height: 440))
        #expect(store.isVisible(shortName: "Tower"))
        try store.save(RotorMapSettings(background: "/tmp/m.png", x: 1, y: 2, width: 3, height: 4))
        try store.setVisible(false, shortName: "Tower")
        #expect(store.load() == RotorMapSettings(background: "/tmp/m.png", x: 1, y: 2, width: 3, height: 4))
        #expect(!store.isVisible(shortName: "Tower"))
        #expect(store.visibility() == ["Tower": false])
    }
}
