import Foundation

/// The two current bands (slot A = VFO-A / radio 1, slot B = VFO-B / radio 2).
/// Values are legacy strings: a band name, `"ALL"` or `"???"`. Both start as `"ALL"`.
public struct BandState: Sendable, Hashable, Codable {
    public var a: String
    public var b: String

    public init(a: String = Band.allName, b: String = Band.allName) {
        self.a = a; self.b = b
    }

    public subscript(slot: BandSlot) -> String {
        get { slot == .a ? a : b }
        set { if slot == .a { a = newValue } else { b = newValue } }
    }

    /// Sets a slot. `nil` means "no band" (`"???"`). Returns true when the value changed.
    @discardableResult
    public mutating func set(_ slot: BandSlot, to band: String?) -> Bool {
        let value = band ?? Band.unknownName
        guard self[slot] != value else { return false }
        self[slot] = value
        return true
    }

    /// Applies a logger `.band` event; returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: LoggerEvent) -> Bool {
        guard case .band(let slot, let band) = event else { return false }
        return set(slot, to: band)
    }

    /// True if either slot is "ALL".
    // Case-insensitive.
    public var showsAll: Bool { Self.isAll(a) || Self.isAll(b) }

    /// Whether a device whose band list is `deviceBands` is shown. Band names match
    /// case-sensitively; "ALL" matches in any case.
    public func isVisible(deviceBands: Set<String>) -> Bool {
        showsAll || deviceBands.contains(a) || deviceBands.contains(b)
    }

    public static func isAll(_ s: String) -> Bool { s.caseInsensitiveCompare(Band.allName) == .orderedSame }
}
