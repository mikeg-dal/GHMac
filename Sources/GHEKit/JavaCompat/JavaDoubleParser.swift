import Foundation

/// Java `Double.parseDouble` grammar check (the grammar documented for `Double.valueOf(String)`), with the
/// actual conversion done by Swift's correctly rounded `Double(String)`.
enum JavaDoubleParser {
    static func parse(_ input: String) -> Double? {
        let s = Array(JavaString.trim(input).utf16)
        guard !s.isEmpty else { return nil }
        var i = 0
        var negative = false
        if s[0] == 0x2D || s[0] == 0x2B { // - +
            negative = s[0] == 0x2D
            i = 1
        }
        guard i < s.count else { return nil }
        let rest = String(decoding: s[i...], as: UTF16.self)
        if s[i] == 0x4E { // N
            return rest == "NaN" ? Double.nan : nil
        }
        if s[i] == 0x49 { // I
            return rest == "Infinity" ? (negative ? -Double.infinity : Double.infinity) : nil
        }
        if s[i] == 0x30, i + 1 < s.count, s[i + 1] == 0x78 || s[i + 1] == 0x58 { // 0x / 0X
            return parseHex(Array(s[(i + 2)...]), negative: negative)
        }
        // Decimal: digits with at most one '.', at least one digit.
        var mantissa: [UInt8] = []
        var sawDigit = false, sawPoint = false
        while i < s.count {
            let c = s[i]
            if c >= 0x30 && c <= 0x39 {
                sawDigit = true
                mantissa.append(UInt8(c))
            } else if c == 0x2E {
                if sawPoint { return nil }
                sawPoint = true
                mantissa.append(UInt8(c))
            } else {
                break
            }
            i += 1
        }
        guard sawDigit else { return nil }
        var exponent: [UInt8] = []
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 { // e E
            i += 1
            if i < s.count, s[i] == 0x2B || s[i] == 0x2D {
                exponent.append(UInt8(s[i]))
                i += 1
            }
            let start = i
            while i < s.count, s[i] >= 0x30, s[i] <= 0x39 {
                exponent.append(UInt8(s[i]))
                i += 1
            }
            if i == start { return nil }
        }
        guard suffixOK(s, i) else { return nil }
        var text = negative ? "-" : ""
        text += String(decoding: mantissa, as: UTF8.self)
        if !exponent.isEmpty { text += "e" + String(decoding: exponent, as: UTF8.self) }
        return convert(text)
    }

    /// After the number: nothing, or exactly one of f F d D.
    private static func suffixOK(_ s: [UInt16], _ i: Int) -> Bool {
        if i == s.count { return true }
        if i == s.count - 1 { return [0x66, 0x46, 0x64, 0x44].contains(s[i]) }
        return false
    }

    /// `0[xX]((hex+ .?)|(hex* . hex+))[pP][+-]?digit+[fFdD]?` — `s` starts after the `0x`.
    private static func parseHex(_ s: [UInt16], negative: Bool) -> Double? {
        func isHex(_ c: UInt16) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
        }
        var i = 0
        var intPart: [UInt8] = [], fracPart: [UInt8] = []
        while i < s.count, isHex(s[i]) { intPart.append(UInt8(s[i])); i += 1 }
        var sawPoint = false
        if i < s.count, s[i] == 0x2E {
            sawPoint = true
            i += 1
            while i < s.count, isHex(s[i]) { fracPart.append(UInt8(s[i])); i += 1 }
        }
        if intPart.isEmpty && fracPart.isEmpty { return nil }
        guard i < s.count, s[i] == 0x70 || s[i] == 0x50 else { return nil } // p P
        i += 1
        var exp: [UInt8] = []
        if i < s.count, s[i] == 0x2B || s[i] == 0x2D { exp.append(UInt8(s[i])); i += 1 }
        let start = i
        while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { exp.append(UInt8(s[i])); i += 1 }
        guard i > start, suffixOK(s, i) else { return nil }
        var text = negative ? "-0x" : "0x"
        text += intPart.isEmpty ? "0" : String(decoding: intPart, as: UTF8.self)
        if sawPoint, !fracPart.isEmpty { text += "." + String(decoding: fracPart, as: UTF8.self) }
        text += "p" + String(decoding: exp, as: UTF8.self)
        return convert(text)
    }

    /// Swift's `Double(String)` is a correctly rounded strtod in the C locale (decimal and hex forms);
    /// out-of-range values give ±infinity or ±0, like Java.
    private static func convert(_ text: String) -> Double? {
        Double(text)
    }
}
