import Foundation
import Testing
@testable import GHEKit

/// Server → client lines: golden bytes for every protocol example, round trips, and the
/// client's prefix-dispatch order.
@Suite struct GHWireServerMessageTests {
    static let examples: [(ServerMessage, String)] = [
        (.user, "USER:␍␊"),
        (.pass(challenge: "0.7316931046151538-81283467123456789011665432101234"),
         "PASS:0.7316931046151538-81283467123456789011665432101234␍␊"),
        (.invalidUserPass, "INVALID USER/PASS␍␊"),
        (.close, "CLOSE␍␊"),
        (.add("Tower 40m"), "ADD␟Tower 40m␍␊"),
        (.remove("Tower 40m"), "REMOVE␟Tower 40m␍␊"),
        (.point(rotor: "Tower 40m", heading: 271, status: .ok, rssi: 0), "POINT␟Tower 40m␟271.0␟0␟0␍␊"),
        (.point(rotor: "Wio Yagi", heading: 45.3, status: .ok, rssi: -71), "POINT␟Wio Yagi␟45.3␟0␟-71␍␊"),
        (.stackAdd(["Yagi Top", "Yagi Mid", "Yagi Bot"]), "STACKADD␟Yagi Top,Yagi Mid,Yagi Bot␍␊"),
        (.stackRemove(["Yagi Top", "Yagi Mid", "Yagi Bot"]), "STACKREMOVE␟Yagi Top,Yagi Mid,Yagi Bot␍␊"),
        (.stack(names: ["Yagi Top", "Yagi Mid", "Yagi Bot"], selected: [true, false, true, false], status: 0, rssi: -64),
         "STACK␟Yagi Top,Yagi Mid,Yagi Bot␟true␟false␟true␟false␟0␟-64␍␊"),
        (.switchAdd(SwitchDescriptor(name: "6-Pack", displayType: 2, positions: [
            SwitchPosition(name: "North", heading: 0, beamwidth: 60, bidirectional: false),
            SwitchPosition(name: "Omni", heading: 0, beamwidth: 360, bidirectional: false),
        ])), "SWITCHADD␟2␟6-Pack␟North␝0␝60␝false␟Omni␝0␝360␝false␍␊"),
        (.switchAdd(SwitchDescriptor(name: "Band SW", displayType: 3, positions: [
            SwitchPosition(name: "40m", lowerMHz: 7.0, upperMHz: 7.3),
            SwitchPosition(name: "20m", lowerMHz: 14.0, upperMHz: 14.35),
        ])), "SWITCHADD␟3␟Band SW␟40m␝7.0␝7.3␟20m␝14.0␝14.35␍␊"),
        (.switchRemove("Band SW"), "SWITCHREMOVE␟Band SW␍␊"),
        (.switchUpdate(name: "Band SW", state: "20m", status: 0, rssi: -58), "SWITCHUPDATE␟Band SW␟20m␟0␟-58␍␊"),
        (.switchLocks(name: "Band SW", states: ["20m", "40m"]), "SWITCHLOCKS␟Band SW␟20m␟40m␍␊"),
        (.presetsLine(names: []), "␍␊"),
        (.presetsLine(names: ["Home", "DX"]), "LOCATIONS␟Home␟DX␍␊"),
        (.tornadoAdd(TornadoDescriptor(name: "Tuner", rotors: ["R1", "R2"], positions: ["A", "B"],
                                       lower: ["7.0", "14.0"], upper: ["7.3", "14.35"])),
         "TORNADOADD␟Tuner␟R1␝R2␟A␝B␟7.0␝14.0␟7.3␝14.35␍␊"),
        (.tornadoRemove("Tuner"), "TORNADOREMOVE␟Tuner␍␊"),
        (.tornado(TornadoState(name: "Tuner", status: 0, rssi: -60, position: "A", headings: ["90", "270"])),
         "TORNADO␟Tuner␟0␟-60␟A␟90␟270␍␊"),
    ]

    @Test func goldenBytesForSpecExamples() {
        for (message, expected) in Self.examples {
            #expect(GHWire.encode(message) == wire(expected), "\(message)")
        }
    }

    @Test func examplesRoundTrip() {
        for (message, _) in Self.examples {
            var bytes = GHWire.encode(message)
            #expect(bytes.suffix(2) == [0x0D, 0x0A])
            bytes.removeLast(2)
            #expect(GHWire.decodeServerLine(Windows1252.decode(bytes)) == message, "\(message)")
        }
    }

    @Test func encodesWindows1252AndJavaDoubles() {
        #expect(GHWire.encode(.add("Ünïcode €")) == [0x41, 0x44, 0x44, 0x1F, 0xDC, 0x6E, 0xEF, 0x63, 0x6F, 0x64, 0x65, 0x20, 0x80, 0x0D, 0x0A])
        #expect(GHWire.encode(.point(rotor: "R", heading: 0.0001, status: .error, rssi: 0)) == wire("POINT␟R␟1.0E-4␟5␟0␍␊"))
        #expect(GHWire.encode(.point(rotor: "R", heading: 359.99999999999994, status: .clone, rssi: 0))
                == wire("POINT␟R␟359.99999999999994␟8␟0␍␊"))
        // STACK always carries four flags.
        #expect(GHWire.encode(.stack(names: ["A"], selected: [true], status: 4, rssi: 0)) == wire("STACK␟A␟true␟false␟false␟false␟4␟0␍␊"))
        // Unknown display types use the heading/beamwidth form.
        #expect(GHWire.encode(.switchAdd(SwitchDescriptor(name: "X", displayType: 7, positions: [SwitchPosition(name: "p")])))
                == wire("SWITCHADD␟7␟X␟p␝0␝0␝false␍␊"))
    }

    // MARK: decode order and leniency

    @Test func pointDefaultsForLegacyServers() {
        #expect(GHWire.decodeServerLine(wireText("POINT␟R␟12.5")) == .point(rotor: "R", heading: 12.5, status: .stopped, rssi: 0))
        #expect(GHWire.decodeServerLine(wireText("POINT␟R␟12.5␟7")) == .point(rotor: "R", heading: 12.5, status: .fixed, rssi: 0))
        #expect(GHWire.decodeServerLine(wireText("POINT␟R␟ 12 ␟0␟-40")) == .point(rotor: "R", heading: 12, status: .ok, rssi: -40))
    }

    @Test func malformedNumbersAreIgnoredNotFatal() {
        for line in ["POINT␟R␟abc␟0␟0", "POINT␟R", "POINT␟R␟1␟0␟x", "POINT␟R␟1␟Z␟0", "SWITCHUPDATE␟S␟A␟x␟0",
                     "SWITCHUPDATE␟S␟A␟0", "SWITCHADD␟x␟S", "SWITCHADD␟2␟S␟N␝x␝60␝false", "SWITCHADD␟3␟S␟40m␝a␝7.3",
                     "STACK␟A␟true␟false␟true␟false␟x␟0", "STACK␟A␟true", "STACK␟,,,␟t␟t␟t␟t␟0␟0", "ADD", "TORNADO␟T␟x␟0␟A",
                     "PASS", "SWITCHLOCKS"] {
            let text = wireText(line)
            #expect(GHWire.decodeServerLine(text) == .ignored(text), "\(line)")
        }
    }

    @Test func clientDispatchOrder() {
        // STACKADD / STACKREMOVE before the generic STACK branch.
        #expect(GHWire.decodeServerLine(wireText("STACKADD␟A,B")) == .stackAdd(["A", "B"]))
        #expect(GHWire.decodeServerLine(wireText("STACKREMOVE␟A")) == .stackRemove(["A"]))
        // Anything else starting with STACK is a stack update.
        #expect(GHWire.decodeServerLine(wireText("STACKX␟A␟TRUE␟false␟true␟false␟0␟-1"))
                == .stack(names: ["A"], selected: [true, false, true, false], status: 0, rssi: -1))
        // SWITCHADD / SWITCHREMOVE before ADD / REMOVE.
        #expect(GHWire.decodeServerLine(wireText("SWITCHADD␟1␟Ant SW␟A␟B"))
                == .switchAdd(SwitchDescriptor(name: "Ant SW", displayType: 1, positions: [SwitchPosition(name: "A"), SwitchPosition(name: "B")])))
        #expect(GHWire.decodeServerLine(wireText("SWITCHREMOVE␟S")) == .switchRemove("S"))
        // TORNADOADD / TORNADOREMOVE before TORNADO.
        #expect(GHWire.decodeServerLine(wireText("TORNADOREMOVE␟T")) == .tornadoRemove("T"))
        // USER: / PASS: by prefix, INVALID by equality.
        #expect(GHWire.decodeServerLine("USER:extra") == .user)
        #expect(GHWire.decodeServerLine("PASS:a:b") == .pass(challenge: "a:b"))
        #expect(GHWire.decodeServerLine("PASS:") == .pass(challenge: ""))
        #expect(GHWire.decodeServerLine("INVALID USER/PASS ") == .ignored("INVALID USER/PASS "))
        // CLOSE by prefix, SERVER_FULL ignored, unknown ignored.
        #expect(GHWire.decodeServerLine("CLOSED") == .close)
        #expect(GHWire.decodeServerLine("SERVER_FULL") == .ignored("SERVER_FULL"))
        #expect(GHWire.decodeServerLine("POPUP\u{1F}hi") == .ignored("POPUP\u{1F}hi"))
        #expect(GHWire.decodeServerLine("HELLO") == .ignored("HELLO"))
        // Empty line = presets line; LOCATIONS alone = no names.
        #expect(GHWire.decodeServerLine("") == .presetsLine(names: []))
        #expect(GHWire.decodeServerLine("LOCATIONS") == .presetsLine(names: []))
    }

    @Test func javaSplitDropsTrailingEmptyFields() {
        #expect(GHWire.decodeServerLine(wireText("SWITCHLOCKS␟SW␟20m␟␟")) == .switchLocks(name: "SW", states: ["20m"]))
        #expect(GHWire.decodeServerLine(wireText("SWITCHLOCKS␟SW␟␟40m")) == .switchLocks(name: "SW", states: ["", "40m"]))
        #expect(GHWire.decodeServerLine(wireText("SWITCHUPDATE␟Bank␟A,B␟0␟0"))
                == .switchUpdate(name: "Bank", state: "A,B", status: 0, rssi: 0))
    }

    @Test func switchAddSubfieldsAndNameGroupSplit() {
        // The switch name is cut at the first GS.
        #expect(GHWire.decodeServerLine(wireText("SWITCHADD␟4␟Bank␝junk␟Amp␝0␝0␝false␟Pre"))
                == .switchAdd(SwitchDescriptor(name: "Bank", displayType: 4, positions: [SwitchPosition(name: "Amp"), SwitchPosition(name: "Pre")])))
        #expect(GHWire.decodeServerLine(wireText("SWITCHADD␟2␟Map␟NE␝45␝60␝TRUE"))
                == .switchAdd(SwitchDescriptor(name: "Map", displayType: 2,
                                               positions: [SwitchPosition(name: "NE", heading: 45, beamwidth: 60, bidirectional: true)])))
    }
}
