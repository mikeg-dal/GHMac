import Testing
import Foundation
import Carbon.HIToolbox
import CoreGraphics
@testable import GHEClientKit

@Suite struct KeyNameVectorTests {
    @Test func tvK1() { #expect(KeyName(keyCode: UInt16(kVK_F5), carbonModifiers: 0)?.legacyString == "F5") }
    @Test func tvK2() {
        #expect(KeyName(keyCode: UInt16(kVK_ANSI_Keypad1), carbonModifiers: UInt32(controlKey))?.legacyString == "CTRL-NumPad1")
    }
    @Test func tvK3() { #expect(KeyName(keyCode: UInt16(kVK_ANSI_F), carbonModifiers: UInt32(optionKey))?.legacyString == "ALT-F") }
    /// Mac extension: several modifiers.
    @Test func tvK4() {
        #expect(KeyName(keyCode: UInt16(kVK_F5), carbonModifiers: UInt32(controlKey | shiftKey))?.legacyString == "CTRL-SHIFT-F5")
        #expect(KeyName(keyCode: UInt16(kVK_F5), cgFlags: [.maskControl, .maskShift])?.legacyString == "CTRL-SHIFT-F5")
    }
    @Test func tvK5() { #expect(HotkeyRegistration.evaluate(KeyName(base: "A")) == .invalid(KeyName(base: "A"))) }
    @Test func tvK6() {
        #expect(HotkeyRegistration.evaluate(KeyName(legacy: "SHIFT-A")!) == .accept(KeyName(modifiers: [.shift], base: "A")))
    }
    @Test func tvK7() { #expect(HotkeyRegistration.evaluate(KeyName(base: "Escape")) == .cancel) }
    @Test func tvK8() {
        #expect(LegacyKeyhookMessage("DEBUG:Registering (F5)") == .debug("Registering (F5)"))
        #expect(LegacyKeyhookMessage("ERROR:boom") == .error("boom"))
        #expect(LegacyKeyhookMessage("HELLO\0\0") == .hello)
        #expect(LegacyKeyhookMessage("CTRL-NumPad1") == .key(KeyName(modifiers: [.ctrl], base: "NumPad1")))
    }

    @Test func legacyParsing() {
        #expect(KeyName(legacy: "F5") == KeyName(base: "F5"))
        #expect(KeyName(legacy: "SHIFT-F13")?.legacyString == "SHIFT-F13")
        #expect(KeyName(legacy: "SHIFT-CTRL-F5")?.legacyString == "CTRL-SHIFT-F5")
        #expect(KeyName(legacy: "WIN-ALT-CTRL-SHIFT-Z")?.legacyString == "CTRL-ALT-SHIFT-WIN-Z")
        #expect(KeyName(legacy: "CTRL-Prior")?.legacyString == "CTRL-PageUp")
        #expect(KeyName(legacy: "CTRL") == KeyName(base: "CTRL"))
        #expect(KeyName(legacy: "") == nil)
        #expect(KeyName(legacy: "CTRL-") == nil)
    }

    @Test func validity() {
        for k in ["F1", "F24", "NumPad0", "Add", "Decimal", "MediaNextTrack", "BrowserStop", "CTRL-A", "ALT-F", "WIN-Z", "SHIFT-D1"] {
            #expect(KeyName(legacy: k)!.isValidHotkey, "\(k)")
        }
        for k in ["A", "D1", "Space", "Left", "Escape"] {
            #expect(!KeyName(legacy: k)!.isValidHotkey, "\(k)")
        }
        #expect(KeyName(legacy: "ALT-F")!.isOptionOnlyCombination)
        #expect(KeyName(legacy: "ALT-SHIFT-F")!.isOptionOnlyCombination)
        #expect(!KeyName(legacy: "CTRL-ALT-F")!.isOptionOnlyCombination)
        #expect(!KeyName(legacy: "SHIFT-F")!.isOptionOnlyCombination)
        #expect(KeyName(legacy: "CTRL-SHIFT-NumPad5")!.caption == "Ct-Sh-Num5")
    }
}

@Suite struct KeyCodeTableTests {
    @Test func roundTrips() {
        #expect(KeyCodeTable.codes.count == 26 + 10 + 20 + 10 + 5 + 4 + 4 + 3 + 4)
        for (name, code) in KeyCodeTable.codes {
            #expect(KeyCodeTable.name(for: code) == name, "\(name)")
            #expect(KeyCodeTable.keyCode(for: name) == code)
        }
        #expect(Set(KeyCodeTable.codes.values).count == KeyCodeTable.codes.count)   // no duplicate codes
        #expect(KeyCodeTable.keyCode(for: "Next") == UInt16(kVK_PageDown))
        #expect(KeyCodeTable.name(for: UInt16(kVK_ANSI_KeypadEnter)) == "Return")
        #expect(KeyCodeTable.keyCode(for: "F12") == UInt16(kVK_F12))
        #expect(KeyCodeTable.keyCode(for: "D7") == UInt16(kVK_ANSI_7))
        #expect(KeyCodeTable.keyCode(for: "Insert") == UInt16(kVK_Help))
    }

    @Test func unsupported() {
        for k in ["F21", "F24", "MediaNextTrack", "VolumeUp", "BrowserBack", "LaunchMail", "SelectMedia"] {
            #expect(KeyCodeTable.isUnsupported(k), "\(k)")
        }
        #expect(!KeyCodeTable.isUnsupported("F20"))
        #expect(KeyCodeTable.isUnsupported("NoSuchKey"))
    }

    @Test func modifiers() {
        let all: Set<KeyModifier> = [.ctrl, .alt, .shift, .win]
        #expect(KeyCodeTable.modifiers(carbon: KeyCodeTable.carbonModifiers(all)) == all)
        #expect(KeyCodeTable.carbonModifiers([.win]) == UInt32(cmdKey))
        #expect(KeyCodeTable.carbonModifiers([.alt]) == UInt32(optionKey))
        #expect(KeyCodeTable.modifiers(cgFlags: [.maskCommand, .maskAlternate]) == [.win, .alt])
    }
}

@Suite struct HotkeyBindingsTests {
    let item = ItemKey(server: ServerID(host: "10.0.0.2", port: 17220), name: "Tribander")

    @Test func oneTargetOneKeyOneKeyManyTargets() {
        var b = HotkeyBindings()
        let t1 = HotkeyTarget.rotor(item, .executeTurn)
        let t2 = HotkeyTarget.stack(name: "Stack1")
        b.bind(t1, to: KeyName(base: "F5"))
        b.bind(t2, to: KeyName(base: "F5"))
        #expect(b.targets(for: KeyName(base: "F5")).count == 2)
        b.bind(t1, to: KeyName(legacy: "CTRL-F6")!)
        #expect(b.targets(for: KeyName(base: "F5")) == [t2])
        #expect(b.key(for: t1) == KeyName(legacy: "CTRL-F6"))
        b.unbind(t2)
        #expect(b.keys == [KeyName(legacy: "CTRL-F6")!])
    }

    @Test func jsonRoundTrip() throws {
        var b = HotkeyBindings()
        b.bind(.rotor(item, .jogCW), to: KeyName(legacy: "CTRL-SHIFT-F5")!)
        b.bind(.switchPosition(item, HotkeyTarget.cycleForward), to: KeyName(base: "Add"))
        b.bind(.switchPosition(panel: "Ant\u{1E}:17220", host: nil, position: "Yagi"), to: KeyName(base: "NumPad1"))
        b.bind(.stack(name: "S"), to: KeyName(base: "NumPad1"))
        let data = try b.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""CTRL-SHIFT-F5""#))
        #expect(text.contains(#""cmd" : "JOG_CW""#))
        #expect(text.contains(#""type" : "switch""#))
        #expect(try HotkeyBindings.fromJSON(data) == b)
    }

    @Test func targetMatchesItem() {
        #expect(HotkeyTarget.rotor(item, .executeStop).refers(to: item))
        #expect(HotkeyTarget.rotor(panel: item.legacyKey, host: nil, command: .executeStop).refers(to: item))
        let other = ItemKey(server: ServerID(host: "10.0.0.3", port: 17220), name: "Tribander")
        #expect(!HotkeyTarget.rotor(item, .executeStop).refers(to: other))
    }
}

@MainActor
@Suite struct HotkeyEngineTests {
    let item = ItemKey(server: ServerID(host: "h", port: 1), name: "R")

    @Test func dispatchAndRegistration() throws {
        let backend = InMemoryHotkeyBackend()
        let engine = HotkeyEngine(backend: backend)
        var fired: [HotkeyTarget] = []
        engine.onAction = { t, _ in fired.append(t) }
        #expect(try engine.bind(KeyName(base: "A"), to: .stack(name: "S")) == .invalid(KeyName(base: "A")))
        #expect(try engine.bind(KeyName(base: "Escape"), to: .stack(name: "S")) == .cancel)
        #expect(backend.registered.isEmpty)
        try engine.bind(KeyName(legacy: "SHIFT-CTRL-F5")!, to: .rotor(item, .executeTurn))
        #expect(backend.registered == [KeyName(legacy: "CTRL-SHIFT-F5")!])
        backend.press(KeyName(legacy: "CTRL-SHIFT-F5")!)
        #expect(fired == [.rotor(item, .executeTurn)])
        backend.press(KeyName(base: "F6"))   // not registered
        #expect(fired.count == 1)

        engine.isTargetAvailable = { _ in false }
        backend.press(KeyName(legacy: "CTRL-SHIFT-F5")!)
        #expect(fired.count == 1)
        engine.isTargetAvailable = nil

        engine.suspend()
        #expect(backend.registered.isEmpty)
        engine.resume()
        #expect(backend.registered.count == 1)
        engine.clear()
        #expect(backend.registered.isEmpty && engine.bindings.isEmpty)
    }

    @Test func refusedKeyIsRolledBack() {
        let backend = InMemoryHotkeyBackend()
        let k = KeyName(legacy: "ALT-F")!
        backend.refuse[k] = .optionOnlyCombination("ALT-F")
        let engine = HotkeyEngine(backend: backend)
        #expect(throws: HotkeyError.optionOnlyCombination("ALT-F")) {
            try engine.bind(k, to: .stack(name: "S"))
        }
        #expect(engine.bindings.isEmpty)
    }

    @Test func loadedUnsupportedKeysAreReported() {
        let backend = InMemoryHotkeyBackend()
        backend.refuse[KeyName(base: "MediaNextTrack")] = .unsupportedKey("MediaNextTrack")
        var b = HotkeyBindings()
        b.bind(.stack(name: "S"), to: KeyName(base: "MediaNextTrack"))
        b.bind(.stack(name: "T"), to: KeyName(base: "F5"))
        let engine = HotkeyEngine(backend: backend, bindings: b)
        #expect(engine.failures.keys.map(\.legacyString) == ["MediaNextTrack"])
        #expect(backend.registered == [KeyName(base: "F5")])
    }

    @Test func so2rFocusFilter() throws {
        let backend = InMemoryHotkeyBackend()
        let engine = HotkeyEngine(backend: backend)
        var count = 0
        engine.onAction = { _, _ in count += 1 }
        let tracker = ActiveRadioTracker()
        engine.so2rGate = SO2RGate(thisRadio: 2, tracker: tracker)
        try engine.bind(KeyName(base: "F5"), to: .stack(name: "S"))
        backend.press(KeyName(base: "F5")); #expect(count == 1)   // unknown focus → accept
        tracker.set(1)
        backend.press(KeyName(base: "F5")); #expect(count == 1)
        tracker.set(2)
        backend.press(KeyName(base: "F5")); #expect(count == 2)
    }

    @Test func carbonBackendValidation() {
        #expect(throws: HotkeyError.optionOnlyCombination("ALT-F")) { try CarbonHotkeyBackend.validate(KeyName(legacy: "ALT-F")!) }
        #expect(throws: HotkeyError.optionOnlyCombination("ALT-SHIFT-F5")) { try CarbonHotkeyBackend.validate(KeyName(legacy: "ALT-SHIFT-F5")!) }
        #expect(throws: HotkeyError.unsupportedKey("F21")) { try CarbonHotkeyBackend.validate(KeyName(base: "F21")) }
        #expect(throws: HotkeyError.unknownKey("Foo")) { try CarbonHotkeyBackend.validate(KeyName(base: "Foo")) }
        #expect((try? CarbonHotkeyBackend.validate(KeyName(legacy: "CTRL-ALT-F")!)) == UInt16(kVK_ANSI_F))
        let b = CarbonHotkeyBackend()
        #expect(throws: HotkeyError.self) { try b.register(KeyName(legacy: "ALT-F")!) }
        #expect(b.registeredKeys.isEmpty)
    }

    @Test func eventTapMatching() throws {
        let reg: Set<KeyName> = [KeyName(legacy: "ALT-F")!]
        #expect(EventTapHotkeyBackend.match(keyCode: UInt16(kVK_ANSI_F), flags: .maskAlternate, registered: reg) == KeyName(legacy: "ALT-F"))
        #expect(EventTapHotkeyBackend.match(keyCode: UInt16(kVK_ANSI_F), flags: [], registered: reg) == nil)
        let tap = EventTapHotkeyBackend()
        try tap.register(KeyName(legacy: "ALT-F")!)   // Option-only is fine for the tap
        #expect(tap.registered.count == 1)
        _ = EventTapHotkeyBackend.isTrusted   // must not crash or prompt
        #expect(!tap.isRunning)
    }
}
