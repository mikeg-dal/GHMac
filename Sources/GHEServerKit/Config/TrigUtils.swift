import Foundation

/// Great-circle helpers (Ed Williams' formulas).
///
/// Convention (replicated for INI compatibility): latitude north positive, longitude
/// **west positive** — an east longitude must be given as a negative number.
public enum TrigUtils {
    /// Angular distance in radians between two points.
    public static func distance(fromLatitude lat1d: Double, fromLongitude lon1d: Double,
                                toLatitude lat2d: Double, toLongitude lon2d: Double) -> Double {
        let lat1 = radians(lat1d), lon1 = radians(lon1d)
        let lat2 = radians(lat2d), lon2 = radians(lon2d)
        return 2.0 * asin(sqrt(pow(sin((lat1 - lat2) / 2.0), 2.0)
                               + cos(lat1) * cos(lat2) * pow(sin((lon1 - lon2) / 2.0), 2.0)))
    }

    /// Initial great-circle course in degrees, (0, 360], from point 1 to point 2.
    /// Due north comes out as 360.0.
    ///
    /// Returns nil for the same point, the antipode, or a pole as the start point.
    /// The `acos` argument is clamped to [-1, 1] so rounding can't create a NaN either.
    public static func heading(fromLatitude lat1d: Double, fromLongitude lon1d: Double,
                               toLatitude lat2d: Double, toLongitude lon2d: Double) -> Double? {
        let d = distance(fromLatitude: lat1d, fromLongitude: lon1d, toLatitude: lat2d, toLongitude: lon2d)
        let lat1 = radians(lat1d), lon1 = radians(lon1d)
        let lat2 = radians(lat2d), lon2 = radians(lon2d)
        let denominator = sin(d) * cos(lat1)
        guard denominator != 0, denominator.isFinite else { return nil }
        let raw = (sin(lat2) - sin(lat1) * cos(d)) / denominator
        guard raw.isFinite else { return nil }
        let ratio = min(1.0, max(-1.0, raw))
        let tc1: Double
        if sin(lon2 - lon1) < 0.0 {
            tc1 = acos(ratio)
        } else {
            tc1 = Double.pi * 2 - acos(ratio)
        }
        let deg = degrees(tc1)
        return deg.isFinite ? deg : nil
    }

    /// Java 8 `Math.toRadians`: `angdeg / 180.0 * PI`.
    static func radians(_ deg: Double) -> Double { deg / 180.0 * Double.pi }
    /// Java 8 `Math.toDegrees`: `angrad * 180.0 / PI`.
    static func degrees(_ rad: Double) -> Double { rad * 180.0 / Double.pi }
}
