import Foundation
import Testing
@testable import GHEKit

/// Client → server commands: golden bytes for the protocol examples and the server's parsing rules.
@Suite struct GHWireClientCommandTests {
    static let examples: [(ClientCommand, String)] = [
        (.turn(rotor: "Tower 40m", .heading(271)), "TURN␟Tower 40m␟271.0␍␊"),
        (.turn(rotor: "Tower 40m", .cw), "TURN␟Tower 40m␟CW␍␊"),
        (.turn(rotor: "Tower 40m", .ccw), "TURN␟Tower 40m␟CCW␍␊"),
        (.turn(rotor: "Tower 40m", .raw("271,5")), "TURN␟Tower 40m␟271,5␍␊"),
        (.stop(rotor: "Tower 40m"), "STOP␟Tower 40m␍␊"),
        (.setStack(antenna: "Yagi Mid", selected: true), "SET_STACK␟Yagi Mid␟true␍␊"),
        (.setSwitch(name: "Band SW", position: "20m", on: nil), "SET_SWITCH␟Band SW␟20m␍␊"),
        (.setSwitch(name: "Bank A", position: "Amp", on: false), "SET_SWITCH␟Bank A␟Amp␟false␍␊"),
        (.toDec(rotor: "R", lat: "40.5", lon: "74,1"), "TO_DEC␟R␟40.5␟74,1␍␊"),
        (.toPreset(rotor: "R", preset: "Home"), "TO_PRESET␟R␟Home␍␊"),
        (.lock("R"), "LOCK␟R␍␊"),
        (.unlock("R"), "UNLOCK␟R␍␊"),
        (.getHead("R"), "GETHEAD R␍␊"),
        (.getLocations, "GET_LOCATIONS␍␊"),
        (.quit, "QUIT␍␊"),
        (.restart, "RESTART␍␊"),
        (.tornadoCal(tuner: "Tuner", rotor: "R"), "TORNADO_CAL␟Tuner␟R␍␊"),
        (.setTornado(tuner: "Tuner", position: "A"), "SET_TORNADO␟Tuner␟A␍␊"),
        (.tornadoTurn(tuner: "Tuner", rotor: "R", cw: true), "TORNADOTURN␟Tuner␟R␟CW␍␊"),
        (.tornadoTurn(tuner: "Tuner", rotor: "R", cw: false), "TORNADOTURN␟Tuner␟R␟CCW␍␊"),
    ]

    @Test func goldenBytesForSpecExamples() {
        for (command, expected) in Self.examples {
            #expect(GHWire.encode(command) == wire(expected), "\(command)")
            #expect(GHWire.encode(command).count < 256)
        }
    }

    @Test func roundTripThroughServerParser() {
        for (command, _) in Self.examples {
            // Drop only the LF: the server's `\n` split leaves the CR on the line.
            let line = Windows1252.decode(GHWire.encode(command).dropLast())
            let decoded = GHWire.decodeClientLine(line)
            switch command {
            case .turn(let r, .raw(let s)):
                #expect(decoded == [.turn(rotor: r, .heading(JavaDouble.parse(s, allowComma: true)!))])
            case .tornadoCal, .setTornado, .tornadoTurn:
                #expect(decoded == [], "servers ignore Tornado commands")
            default:
                #expect(decoded == [command], "\(command)")
            }
        }
    }

    @Test func turnHeadingsUseJavaDoubleString() {
        #expect(GHWire.encode(.turn(rotor: "R", .heading(0))) == wire("TURN␟R␟0.0␍␊"))
        #expect(GHWire.encode(.turn(rotor: "R", .heading(359.5))) == wire("TURN␟R␟359.5␍␊"))
        #expect(GHWire.encode(.turn(rotor: "R", .heading(1e-4))) == wire("TURN␟R␟1.0E-4␍␊"))
    }

    @Test func turnParsingMatchesServer() {
        #expect(GHWire.decodeClientLine(wireText("TURN␟ Tower 40m ␟271,5")) == [.turn(rotor: "Tower 40m", .heading(271.5))])
        #expect(GHWire.decodeClientLine(wireText("TURN␟R␟ 90d ")) == [.turn(rotor: "R", .heading(90))])
        #expect(GHWire.decodeClientLine(wireText("TURN␟R␟cw")) == [], "CW is case-sensitive; 'cw' is not a number")
        #expect(GHWire.decodeClientLine(wireText("TURN␟R␟ CW")) == [], "CW is compared untrimmed")
        #expect(GHWire.decodeClientLine(wireText("TURN␟R")) == [], "no target: nothing happens")
        #expect(GHWire.decodeClientLine("TURN") == [], "missing rotor is ignored, not fatal")
        #expect(GHWire.decodeClientLine(wireText("TURN␟R␟1e2")) == [.turn(rotor: "R", .heading(100))])
    }

    @Test func carriageReturnSeparatesRepeatedCommands() {
        #expect(GHWire.decodeClientLine(wireText("TURN␟A␟10␍TURN␟B␟CW␍"))
                == [.turn(rotor: "A", .heading(10)), .turn(rotor: "B", .cw)])
        #expect(GHWire.decodeClientLine(wireText("STOP␟A␍STOP␟B")) == [.stop(rotor: "A"), .stop(rotor: "B")])
        #expect(GHWire.decodeClientLine(wireText("SET_STACK␟A␟true␍SET_STACK␟B␟x"))
                == [.setStack(antenna: "A", selected: true), .setStack(antenna: "B", selected: false)])
        #expect(GHWire.decodeClientLine(wireText("SET_SWITCH␟S␟A␍SET_SWITCH␟S␟B␟TRUE"))
                == [.setSwitch(name: "S", position: "A", on: nil), .setSwitch(name: "S", position: "B", on: true)])
        // Every \r-part is parsed as the line's command, whatever its keyword.
        #expect(GHWire.decodeClientLine(wireText("TURN␟A␟10␍XYZ␟B␟20")) == [.turn(rotor: "A", .heading(10)), .turn(rotor: "B", .heading(20))])
        // A malformed part is skipped, the rest still run.
        #expect(GHWire.decodeClientLine(wireText("STOP␍STOP␟B")) == [.stop(rotor: "B")])
    }

    @Test func trailingCarriageReturnIsStrippedEverywhere() {
        #expect(GHWire.decodeClientLine("LOCK\u{1F}R\r") == [.lock("R")])
        #expect(GHWire.decodeClientLine("UNLOCK\u{1F}R\r") == [.unlock("R")])
        #expect(GHWire.decodeClientLine("GETHEAD R\r") == [.getHead("R")])
        #expect(GHWire.decodeClientLine("TO_PRESET\u{1F}R\u{1F}Home\r") == [.toPreset(rotor: "R", preset: "Home")])
        #expect(GHWire.decodeClientLine("QUIT\r") == [.quit])
    }

    @Test func fieldTrimmingFollowsServer() {
        // SET_SWITCH fields are not trimmed; SET_STACK / STOP / TURN / TO_DEC rotor names are.
        #expect(GHWire.decodeClientLine(wireText("SET_SWITCH␟ S ␟ A ")) == [.setSwitch(name: " S ", position: " A ", on: nil)])
        #expect(GHWire.decodeClientLine(wireText("SET_STACK␟ A ␟true")) == [.setStack(antenna: "A", selected: true)])
        #expect(GHWire.decodeClientLine(wireText("STOP␟ A ")) == [.stop(rotor: "A")])
        #expect(GHWire.decodeClientLine(wireText("TO_DEC␟ R ␟1,5␟2")) == [.toDec(rotor: "R", lat: "1,5", lon: "2")])
        #expect(GHWire.decodeClientLine(wireText("LOCK␟ R ")) == [.lock(" R ")])
    }

    @Test func malformedAndUnknownLinesYieldNothing() {
        for line in ["", "HELLO", "TO_DEC␟R␟1", "TO_PRESET␟R", "LOCK", "UNLOCK", "GETHEAD", "GETHEAD␟R", "SET_STACK␟A",
                     "SET_SWITCH␟S", "STOP", "TORNADOTURN␟T␟R␟CW", "turn␟R␟10", "\u{0}STOP␟R"] {
            #expect(GHWire.decodeClientLine(wireText(line)) == [], "\(line)")
        }
    }

    @Test func prefixMatchingIsJavaStartsWith() {
        #expect(GHWire.decodeClientLine("QUITTING") == [.quit])
        #expect(GHWire.decodeClientLine("GET_LOCATIONS") == [.getLocations])
        #expect(GHWire.decodeClientLine("RESTART now") == [.restart])
    }
}
