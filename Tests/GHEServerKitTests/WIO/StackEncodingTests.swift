import Testing
@testable import GHEServerKit

/// Expected values were generated from a line-by-line Python port of `WioStackMatch.calcRelayByte`
/// (Java byte arithmetic), indexed by the antenna bitmask a1 = bit 0 … a4 = bit 3. nil = "no antenna".
@Suite struct StackEncodingTests {
    static let expected: [WIOStackType: [UInt8?]] = [
        .stackMatchLow: [nil, 0x03, 0x05, 0x08, 0x09, 0x04, 0x02, 0x00, nil, 0x03, 0x05, 0x08, 0x09, 0x04, 0x02, 0x00],
        .stackMatchHigh: [nil, 0x03, 0x05, 0x08, 0x09, 0x04, 0x02, 0x00, nil, 0x03, 0x05, 0x08, 0x09, 0x04, 0x02, 0x00],
        .fourStack: [nil, 0x21, 0x22, 0x1C, 0x24, 0x1A, 0x19, 0x18, 0x28, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x00],
        .lbs: [nil, 0x4E, 0x4D, 0x3C, 0x4B, 0x3A, 0x39, 0x18, 0x47, 0x36, 0x35, 0x14, 0x33, 0x12, 0x11, 0x00],
        .ok2zawLow: [nil, 0x01, 0x02, 0x0B, 0x04, 0x0D, 0x0E, 0x0F, nil, 0x01, 0x02, 0x0B, 0x04, 0x0D, 0x0E, 0x0F],
        .ok2zawHigh: [nil, 0x01, 0x02, 0x0B, 0x04, 0x0D, 0x0E, 0x0F, nil, 0x01, 0x02, 0x0B, 0x04, 0x0D, 0x0E, 0x0F],
    ]

    static func ants(_ m: Int) -> [Bool] { (0..<4).map { m >> $0 & 1 == 1 } }

    @Test(arguments: WIOStackType.allCases)
    func everySubset(_ type: WIOStackType) throws {
        let table = try #require(Self.expected[type])
        for m in 0..<16 {
            let a = Self.ants(m)
            if let want = table[m] {
                #expect(try StackEncoding.relayByte(type, a) == want, "type \(type) mask \(m)")
            } else {
                #expect(throws: StackEncodingError.noAntennaSelected) { try StackEncoding.relayByte(type, a) }
            }
        }
    }

    @Test(arguments: WIOStackType.allCases)
    func pinsMatchByteOnTheRightSide(_ type: WIOStackType) throws {
        for m in 1..<16 {
            let a = Self.ants(m)
            guard let b = try? StackEncoding.relayByte(type, a) else { continue }
            let pins = try StackEncoding.pins(type, a)
            let (first, count): (Int, Int) = switch type {
            case .stackMatchLow, .ok2zawLow: (0, 4)
            case .stackMatchHigh, .ok2zawHigh: (4, 4)
            case .fourStack: (0, 6)
            case .lbs: (0, 7)
            }
            for p in 0..<8 {
                if p >= first && p < first + count {
                    #expect(pins[p] == Int8((b >> UInt8(p - first)) & 1))
                } else {
                    #expect(pins[p] == -1)
                }
            }
        }
    }

    @Test func specTableSpotChecks() throws {
        // Stack Match a1=0x3, a2=0x5, a3=0x9, a1+a2=0x8, a1+a3=0x4, a2+a3=0x2, all=0x0.
        #expect(try StackEncoding.relayByte(.stackMatchLow, [true, false, false, false]) == 0x3)
        #expect(try StackEncoding.relayByte(.stackMatchLow, [true, true, false, false]) == 0x8)
        #expect(try StackEncoding.relayByte(.stackMatchLow, [true, true, true, false]) == 0x0)
        #expect(try StackEncoding.pins(.stackMatchHigh, [false, true, false, false]) == [-1, -1, -1, -1, 1, 0, 1, 0])
    }

    @Test func subtypeNames() {
        #expect(WIOStackType(subTypeName: "Four Stack (GHE)") == .fourStack)
        #expect(WIOStackType(subTypeName: "OK2ZAW (5-8)") == .ok2zawHigh)
        #expect(WIOStackType(subTypeName: "8 Simple") == nil)
        #expect(WIOSubtypes.builtIn == ["N/A", "RT-21", "Stack Match (1-4)", "Stack Match (5-8)", "Four Stack (GHE)",
                                        "LBS Stack", "OK2ZAW (1-4)", "OK2ZAW (5-8)"])
        #expect(StackEncoding.ok2zawInitialPins(.ok2zawLow) == [1, 1, 1, 1, -1, -1, -1, -1])
        #expect(StackEncoding.ok2zawInitialPins(.lbs) == nil)
    }

    @Test func antennaNamesAreTrimmed() {
        #expect(WIOStackMatch.antennaNames(from: " Yagi1 , Yagi2,Yagi3,") == ["Yagi1", "Yagi2", "Yagi3"])
    }
}
