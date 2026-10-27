import Foundation

// Spec: docs/PROTOCOL.md.
// Verified on hardware 2026-10-22: RT-21 fw 4.13.1 answers `BI2;` with `358.4;`.

public enum RT21Reply: Sendable, Equatable {
    /// A heading. `model` is 21 when the reply contained a '.', 20 for the 3-digit RT-20/DCU form.
    case heading(Double, model: Int)
    /// A frame containing ACK (0x06): acknowledged, no data.
    case ack
    /// EEPROM register reply `<reg> SOH <value>`.
    case register(UInt8, String)
    /// Anything else (kept for the traffic log).
    case noise([UInt8])
}

/// `;`-delimited reply parser. Pure; always resets its buffer on `;`; never traps on bad numbers.
/// Parses `358.4;` as 358.4.
///
/// Frame rules, in order: contains ACK → `.ack`; contains SOH → `.register(byte before SOH, rest)`;
/// contains '.' → tenths heading (model 21); otherwise a trailing run of 3–4 digits → integer
/// heading (model 20). Leading junk, spaces, CR/LF and NULs are tolerated. Empty frames
/// (a bare `;`) produce nothing; everything else is `.noise`.
public struct RT21ReplyParser: Sendable {
    private var buffer: [UInt8] = []
    /// A frame longer than this without a `;` is flushed as noise.
    public static let maxFrame = 256

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [RT21Reply] {
        var out: [RT21Reply] = []
        for b in bytes {
            if b == 0x3B {
                // The buffer is cleared on every `;`, whatever the frame held.
                let frame = buffer
                buffer.removeAll(keepingCapacity: true)
                if let r = Self.parse(frame: frame) { out.append(r) }
            } else {
                buffer.append(b)
                if buffer.count > Self.maxFrame {
                    out.append(.noise(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return out
    }

    public mutating func reset() { buffer.removeAll() }

    /// Parses one frame (without its `;`). Returns nil for an empty / whitespace-only frame.
    public static func parse(frame: [UInt8]) -> RT21Reply? {
        if frame.contains(0x06) { return .ack }
        if let soh = frame.firstIndex(of: 0x01) {
            guard soh > 0 else { return .noise(frame) }
            return .register(frame[soh - 1], latin1(frame[(soh + 1)...]))
        }
        let trimmed = trim(frame)
        if trimmed.isEmpty { return nil }
        // Trailing run of digits and dots: tolerates any leading junk.
        let start = trimmed.lastIndex { !(isDigit($0) || $0 == 0x2E) }.map { trimmed.index(after: $0) } ?? trimmed.startIndex
        let token = trimmed[start...]
        let digits = token.filter(isDigit).count
        if frame.contains(0x2E) {
            guard digits > 0, token.filter({ $0 == 0x2E }).count == 1,
                  let v = Double(latin1(token)), v.isFinite, v >= 0, v < 1000 else { return .noise(frame) }
            return .heading(v, model: 21)
        }
        guard (3...4).contains(digits), let v = Int(latin1(token)) else { return .noise(frame) }
        return .heading(Double(v), model: 20)
    }

    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    static func trim(_ f: [UInt8]) -> ArraySlice<UInt8> {
        let pad: (UInt8) -> Bool = { $0 == 0 || $0 == 0x20 || $0 == 0x0D || $0 == 0x0A || $0 == 0x09 }
        var s = f[...]
        while let l = s.first, pad(l) { s = s.dropFirst() }
        while let l = s.last, pad(l) { s = s.dropLast() }
        return s
    }

    static func latin1<S: Sequence<UInt8>>(_ bytes: S) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }
}

/// Command bytes. Formatting is locale-independent.
public enum RT21Commands {
    /// `BI<d>;` (heading with tenths).
    public static func pollTenths(digit: Character = "2") -> [UInt8] { Array("BI\(digit);".utf8) }
    /// `AI<d>;` (integer heading; DCU-1 uses digit 1, client terminal server digit 2).
    public static func pollInteger(digit: Character) -> [UInt8] { Array("AI\(digit);".utf8) }

    /// RT-21 goto with tenths: `AP2hhh.h\r;`.
    ///
    /// `DecimalFormat("000.0")` rounds HALF_EVEN on the double's exact binary value
    /// (99.95 → `100.0`, 359.95 → `359.9`, 45.25 → `045.2`), is locale-dependent and has no
    /// range check (−5 → `-005.0`, 1234.5 → `1234.5`). C `%05.1f` rounds the exact binary value
    /// half-to-even too, so it matches byte for byte on 0…360; we always use the POSIX
    /// decimal point and wrap headings outside 0…360 into range.
    public static func gotoTenths(_ heading: Double, digit: Character = "2") -> [UInt8] {
        Array("AP\(digit)\(tenths(normalize(heading)))\r;".utf8)
    }

    /// RT-20 / DCU-1 goto: `AP<d>nnn;AM<d>;`. `Math.round` (half up), 3 digits.
    public static func gotoWithExecute(_ heading: Double, digit: Character) -> [UInt8] {
        Array("AP\(digit)\(whole(heading));AM\(digit);".utf8)
    }

    /// Client terminal-server goto: `AP2nnn\r;`.
    public static func gotoTerminal(_ heading: Double, digit: Character = "2") -> [UInt8] {
        Array("AP\(digit)\(whole(heading))\r;".utf8)
    }

    /// Jog: `AA0;` (CCW) / `AB0;` (CW).
    public static func jog(cw: Bool) -> [UInt8] { cw ? Array("AB0;".utf8) : Array("AA0;".utf8) }
    public static let stop: [UInt8] = [0x3B]

    /// Headings in 0…360 pass through (360 stays 360); anything else wraps into [0, 360);
    /// NaN/∞ become 0; −0 becomes 0.
    public static func normalize(_ heading: Double) -> Double {
        guard heading.isFinite else { return 0 }
        if heading >= 0 && heading <= 360 { return heading == 0 ? 0 : heading }
        var h = heading.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h == 0 || h >= 360 ? 0 : h
    }

    /// `000.0` with HALF_EVEN on the exact value (Java `DecimalFormat("000.0")`), POSIX locale.
    static func tenths(_ h: Double) -> String { String(format: "%05.1f", h) }

    /// `Math.round(h)` zero-padded to 3 digits, after normalisation.
    static func whole(_ heading: Double) -> String {
        let n = Int(normalize(heading).rounded(.toNearestOrAwayFromZero))
        return String(format: "%03d", n)
    }
}
