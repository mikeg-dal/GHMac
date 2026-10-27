import Foundation
import GHEKit

/// What a driver should do for a `TurnTarget`.
enum ResolvedTurn: Equatable {
    case heading(Double)
    case cw
    case ccw
    case invalid
}

extension TurnTarget {
    /// `.raw` strings are parsed as "CW"/"CCW", else a double with
    /// `,` accepted as the decimal separator. Unparsable or non-finite values are dropped.
    var resolved: ResolvedTurn {
        switch self {
        case .heading(let h): return h.isFinite ? .heading(h) : .invalid
        case .cw: return .cw
        case .ccw: return .ccw
        case .raw(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "CW" { return .cw }
            if t == "CCW" { return .ccw }
            guard let d = Double(t.replacingOccurrences(of: ",", with: ".")), d.isFinite else { return .invalid }
            return .heading(d)
        }
    }
}

/// Normalises a heading into [0, 360).
func normalizedHeading(_ h: Double) -> Double {
    guard h.isFinite else { return 0 }
    var r = h.truncatingRemainder(dividingBy: 360)
    if r < 0 { r += 360 }
    if r >= 360 { r -= 360 }
    return r
}

/// Owns the output stream of a driver: yields readings and finishes exactly once.
struct ReadingOutlet {
    private var continuation: AsyncStream<RotorReading>.Continuation?

    mutating func makeStream() -> AsyncStream<RotorReading> {
        let (s, c) = AsyncStream<RotorReading>.makeStream()
        continuation?.finish()
        continuation = c
        return s
    }

    func yield(_ r: RotorReading) { continuation?.yield(r) }

    mutating func finish() {
        continuation?.finish()
        continuation = nil
    }

    var isOpen: Bool { continuation != nil }
}
