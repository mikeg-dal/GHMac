import Foundation

/// A Win-Test UDP datagram: `VERB: "<from>" "<to>" args…<CK>\0`.
public struct WinTestPacket: Sendable, Equatable {
    /// Text without the checksum byte and NUL padding.
    public var text: String
    /// Text before the first ':' ("SETAZIMUTH", "STATUS").
    public var verb: String
    public var checksum: UInt8?
    /// Whether `checksum == ((Σ preceding bytes) & 0xFF) | 0x80`.
    public var checksumValid: Bool

    public static func checksum(of bytes: some Sequence<UInt8>) -> UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) }) | 0x80
    }

    /// Splits off padding and the checksum byte. The last byte after trimming
    /// is always taken as the checksum; a mismatch is reported but the packet is accepted.
    public init?(bytes: [UInt8]) {
        var b = bytes[...]
        while let last = b.last, last <= 0x20 { b.removeLast() }   // NULs and whitespace, like trim()
        while let first = b.first, first <= 0x20 { b.removeFirst() }
        guard let ck = b.popLast() else { return nil }
        checksum = ck
        checksumValid = Self.checksum(of: b) == ck
        text = LoggerText.latin1(b)
        guard let colon = text.firstIndex(of: ":") else { verb = ""; return }
        verb = String(text[..<colon])
    }

    /// The quoted sender station (`split("\"")[1]`).
    public var station: String? {
        let parts = text.components(separatedBy: "\"")
        return parts.count > 1 ? parts[1] : nil
    }
}

/// The assumed STATUS grammar, isolated so it can be corrected
/// once real Win-Test captures are available:
/// `STATUS: "<stn>" "<to>" f0 f1 f2 RAD FREQ1 … "<s5>" … "<s7>" FREQ2`.
public struct WinTestStatusGrammar: Sendable {
    public struct Status: Sendable, Equatable {
        public var station: String
        public var rad: Int
        /// Frequencies in Win-Test units (100 Hz).
        public var freq1: Double
        public var freq2: Double
        /// Frequency of the reported radio: RAD 1 → FREQ2, otherwise FREQ1.
        public var selected: Double { rad == 1 ? freq2 : freq1 }
    }

    public init() {}

    /// Parses STATUS text (checksum already removed). Nil if it does not fit the grammar.
    public func parse(_ text: String) -> Status? {
        let q = text.components(separatedBy: "\"")
        guard q.count > 8 else { return nil }
        let trimmed = q[4].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        guard trimmed.count > 4, let rad = Int(trimmed[3].trimmingCharacters(in: .whitespaces)),
              let f1 = LoggerText.parseNumber(trimmed[4]),
              let f2Token = q[8].split(separator: " ").first, let f2 = LoggerText.parseNumber(f2Token)
        else { return nil }
        return Status(station: q[1], rad: rad, freq1: f1, freq2: f2)
    }
}

/// Win-Test settings that affect parsing.
public struct WinTestFilter: Sendable, Hashable {
    /// 0 = active radio, 1 = radio 1 only, 2 = radio 2 only, 3 = both.
    public var selectedRadio: Int
    public var stationFilterEnabled: Bool
    public var stationName: String
    public init(selectedRadio: Int = 0, stationFilterEnabled: Bool = false, stationName: String = "") {
        self.selectedRadio = selectedRadio; self.stationFilterEnabled = stationFilterEnabled; self.stationName = stationName
    }

    /// The station filter applies only when its checkbox is on.
    public var activeStation: String? {
        stationFilterEnabled && !stationName.isEmpty ? stationName : nil
    }
}

public enum WinTestParser {
    public static let grammar = WinTestStatusGrammar()

    /// Win-Test frequency (100 Hz units) → kHz/MHz.
    public static func frequency(_ v: Double) -> LoggerFrequency { LoggerFrequency(kHz: v / 10, mhz: v / 10_000) }

    /// Events for one datagram.
    public static func events(for bytes: [UInt8], filter: WinTestFilter) -> [LoggerEvent] {
        guard let p = WinTestPacket(bytes: bytes) else { return [] }
        var out: [LoggerEvent] = [.raw(p.text)]
        if !p.checksumValid {
            out.append(.status("Win-Test checksum mismatch (accepted)"))
        }
        let mismatch = filter.activeStation.flatMap { want in p.station == want ? nil : want }
        if p.text.contains("SETAZIMUTH:") {
            if let want = mismatch {
                out.append(.status("Station name does not match \"\(want)\""))
            } else if let heading = p.text.split(separator: " ").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
                      !heading.isEmpty {
                out += [.status("Rotor: \(heading)"), .turnActive(raw: heading)]
            }
        }
        if p.text.contains("STATUS:") {
            if let want = mismatch {
                out.append(.status("Station name does not match \"\(want)\""))
            } else if let s = grammar.parse(p.text) {
                let f = frequency(s.selected)
                out += RadioRouting.winTest(rad: s.rad, setting: filter.selectedRadio, freqMHz: f.mhz, band: f.band)
            } else {
                out.append(.status("Unrecognised Win-Test STATUS packet"))
            }
        }
        return out
    }
}
