import Foundation

/// `.properties` reader/writer written from the documented `java.util.Properties.load(InputStream)`
/// and `store(OutputStream, String)` contracts (ISO-8859-1 bytes), checked against JDK 8 goldens.
enum JavaPropertiesCodec {
    private static let cr: UInt16 = 0x0D, lf: UInt16 = 0x0A, backslash: UInt16 = 0x5C

    /// Space, tab, form feed.
    private static func isBlank(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0C }

    // MARK: load

    /// Entries in file order (apply in order: later duplicates win).
    static func load(_ data: Data) -> [(String, String)] {
        var result: [(String, String)] = []
        for logical in logicalLines(naturalLines(data.map { UInt16($0) })) {
            let (rawKey, rawValue) = splitKeyValue(logical)
            // A malformed \uXXXX makes Java's load throw; entries read before it stay loaded.
            guard let key = unescape(rawKey), let value = unescape(rawValue) else { return result }
            result.append((key, value))
        }
        return result
    }

    /// Splits on "\n", "\r" or "\r\n".
    private static func naturalLines(_ chars: [UInt16]) -> [ArraySlice<UInt16>] {
        var lines: [ArraySlice<UInt16>] = []
        var start = 0, i = 0
        while i < chars.count {
            if chars[i] == lf || chars[i] == cr {
                lines.append(chars[start..<i])
                if chars[i] == cr, i + 1 < chars.count, chars[i + 1] == lf { i += 1 }
                start = i + 1
            }
            i += 1
        }
        if start < chars.count { lines.append(chars[start...]) }
        return lines
    }

    /// True when the text ends in an odd number of backslashes (the line terminator is escaped).
    private static func endsWithEscape(_ s: [UInt16]) -> Bool {
        var n = 0
        for c in s.reversed() { if c == backslash { n += 1 } else { break } }
        return n % 2 == 1
    }

    /// Joins continuation lines, drops blank and comment lines, strips leading white space.
    private static func logicalLines(_ natural: [ArraySlice<UInt16>]) -> [[UInt16]] {
        var out: [[UInt16]] = []
        var pending: [UInt16]? // a logical line awaiting its continuation
        for line in natural {
            let content = Array(line.drop(while: isBlank))
            if var p = pending {
                p += content
                if endsWithEscape(content) {
                    p.removeLast()
                    pending = p
                } else {
                    out.append(p)
                    pending = nil
                }
                continue
            }
            guard let first = content.first else { continue }   // blank line
            if first == 0x23 || first == 0x21 { continue }       // '#' or '!' comment
            if endsWithEscape(content) {
                pending = Array(content.dropLast())
            } else {
                out.append(content)
            }
        }
        if let p = pending, !p.isEmpty { out.append(p) }
        return out
    }

    /// Key ends at the first unescaped '=', ':' or blank; then blanks, at most one '=' or ':', blanks.
    private static func splitKeyValue(_ line: [UInt16]) -> (ArraySlice<UInt16>, ArraySlice<UInt16>) {
        var i = 0
        var escaped = false
        while i < line.count {
            let c = line[i]
            if !escaped && (c == 0x3D || c == 0x3A || isBlank(c)) { break }
            escaped = c == backslash && !escaped
            i += 1
        }
        let key = line[0..<i]
        var j = i
        var sawSeparator = false
        if j < line.count && (line[j] == 0x3D || line[j] == 0x3A) {
            sawSeparator = true
            j += 1
        }
        while j < line.count {
            if isBlank(line[j]) {
                j += 1
            } else if !sawSeparator && (line[j] == 0x3D || line[j] == 0x3A) {
                sawSeparator = true
                j += 1
            } else {
                break
            }
        }
        return (key, line[j...])
    }

    /// `\t \n \r \f`, `\uXXXX`, and `\x` → `x`. Returns nil for a malformed `\u` escape.
    private static func unescape(_ s: ArraySlice<UInt16>) -> String? {
        var out: [UInt16] = []
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == backslash else { out.append(c); continue }
            guard let e = it.next() else { break } // dangling backslash: dropped
            switch e {
            case 0x74: out.append(0x09)
            case 0x6E: out.append(lf)
            case 0x72: out.append(cr)
            case 0x66: out.append(0x0C)
            case 0x75:
                var v: UInt16 = 0
                for _ in 0..<4 {
                    guard let h = it.next(), let d = hexValue(h) else { return nil }
                    v = v << 4 | d
                }
                out.append(v)
            default: out.append(e)
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func hexValue(_ c: UInt16) -> UInt16? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x41...0x46: c - 0x41 + 10
        case 0x61...0x66: c - 0x61 + 10
        default: nil
        }
    }

    // MARK: store

    static func store(_ entries: [(String, String)], comment: String?, date: Date, timeZone: TimeZone) -> Data {
        var text: [UInt16] = []
        if let comment { text += commentBlock(comment) }
        text += Array(("#" + JavaDate.string(date, timeZone: timeZone) + "\n").utf16)
        for (k, v) in entries {
            text += escape(k, isKey: true)
            text.append(0x3D)
            text += escape(v, isKey: false)
            text.append(lf)
        }
        // Everything is <= U+00FF by now (escaped, or comment text); write as ISO-8859-1.
        return Data(text.map { $0 <= 0xFF ? UInt8($0) : 0x3F })
    }

    private static func uEscape(_ c: UInt16) -> [UInt16] {
        Array(String(format: "\\u%04X", c).utf16)
    }

    /// Entry escaping: specials get a backslash, controls and non-ASCII become `\uXXXX`.
    /// Spaces are escaped everywhere in keys, and only as the first character of values.
    private static func escape(_ s: String, isKey: Bool) -> [UInt16] {
        var out: [UInt16] = []
        for (index, c) in s.utf16.enumerated() {
            switch c {
            case 0x20:
                if isKey || index == 0 { out.append(backslash) }
                out.append(c)
            case 0x09: out += [backslash, 0x74]
            case lf: out += [backslash, 0x6E]
            case cr: out += [backslash, 0x72]
            case 0x0C: out += [backslash, 0x66]
            case 0x3D, 0x3A, 0x23, 0x21, backslash: out += [backslash, c]
            case 0x21...0x7E: out.append(c)
            default: out += uEscape(c)
            }
        }
        return out
    }

    /// Comment block: "#" prefix; chars above U+00FF as `\uXXXX`; each line break (CR, LF or CRLF)
    /// becomes a newline followed by "#" unless the comment itself continues with '#' or '!'.
    private static func commentBlock(_ comment: String) -> [UInt16] {
        let u = Array(comment.utf16)
        var out: [UInt16] = [0x23]
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == cr || c == lf {
                out.append(lf)
                if c == cr, i + 1 < u.count, u[i + 1] == lf { i += 1 }
                let next: UInt16? = i + 1 < u.count ? u[i + 1] : nil
                if next != 0x23 && next != 0x21 { out.append(0x23) }
            } else if c > 0xFF {
                out += uEscape(c)
            } else {
                out.append(c)
            }
            i += 1
        }
        out.append(lf)
        return out
    }
}

/// `java.util.Date.toString()` text: `EEE MMM dd HH:mm:ss zzz yyyy` in the US locale.
public enum JavaDate {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let day = days[((c.weekday ?? 1) - 1) % 7]
        let month = months[((c.month ?? 1) - 1) % 12]
        return "\(day) \(month) \(two(c.day)) \(two(c.hour)):\(two(c.minute)):\(two(c.second)) "
            + "\(zoneName(timeZone, at: date)) \(c.year ?? 1970)"
    }

    /// Short US zone name. Foundation agrees with Java for US zones and GMT; other zones fall back
    /// to Foundation's abbreviation (may read "GMT+2" where Java says "CEST" — comment line only).
    static func zoneName(_ tz: TimeZone, at date: Date) -> String {
        if tz.identifier == "UTC" || tz.identifier == "Etc/UTC" { return "UTC" }
        if tz.identifier == "GMT" || tz.identifier == "Etc/GMT" { return "GMT" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = tz
        f.dateFormat = "zzz"
        return f.string(from: date)
    }
}
