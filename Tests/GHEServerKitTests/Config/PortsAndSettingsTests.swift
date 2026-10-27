import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

@Suite struct PortsIniTests {
    @Test func escapedAndBareColonsMakeTCPPorts() {
        let ini = PortsIni.parse(Data("""
        #Example of RT-21 on remote terminal server:
        RT21-NET=192.168.70.13\\:6555
        Bare=10.0.0.2:4001
        RemoteAntenna=base.local\\:9000
        V6=[fe80::1]\\:23
        COMX=COM5
        Bad=10.0.0.3\\:70000
        Path=/dev/cu.usbserial-R1
        """.utf8))
        #expect(ini.portNames == ["RT21-NET", "Bare", "RemoteAntenna", "V6", "COMX", "Bad", "Path"])
        #expect(ini.tcpTarget(for: "RT21-NET")! == ("192.168.70.13", 6555))
        #expect(ini.tcpTarget(for: "Bare")! == ("10.0.0.2", 4001))
        #expect(ini.tcpTarget(for: "RemoteAntenna")! == ("base.local", 9000))
        #expect(ini.tcpTarget(for: "V6")! == ("fe80::1", 23))
        #expect(ini.tcpTarget(for: "COMX") == nil)
        #expect(ini.tcpTarget(for: "Bad") == nil)
        #expect(ini.serialAlias(for: "Path") == "/dev/cu.usbserial-R1")
    }

    @Test func hostPortParsing() {
        #expect(PortsIni.parseHostPort("  h:1 ")! == ("h", 1))
        #expect(PortsIni.parseHostPort("h:0") == nil)
        #expect(PortsIni.parseHostPort(":80") == nil)
        #expect(PortsIni.parseHostPort("h:") == nil)
        #expect(PortsIni.parseHostPort("a b:80") == nil)
        #expect(PortsIni.parseHostPort("fe80::1:80") == nil)
        #expect(PortsIni.parseHostPort("COM5") == nil)
    }

    @Test func commentOnlyFileHasNoKeys() throws {
        let data = try Fixtures.data("server/input/extra_ports_comments_only.ini")
        #expect(PortsIni.parse(data).portNames.isEmpty)
    }

    @Test func saveWritesEscapedColon() throws {
        let dirs = AppDirectories.temporary(prefix: "test-ports")
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        var ini = PortsIni()
        ini.properties["RT21-NET"] = "192.168.70.13:6555"
        try ini.save(to: dirs)
        let text = try String(contentsOf: dirs.file(PortsIni.fileName), encoding: .isoLatin1)
        #expect(text.hasPrefix("#File stores additional ports used in device manager\n#"))
        #expect(text.contains("RT21-NET=192.168.70.13\\:6555\n"))
        #expect(PortsIni.load(from: dirs).tcpTarget(for: "RT21-NET")! == ("192.168.70.13", 6555))
    }
}

@Suite struct ServerPortResolverTests {
    static func resolver() -> ServerPortResolver {
        ServerPortResolver(
            ports: PortsIni.parse(Data("RT21-NET=192.168.70.13\\:6555\nRemoteAntenna=10.0.0.9\\:9000\nCOMX=x\nAlias=/dev/cu.alias\n".utf8)),
            extraNames: ["COM5", "RT21-NET", ""],
            simulated: [(name: "SIM RT-21", id: "rt21-1")],
            serialPorts: { ["/dev/cu.usbserial-A1", "/dev/cu.Bluetooth"] })
    }

    @Test func portListOrderAndDeduplication() {
        #expect(Self.resolver().portNames() == [
            "N/A", "/dev/cu.usbserial-A1", "/dev/cu.Bluetooth", "RT21-NET", "RemoteAntenna", "COMX", "Alias",
            "COM5", "SIM RT-21",
        ])
    }

    @Test func endpoints() {
        let r = Self.resolver()
        let s = SerialSettings.rotor
        #expect(r.endpoint(for: "RT21-NET", settings: s) == .tcp(host: "192.168.70.13", port: 6555))
        #expect(r.endpoint(for: "*RT21-NET*", settings: s) == .tcp(host: "192.168.70.13", port: 6555))
        #expect(r.endpoint(for: "RemoteAntenna", settings: .wioBase) == .tcp(host: "10.0.0.9", port: 9000))
        #expect(r.endpoint(for: "SIM RT-21", settings: s) == .simulated(id: "rt21-1"))
        #expect(r.endpoint(for: "/dev/cu.usbserial-A1", settings: s) == .serial(path: "/dev/cu.usbserial-A1", s))
        #expect(r.endpoint(for: "usbserial-A1", settings: s) == .serial(path: "/dev/cu.usbserial-A1", s))
        #expect(r.endpoint(for: "cu.usbserial-A1", settings: .wioBase) == .serial(path: "/dev/cu.usbserial-A1", .wioBase))
        #expect(r.endpoint(for: "/dev/cu.gone", settings: s) == .serial(path: "/dev/cu.gone", s))
        #expect(r.endpoint(for: "Alias", settings: s) == .serial(path: "/dev/cu.alias", s))
        #expect(r.endpoint(for: "N/A", settings: s) == nil)
        #expect(r.endpoint(for: "", settings: s) == nil)
        #expect(r.endpoint(for: "COM5", settings: s) == nil)
        #expect(r.endpoint(for: "COMX", settings: s) == nil)
    }

    @Test func updatesTakeEffect() {
        let r = Self.resolver()
        r.update(ports: PortsIni())
        r.update(simulated: [])
        #expect(r.endpoint(for: "RT21-NET", settings: .rotor) == nil)
        #expect(!r.portNames().contains("SIM RT-21"))
    }
}

@Suite struct ServerSettingsTests {
    @Test func defaultsFileAndDefaults() throws {
        let data = try Fixtures.data("server/input/server_settings_defaults.ini")
        let s = ServerSettings.parse(data)
        #expect(s.port == 17220 && s.maxConnections == 4 && s.lat == 0 && s.lon == 0)
        #expect(!s.authenticate && !s.serverLogging && !s.rotorUiVisible && !s.serverMinimized)
        #expect(s.serverWindowWidth == 500 && s.serverWindowHeight == 200 && s.serverWindowX == 0 && s.serverWindowY == 0)
        #expect(ServerSettings.parse(Data()) == ServerSettings(properties: JavaProperties()))
    }

    @Test func valuesBadValuesAndUnknownKeys() {
        let s = ServerSettings.parse(Data("""
        #Settings for server UI
        custom=keep me
        port=0
        maxConnections=x
        lat=42.5
        lon=-71.25
        authenticate=TRUE
        serverWindowX=-20
        """.utf8))
        #expect(s.port == 17220)          // never 0
        #expect(s.maxConnections == 4)
        #expect(s.lat == 42.5 && s.lon == -71.25)
        #expect(s.authenticate)
        #expect(s.serverWindowX == -20)
        let p = s.properties
        #expect(p["custom"] == "keep me")
        #expect(p.keys.first == "custom")
        #expect(p["lat"] == "42.5")
        #expect(p["port"] == "17220")
        #expect(p["serverMinimized"] == "false")
    }

    @Test func saveCreatesFolderAndRoundTrips() throws {
        let base = AppDirectories.temporary(prefix: "test-settings")
        defer { try? FileManager.default.removeItem(at: base.root) }
        let dirs = AppDirectories(root: base.root.appendingPathComponent("missing/GHMac Server"))
        var s = ServerSettings.load(from: dirs)
        #expect(FileManager.default.fileExists(atPath: dirs.root.path))
        #expect(s.port == 17220)
        s.authenticate = true
        s.maxConnections = 10
        s.document["extra"] = "1"
        try s.save(to: dirs)
        let text = try String(contentsOf: dirs.file(ServerSettings.fileName), encoding: .isoLatin1)
        #expect(text.hasPrefix("#Settings for server UI\n#"))
        let back = ServerSettings.load(from: dirs)
        #expect(back.authenticate && back.maxConnections == 10)
        #expect(back.document["extra"] == "1")
    }
}

@Suite struct SwitchStateStoreTests {
    @Test func fileNamesAreURLEncoded() {
        #expect(SwitchStateStore.fileName(forSwitch: "Ant Switch") == "switchstateAnt+Switch.properties")
        #expect(SwitchStateStore.fileName(forSwitch: "A/B é") == "switchstateA%2FB+%C3%A9.properties")
        #expect(SwitchStateStore.fileName(forSwitch: "x.y-z_*") == "switchstatex.y-z_*.properties")
    }

    @Test func saveLoadAndJavaWrittenFiles() async throws {
        let dirs = AppDirectories.temporary(prefix: "test-switch")
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let store = SwitchStateStore(directory: dirs)
        #expect(await store.loadState(forSwitch: "Ant Switch") == nil)
        await store.saveState("FIRST", forSwitch: "Ant Switch")
        await store.saveState("TWO", forSwitch: "Ant Switch")
        #expect(await store.loadState(forSwitch: "Ant Switch") == "TWO")
        let text = try String(contentsOf: dirs.file("switchstateAnt+Switch.properties"), encoding: .isoLatin1)
        #expect(text.hasPrefix("#\n#"))
        #expect(text.hasSuffix("Ant\\ Switch=TWO\n"))
        // An existing file (bank state).
        try Data("#\r\n#Sun Mar 11 08:14:06 EDT 2018\r\nPreamp\\ Bank=PREAMP,ATT\r\n".utf8)
            .write(to: dirs.file("switchstatePreamp+Bank.properties"))
        #expect(await store.loadState(forSwitch: "Preamp Bank") == "PREAMP,ATT")
        #expect(await store.savedSwitchNames() == ["Ant Switch", "Preamp Bank"])
    }
}
