import Foundation

/// One band-switch position with its frequency range in MHz (from `SWITCHADD`).
public struct BandSwitchPosition: Sendable, Hashable {
    public var name: String
    public var lowerMHz: Double
    public var upperMHz: Double
    public init(name: String, lowerMHz: Double, upperMHz: Double) {
        self.name = name; self.lowerMHz = lowerMHz; self.upperMHz = upperMHz
    }
    public func contains(_ mhz: Double) -> Bool { lowerMHz <= mhz && mhz <= upperMHz }
}

/// Picks the band-switch position for a frequency.
public enum BandSwitchSelector {
    /// Returns the position to select, or nil to leave the switch alone.
    ///
    /// Rules: first match in profile order; a current position whose range still contains
    /// the frequency sticks; a current position that suspends auto-selection (OFF/DUMMY)
    /// sticks; locked positions are skipped; no match → nil.
    public static func select(positions: [BandSwitchPosition], current: String?,
                              freqMHz: Double, locked: Set<String> = []) -> String? {
        if let current {
            if suspendsAutoSelection(current) { return nil }
            // An unknown current name is "not in range" instead of a crash.
            if let cur = positions.first(where: { $0.name == current }), cur.contains(freqMHz) { return nil }
        }
        // Nil current → plain first match.
        for p in positions where p.contains(freqMHz) {
            // Skip positions held by a matrix lockout (OFF is never locked) and try the next match.
            if locked.contains(p.name) && p.name.caseInsensitiveCompare("OFF") != .orderedSame { continue }
            return p.name == current ? nil : p.name
        }
        return nil
    }

    /// True if a position named like this keeps the switch where it is.
    // The whole word OFF (any case) or DUMMY anywhere in the name.
    public static func suspendsAutoSelection(_ name: String) -> Bool {
        if name.range(of: "dummy", options: .caseInsensitive) != nil { return true }
        let words = name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return words.contains { $0.caseInsensitiveCompare("off") == .orderedSame }
    }
}

/// Picks the "Default" position of a switch that is becoming visible.
public enum DefaultPositionRule {
    public enum Action: Sendable, Hashable {
        /// Select this position (button, band, map switches).
        case select(String)
        /// Turn this bank position ON (never toggle).
        case setOn(String)
    }

    /// The first position whose name contains "default" (any case) or starts with "*".
    // Only the first match; empty names are ignored instead of throwing.
    public static func position(in names: [String]) -> String? {
        names.first { !$0.isEmpty && ($0.range(of: "default", options: .caseInsensitive) != nil || $0.hasPrefix("*")) }
    }

    /// The action to perform. banks set the position ON rather than toggling it.
    public static func action(in names: [String], isBank: Bool) -> Action? {
        guard let p = position(in: names) else { return nil }
        return isBank ? .setOn(p) : .select(p)
    }
}
