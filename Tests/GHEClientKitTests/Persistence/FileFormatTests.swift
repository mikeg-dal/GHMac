import Foundation
import Testing
import GHEKit
@testable import GHEClientKit

@Suite("server.ini, XML and JSON files")
struct FileFormatTests {

    // MARK: server.ini / rotornames.ini

    @Test("server.ini rows decode")
    func serverRows() throws {
        let p = JavaProperties.parse(try PersistenceFixtures.data("server.ini"))
        let rows = ServerRowCodec.decode(p)
        #expect(rows.count == 10)
        #expect(rows[0] == SavedServerRow(address: "192.168.1.8", port: "6555", user: "", rotorName: "",
                                          kind: .terminalServerTCP, autoConnect: true))
        #expect(rows[0].serverID == ServerID(host: "192.168.1.8", port: 6555))
        #expect(rows[3] == SavedServerRow(address: "ghserver.example", port: "17220", user: "op", kind: .ghServer))
        #expect(rows[1].isEmpty && rows[9].isEmpty && rows[1].portNumber == nil)
    }

    @Test("server.ini encode: exact keys, all 10 rows; old 5-part keys fill rows in order")
    func serverEncode() throws {
        var rows = Array(repeating: SavedServerRow(), count: 10)
        rows[2] = SavedServerRow(address: "h", port: "1", user: "u", rotorName: "R", kind: .terminalServerTCP, autoConnect: true)
        let p = ServerRowCodec.encode(rows)
        #expect(p.keys.count == 10)
        #expect(p["h\u{1F}1\u{1F}u\u{1F}R\u{1F}1\u{1F}2"] == "true")
        #expect(p["\u{1F}\u{1F}\u{1F}\u{1F}0\u{1F}0"] == "false")
        #expect(ServerRowCodec.decode(p) == rows)

        var old = JavaProperties()
        old["a\u{1F}17220\u{1F}u\u{1F}x\u{1F}0"] = "true"
        old["b\u{1F}17221\u{1F}v\u{1F}y\u{1F}1"] = "false"
        old["c\u{1F}1\u{1F}\u{1F}\u{1F}0\u{1F}42"] = "true" // out of range: ignored
        let decoded = ServerRowCodec.decode(old)
        #expect(decoded[0].address == "a" && decoded[0].autoConnect)
        #expect(decoded[1].address == "b" && decoded[1].kind == .terminalServerTCP)

        let dir = AppDirectories.temporary(prefix: "test-srv")
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let store = ServerRowStore(directory: dir)
        try store.save([rows[2]])
        #expect(store.load()[0] == rows[2])
        #expect(store.load().count == 10)
        let names = RotorNamesStore(directory: dir)
        try names.setName("Tower RT21", host: "192.168.1.8", port: 6555)
        #expect(names.name(host: "192.168.1.8", port: 6555) == "Tower RT21")
        let text = String(decoding: try Data(contentsOf: dir.file("rotornames.ini")), as: UTF8.self)
        #expect(text.contains("192.168.1.8\\:6555=Tower RT21\n"))
    }

    // MARK: XML

    @Test("presetFrames.xml round-trips byte-for-byte against JDK 8")
    func presetFrames() throws {
        let golden = try PersistenceFixtures.data("presetFrames.xml")
        let frames = PresetFramesXML.decode(golden)
        #expect(frames == [
            PresetFrameState(name: "Tower 40m preset selection", visible: true, keepVisible: true, x: 10, y: 20, width: 400, height: 400),
            PresetFrameState(name: "A&B <\"x\"> preset selection", visible: false, keepVisible: false, x: -5, y: 0, width: 300, height: 250),
            PresetFrameState(name: PresetFrameState.globalName, x: 0, y: 0, width: 400, height: 400),
        ])
        #expect(PresetFramesXML.encode(frames) == golden)
        #expect(PresetFramesXML.encode([]) == (try PersistenceFixtures.data("presetFrames_empty.xml")))
        let crlf = PresetFramesXML.encode(frames, lineEnding: "\r\n")
        #expect(PresetFramesXML.decode(crlf) == frames)
        // An empty file (CRLF, root written open/close).
        let sample = try PersistenceFixtures.data("presetFrames_open_close.xml")
        #expect(PresetFramesXML.decode(sample) == [])
        #expect(PresetFrameState.name(forRotorShortName: "Tower 40m") == "Tower 40m preset selection")
    }

    @Test("presetFrames store and phidgets.xml")
    func xmlStores() throws {
        let golden = try PersistenceFixtures.data("phidgets.xml")
        let list = PhidgetsXML.decode(golden)
        #expect(list == [PhidgetAssignment(name: "Tower 40m:17220", serial: 123456),
                         PhidgetAssignment(name: "Global preset selection", serial: 98765)])
        #expect(PhidgetsXML.encode(list) == golden)
        #expect(PhidgetsXML.decode(Data("not xml".utf8)) == [])

        let dir = AppDirectories.temporary(prefix: "test-xml")
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let frames = PresetFramesStore(directory: dir)
        #expect(frames.load() == [])
        try frames.save([PresetFrameState(name: "G", visible: true)])
        #expect(frames.frame(named: "G")?.visible == true)
        let phidgets = PhidgetAssignmentStore(directory: dir)
        try phidgets.save(list)
        #expect(phidgets.load() == list)
    }

    @Test("JSON stores round-trip")
    func jsonStores() throws {
        let dir = AppDirectories.temporary(prefix: "test-json")
        defer { try? FileManager.default.removeItem(at: dir.root) }
        let presets = PresetStore(directory: dir)
        #expect(presets.load() == [])
        let many = (0..<20).map { RotorPreset(name: "P\($0)", heading: "\($0 * 10)") } + [RotorPreset(name: "bad", heading: "x")]
        try presets.save(many)
        #expect(presets.load() == Array(many.prefix(16)))
        let hk = HotkeyStore(directory: dir)
        var b = HotkeyBindings()
        b.bind(.stack(name: "S"), to: KeyName(base: "F6"))
        try hk.save(b)
        #expect(hk.load() == b)
        let sw = SwitchWindowStore(directory: dir)
        try sw.update { $0.switches["A"] = SwitchWindowConfig(x: 1, y: 2, image: .file(path: "/x.png"), beamColor: 0x123456) }
        #expect(sw.load().switches["A"]?.image == .file(path: "/x.png"))
    }
}
