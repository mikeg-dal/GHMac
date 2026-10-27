import Foundation

/// Text helpers shared by the logger parsers: locale-free numbers, tolerant tag
/// extraction and datagram decoding.
public enum LoggerText {
    /// Parses a decimal number accepting `.` or `,` as the decimal separator, with
    /// surrounding whitespace. No exponents, no grouping. Returns nil for anything else.
    public static func parseNumber(_ text: some StringProtocol) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var digits = ""
        var sawSeparator = false, sawDigit = false
        for (i, ch) in s.enumerated() {
            if ch.isASCII, ch.isNumber { digits.append(ch); sawDigit = true }
            else if (ch == "." || ch == ","), !sawSeparator { digits.append("."); sawSeparator = true }
            else if (ch == "-" || ch == "+"), i == 0 { digits.append(ch) }
            else { return nil }
        }
        guard sawDigit else { return nil }
        return Double(digits)
    }

    /// True if the text has a decimal separator.
    public static func hasDecimalSeparator(_ text: some StringProtocol) -> Bool {
        text.contains(".") || text.contains(",")
    }

    /// Text between the first `<tag>` and the following `</tag>`; nil if `<tag>` is absent.
    /// A missing close tag yields the rest of the text (tolerant, like Java's split).
    public static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>") else { return nil }
        let rest = text[open.upperBound...]
        if let close = rest.range(of: "</\(name)>") { return String(rest[..<close.lowerBound]) }
        return String(rest)
    }

    /// Decodes a datagram: trailing NULs stripped, UTF-8 with a Latin-1 fallback.
    public static func decode(_ bytes: some Collection<UInt8>) -> String {
        var b = Array(bytes)
        while let last = b.last, last == 0 { b.removeLast() }
        return String(validating: b, as: UTF8.self) ?? latin1(b)
    }

    /// ISO-8859-1: every byte is the code point of the same value.
    public static func latin1(_ bytes: some Sequence<UInt8>) -> String {
        var view = String.UnicodeScalarView()
        for b in bytes { view.append(Unicode.Scalar(b)) }
        return String(view)
    }
}
