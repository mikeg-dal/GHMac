import Foundation
import Testing
import GHEKit
@testable import GHEServerKit

@Suite("CommandRouter.parse")
struct CommandRouterParseTests {
    static let cases: [(String, [ClientCommand])] = [
        (wire("TURN", "Tower 40m", "271.0"), [.turn(rotor: "Tower 40m", .heading(271))]),
        (wire("TURN", "Tower 40m", "CW"), [.turn(rotor: "Tower 40m", .cw)]),
        (wire("TURN", "Tower 40m", "CCW"), [.turn(rotor: "Tower 40m", .ccw)]),
        (wire("TURN", "Tower 40m", "271,5"), [.turn(rotor: "Tower 40m", .heading(271.5))]),
        (wire("TURN", "R", "123d"), [.turn(rotor: "R", .heading(123))]),
        (wire("TURN", "R", ".5"), [.turn(rotor: "R", .heading(0.5))]),
        (wire("TURN", "R", "cw"), []),                       // CW is case-sensitive; "cw" is not a number
        (wire("TURN", "R", "1") + "\r" + wire("TURN", "S", "2"), [.turn(rotor: "R", .heading(1)), .turn(rotor: "S", .heading(2))]),
        (wire("TURN", "R"), []),
        ("TURN", []),
        (wire("STOP", " Tower 40m "), [.stop(rotor: "Tower 40m")]),
        (wire("STOP", "A") + "\r" + wire("STOP", "B"), [.stop(rotor: "A"), .stop(rotor: "B")]),
        ("STOP", []),
        (wire("SET_STACK", "Yagi Mid", "true"), [.setStack(antenna: "Yagi Mid", selected: true)]),
        (wire("SET_STACK", "Yagi Mid", "True"), [.setStack(antenna: "Yagi Mid", selected: true)]),
        (wire("SET_STACK", "Yagi Mid", "1"), [.setStack(antenna: "Yagi Mid", selected: false)]),
        (wire("SET_SWITCH", "Band SW", "20m"), [.setSwitch(name: "Band SW", position: "20m", on: nil)]),
        (wire("SET_SWITCH", "Bank A", "Amp", "false"), [.setSwitch(name: "Bank A", position: "Amp", on: false)]),
        (wire("SET_SWITCH", " Sw ", "P"), [.setSwitch(name: " Sw ", position: "P", on: nil)]),   // name untrimmed
        (wire("TO_DEC", " R ", "1,5", "2"), [.toDec(rotor: "R", lat: "1,5", lon: "2")]),
        (wire("TO_DEC", "R", "1"), []),
        (wire("TO_PRESET", "R", "Home"), [.toPreset(rotor: "R", preset: "Home")]),
        (wire("LOCK", " R "), [.lock(" R")]),                // untrimmed field; the line's trailing space is trimmed
        (wire("UNLOCK", "R"), [.unlock("R")]),
        ("GETHEAD Tower 40m", [.getHead("Tower")]),
        ("GET_LOCATIONS", [.getLocations]),
        ("QUIT", [.quit]),
        ("RESTART", [.restart]),
        (wire("TORNADOTURN", "T", "R", "CW"), []),
        (wire("TORNADO_CAL", "T", "R"), []),
        (wire("SET_TORNADO", "T", "P"), []),
        ("", []),
        ("hello", []),
    ]

    @Test(arguments: cases)
    func parses(_ line: String, _ expected: [ClientCommand]) {
        #expect(CommandRouter.parse(line) == expected)
    }

    @Test func trailingCRIsStrippedForEveryCommand() {
        // LOCK no longer keys "R\r".
        #expect(CommandRouter.parse(wire("LOCK", "R") + "\r") == [.lock("R")])
        #expect(CommandRouter.parse(wire("TURN", "R", "5") + "\r") == [.turn(rotor: "R", .heading(5))])
    }
}
