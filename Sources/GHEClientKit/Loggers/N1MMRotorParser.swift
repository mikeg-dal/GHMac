import Foundation

/// An N1MM+ rotor (Alt-J) command.
public enum N1MMRotorCommand: Sendable, Equatable {
    /// `<goazi>` text passed through untouched (e.g. "123.0").
    case goAzimuth(raw: String, rotor: String?)
    case stop(rotor: String?)
}

public enum N1MMRotorParser {
    public static func parse(_ text: String) -> N1MMRotorCommand? {
        let rotor = LoggerText.tag("rotor", in: text)
        if let az = LoggerText.tag("goazi", in: text) { return .goAzimuth(raw: az, rotor: rotor) }
        if text.contains("<stop>") || text.contains("<stop/>") { return .stop(rotor: rotor) }
        return nil
    }

    /// Events for one packet. `<rotor>` is ignored: every active+visible rotor moves.
    public static func events(for text: String) -> [LoggerEvent] {
        switch parse(text) {
        case .goAzimuth(let az, _)?: [.raw(text), .status("Rotor: \(az)"), .turnActive(raw: az)]
        case .stop?: [.raw(text), .status("Rotor: stop"), .stopActive]
        case nil: [.raw(text)]
        }
    }
}
