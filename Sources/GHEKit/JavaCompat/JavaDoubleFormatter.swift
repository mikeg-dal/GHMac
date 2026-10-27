import Foundation

/// Clean-room formatter producing the documented `Double.toString(double)` layout from Swift's
/// shortest round-trip digits (`Double.description`).
///
/// Layout (per the `Double.toString` documentation):
/// - NaN → "NaN", ±∞ → "Infinity"/"-Infinity", ±0 → "0.0"/"-0.0";
/// - 10⁻³ ≤ |x| < 10⁷ → plain decimal with at least one digit after the point ("271.0", "0.001");
/// - otherwise → computerized scientific notation "d.ddd" + "E" + exponent, with at least one
///   fractional digit ("1.0E-4", "1.0E7").
///
/// Java 8 occasionally prints more digits than the shortest round-trip form; for those values our
/// string still parses back to the identical double.
enum JavaDoubleFormatter {
    static func string(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0.0" }

        let (digits, exponent) = shortestDigits(abs(value))
        // value = 0.d1d2d3… × 10^exponent
        if exponent >= -2 && exponent <= 7 {
            if exponent > 0 {
                let intCount = exponent
                let intPart = digits.count >= intCount
                    ? String(digits.prefix(intCount))
                    : digits + String(repeating: "0", count: intCount - digits.count)
                let frac = digits.count > intCount ? String(digits.dropFirst(intCount)) : "0"
                return sign + intPart + "." + frac
            }
            return sign + "0." + String(repeating: "0", count: -exponent) + digits
        }
        let first = String(digits.prefix(1))
        let rest = digits.count > 1 ? String(digits.dropFirst()) : "0"
        return sign + first + "." + rest + "E" + String(exponent - 1)
    }

    /// Significant digits (no leading/trailing zeros) and exponent `k` with value = 0.digits × 10^k,
    /// extracted from Swift's shortest round-trip `description` of a finite, positive double.
    static func shortestDigits(_ x: Double) -> (digits: String, exponent: Int) {
        let text = x.description // e.g. "271.0", "0.001", "1e-05", "1.7976931348623157e+308"
        let parts = text.lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exp10 = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pointIndex = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        var digits = Array(mantissa.filter { $0 != "." })
        var k = pointIndex + exp10
        while let f = digits.first, f == "0", digits.count > 1 {
            digits.removeFirst()
            k -= 1
        }
        while let l = digits.last, l == "0", digits.count > 1 { digits.removeLast() }
        return (String(digits), k)
    }
}
