import Foundation

/// The six stack-match subtypes.
public enum WIOStackType: Int, Sendable, CaseIterable, Hashable {
    case stackMatchLow = 0
    case stackMatchHigh = 4
    case fourStack = 8
    case lbs = 16
    case ok2zawLow = 32
    case ok2zawHigh = 64

    /// The Device Manager subtype string.
    public var subTypeName: String {
        switch self {
        case .stackMatchLow: "Stack Match (1-4)"
        case .stackMatchHigh: "Stack Match (5-8)"
        case .fourStack: "Four Stack (GHE)"
        case .lbs: "LBS Stack"
        case .ok2zawLow: "OK2ZAW (1-4)"
        case .ok2zawHigh: "OK2ZAW (5-8)"
        }
    }

    public init?(subTypeName: String) {
        guard let t = Self.allCases.first(where: { $0.subTypeName == subTypeName }) else { return nil }
        self = t
    }

    public var isOK2ZAW: Bool { self == .ok2zawLow || self == .ok2zawHigh }
}

/// Built-in Base subtypes, in Device Manager order. Profile names follow these.
public enum WIOSubtypes {
    public static let rt21 = "RT-21"
    public static let builtIn: [String] = ["N/A", rt21] + WIOStackType.allCases.map(\.subTypeName)
}

public enum StackEncodingError: Error, Equatable {
    /// "You must have at least one antenna selected."
    case noAntennaSelected
}

/// Pure relay encodings.
public enum StackEncoding {
    /// The relay value for the selected antennas `a1…a4` (only the first 4 entries are used).
    public static func relayByte(_ type: WIOStackType, _ ants: [Bool]) throws -> UInt8 {
        let a = (0..<4).map { $0 < ants.count ? ants[$0] : false }
        switch type {
        case .stackMatchLow, .stackMatchHigh:
            // a1→2, a2→4, a3→8 (a4 ignored). One: +1. Two or more: ~(v+1) & 0x0F.
            var v = 0, n = 0
            for (i, w) in [2, 4, 8].enumerated() where a[i] { v += w; n += 1 }
            guard n > 0 else { throw StackEncodingError.noAntennaSelected }
            return n == 1 ? UInt8(v + 1) : UInt8(~(v + 1) & 0x0F)
        case .fourStack:
            var v = 0, n = 0
            for (i, w) in [1, 2, 4, 8].enumerated() where a[i] { v += w; n += 1 }
            switch n {
            case 0: throw StackEncodingError.noAntennaSelected
            case 1: return UInt8(v + 0x20)
            case 2, 3: return UInt8(((~(v + 0x20)) & 0x2F) + 0x10)
            default: return 0
            }
        case .lbs:
            var v = 0x0F, n = 0
            for (i, w) in [1, 2, 4, 8].enumerated() where a[i] { v -= w; n += 1 }
            switch n {
            case 0: throw StackEncodingError.noAntennaSelected
            case 1: return UInt8(v + 0x40)
            case 2: return UInt8(v + 0x30)
            case 3: return UInt8(v + 0x10)
            default: return 0
            }
        case .ok2zawLow, .ok2zawHigh:
            var v = 0, n = 0
            for (i, w) in [1, 2, 4].enumerated() where a[i] { v += w; n += 1 }
            guard n > 0 else { throw StackEncodingError.noAntennaSelected }
            return UInt8(n >= 2 ? v + 8 : v)
        }
    }

    /// Pin mask (−1 = unused pin) for the selected antennas.
    public static func pins(_ type: WIOStackType, _ ants: [Bool]) throws -> [Int8] {
        let b = try relayByte(type, ants)
        let (first, count): (Int, Int) = switch type {
        case .stackMatchLow, .ok2zawLow: (0, 4)
        case .stackMatchHigh, .ok2zawHigh: (4, 4)
        case .fourStack: (0, 6)
        case .lbs: (0, 7)
        }
        var r = [Int8](repeating: -1, count: 8)
        for bit in 0..<count { r[first + bit] = Int8((b >> UInt8(bit)) & 1) }
        return r
    }

    /// OK2ZAW startup pattern: all four pins of its side on (`initializeStack`). nil for other types.
    public static func ok2zawInitialPins(_ type: WIOStackType) -> [Int8]? {
        switch type {
        case .ok2zawLow: [1, 1, 1, 1, -1, -1, -1, -1]
        case .ok2zawHigh: [-1, -1, -1, -1, 1, 1, 1, 1]
        default: nil
        }
    }
}
