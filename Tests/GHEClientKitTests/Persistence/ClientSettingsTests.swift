import Foundation
import Testing
import Synchronization
import GHEKit
@testable import GHEClientKit

@Suite("settings.ini")
struct ClientSettingsTests {
    @Test("on-load defaults")
    func defaults() {
        let s = ClientSettings(properties: JavaProperties())
        #expect(s == ClientSettings.defaults)
        #expect(s.switchButtonColor == .green)
        #expect(s.fastExit == false)
        #expect(s.loggerSource == .manual) // `manual` defaults to true
        #expect(s.globalPresetsVisible == false)
        #expect(s.bandA == "ALL" && s.bandB == "ALL")
        #expect(s.x == 0 && s.y == 0)
        #expect(s.touchScreen == false && s.alwaysOnTop == false && s.loggingFocus == false)
        #expect(s.showDropOnSwitches == true)
        #expect(s.rotorDisplaySize == .medium)
        #expect(s.switchDisplaySize == .small)
        #expect(s.presetEntryWidth == 400 && s.presetEntryHeight == 400)
        #expect(s.presetFontSize == 18)
        #expect(s.rotorMapFrameVisible == false)
        #expect(s.rotorStepSize == 10)
        #expect(s.showHotkeysOnButtons == true)
        #expect(s.bandScope == .hfContest)
        #expect(s.savePasswords == false)
        #expect(s.n1mm == N1MMConfig(radioPort: 12060, rotorPort: 12045, selectedVFO: 1))
        #expect(s.n3fjp == N3FJPConfig(host: "127.0.0.1", port: 1100))
        #expect(s.winTest == WinTestConfig(port: 9871, bind: .network, filter: WinTestFilter()))
        #expect(s.winTestCustomIPAddress == "")
    }

    private func props(_ pairs: [String: String]) -> JavaProperties {
        var p = JavaProperties()
        for (k, v) in pairs.sorted(by: { $0.key < $1.key }) { p[k] = v }
        return p
    }

    @Test("load quirks: radio-button group, switchDisplaySize 0, bandB reset, bandsScope strings")
    func quirks() {
        #expect(ClientSettings(properties: props(["wintest": "true", "manual": "false"])).loggerSource == .wintest)
        // Replicated: a missing `manual` key defaults to true and wins over an earlier true mode.
        #expect(ClientSettings(properties: props(["n1mm": "true"])).loggerSource == .manual)
        #expect(ClientSettings(properties: props(["n1mm": "TRUE", "manual": "false"])).loggerSource == .n1mm)
        #expect(ClientSettings(properties: props(["n1mm": "false", "manual": "false"])).loggerSource == .manual)
        #expect(ClientSettings(properties: props(["switchDisplaySize": "0"])).switchDisplaySize == .small)
        #expect(ClientSettings(properties: props(["switchDisplaySize": "12"])).switchDisplaySize == .large)
        #expect(ClientSettings(properties: props(["rotorDisplaySize": "0"])).rotorDisplaySize == .small)
        #expect(ClientSettings(properties: props(["rotorDisplaySize": "junk"])).rotorDisplaySize == .medium)
        #expect(ClientSettings(properties: props(["bandB": "20M", "bandA": "40M"])).bandB == "ALL")
        #expect(ClientSettings(properties: props(["bandA": "40M"])).bandA == "40M")
        #expect(ClientSettings(properties: props(["bandsScope": "HF Contest"])).bandScope == .hfContest)
        #expect(ClientSettings(properties: props(["bandsScope": "hfall"])).bandScope == .hfAll)
        #expect(ClientSettings(properties: props(["bandsScope": "vhf"])).bandScope == .vhf)
        #expect(ClientSettings(properties: props(["SwitchButtonColor": "Purple"])).switchButtonColor == .green)
        #expect(ClientSettings(properties: props(["radioPort": "99999"])).n1mm.radioPort == 12060)
        let w = ClientSettings(properties: props(["wintestLoopbackRadioButton": "true", "wintestCustomIPAddress": "1.2.3.4"]))
        #expect(w.winTest.bind == .loopback)
        #expect(w.winTestCustomIPAddress == "1.2.3.4")
    }

    @Test("write uses the legacy key spellings and round-trips")
    func roundTrip() {
        var s = ClientSettings()
        s.switchButtonColor = .cyan
        s.loggerSource = .n3fjp
        s.bandA = "15M"; s.bandB = "20M"
        s.x = -40; s.y = 900
        s.loggingFocus = true
        s.rotorDisplaySize = .large
        s.switchDisplaySize = .medium
        s.presetFontSize = 30
        s.rotorStepSize = 3
        s.bandScope = .vhf
        s.savePasswords = true
        s.n1mm = N1MMConfig(radioPort: 12061, rotorPort: 12046, selectedVFO: 3)
        s.n3fjp = N3FJPConfig(host: "10.1.1.1", port: 1101)
        s.winTest = WinTestConfig(port: 9000, bind: .custom("192.168.0.9"),
                                  filter: WinTestFilter(selectedRadio: 2, stationFilterEnabled: true, stationName: "RUN"))
        s.winTestCustomIPAddress = "192.168.0.9"
        var p = JavaProperties()
        s.write(into: &p)
        #expect(p["logginFocus"] == "true")
        #expect(p["touchScreen"] == "false")
        #expect(p["n3fjp"] == "true" && p["manual"] == "false")
        #expect(p["switchDisplaySize"] == "11")
        #expect(p["bandsScope"] == "vhf")
        #expect(p["bandB"] == "20M")
        #expect(p["RotorPresetsFontSize"] == "30")
        #expect(p["wintestCustomRadioButton"] == "true" && p["wintestNetworkRadioButton"] == "false")
        #expect(p["wintestCustomIPAddress"] == "192.168.0.9")
        var back = ClientSettings(properties: p)
        #expect(back.bandB == "ALL")
        back.bandB = s.bandB
        #expect(back == s)
        #expect(back.winTestCustomIPAddress == "192.168.0.9")
    }

    @Test("store keeps unknown keys (load-modify-store)")
    func storeKeepsUnknownKeys() throws {
        let dir = AppDirectories.temporary(prefix: "test-settings")
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try PersistenceFixtures.write("#\n#date\nfutureKey=keep me\nx=7\n", to: dir.file("settings.ini"))
        let store = ClientSettingsStore(directory: dir)
        var s = store.load()
        #expect(s.x == 7)
        s.y = 12
        try store.save(s)
        let p = try #require(PropertiesFile(dir, "settings.ini", comment: nil).read())
        #expect(p["futureKey"] == "keep me")
        #expect(p["y"] == "12")
        let text = String(decoding: try Data(contentsOf: dir.file("settings.ini")), as: UTF8.self)
        #expect(text.hasPrefix("#\n#"))
    }

    @Test("debouncer coalesces saves on a manual clock")
    func debouncer() async {
        let clock = ManualClock()
        let count = Mutex(0)
        let d = SaveDebouncer(clock: clock, delay: .milliseconds(500)) { count.withLock { $0 += 1 } }
        d.schedule(); d.schedule()
        await clock.settle()
        await clock.advance(by: .milliseconds(300))
        d.schedule()
        await clock.settle()
        await clock.advance(by: .milliseconds(499))
        await clock.settle()
        #expect(count.withLock { $0 } == 0)
        await clock.advance(by: .milliseconds(1))
        await clock.settle()
        #expect(await eventually { count.withLock { $0 } == 1 })
        #expect(!d.hasPendingSave)
        d.schedule()
        d.flush()
        #expect(count.withLock { $0 } == 2)
        d.flush()
        #expect(count.withLock { $0 } == 2)
    }
}
