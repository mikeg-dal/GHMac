import Foundation
import Testing
@testable import GHEServerKit

@Suite("TrigUtils (west-positive longitudes)")
struct TrigUtilsTests {
    /// Standard initial-bearing formula with EAST-positive longitudes, for cross-checking.
    static func reference(_ lat1: Double, _ lonEast1: Double, _ lat2: Double, _ lonEast2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lonEast2 - lonEast1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let b = atan2(y, x) * 180 / .pi
        return b <= 0 ? b + 360 : b   // range is (0, 360]
    }

    @Test func cardinalDirections() throws {
        // From 0,0: north → 360, west (positive lon) → 270, east (negative lon) → 90, south → 180.
        #expect(try #require(TrigUtils.heading(fromLatitude: 0, fromLongitude: 0, toLatitude: 10, toLongitude: 0)) == 360)
        #expect(abs(try #require(TrigUtils.heading(fromLatitude: 0, fromLongitude: 0, toLatitude: 0, toLongitude: 10)) - 270) < 1e-9)
        #expect(abs(try #require(TrigUtils.heading(fromLatitude: 0, fromLongitude: 0, toLatitude: 0, toLongitude: -10)) - 90) < 1e-9)
        #expect(abs(try #require(TrigUtils.heading(fromLatitude: 0, fromLongitude: 0, toLatitude: -10, toLongitude: 0)) - 180) < 1e-9)
    }

    @Test func knownPaths() throws {
        // W1AW (41.7147 N, 72.7272 W) → London (51.5074 N, 0.1278 W): about 52.2°.
        let london = try #require(TrigUtils.heading(fromLatitude: 41.7147, fromLongitude: 72.7272,
                                                    toLatitude: 51.5074, toLongitude: 0.1278))
        #expect(abs(london - 52.2) < 0.1)
        // W1AW → Tokyo (35.6762 N, 139.6503 E = -139.6503 west-positive): about 334°.
        let tokyo = try #require(TrigUtils.heading(fromLatitude: 41.7147, fromLongitude: 72.7272,
                                                   toLatitude: 35.6762, toLongitude: -139.6503))
        #expect(abs(tokyo - 334.0) < 0.1)
    }

    /// Golden values computed under Java 8.
    @Test func matchesJava8() throws {
        let golden: [(Double, Double, Double, Double, Double)] = [
            (41.7147, 72.7272, 51.5074, 0.1278, 52.218377957745176),
            (41.7147, 72.7272, 35.6762, -139.6503, 333.99933551293213),
            (0, 0, 10, 0, 360.0),
            (0, 0, 0, 10, 270.0),
            (0, 0, 0, -10, 90.0),
            (45.5, 122.6, -33.9, -151.2, 242.55248677287392),
        ]
        for g in golden {
            let h = try #require(TrigUtils.heading(fromLatitude: g.0, fromLongitude: g.1, toLatitude: g.2, toLongitude: g.3))
            #expect(abs(h - g.4) < 1e-9, "\(g)")
        }
        // The same point (10, 20 → 10, 20) returns nil.
    }

    @Test func matchesTheStandardFormula() throws {
        let points: [(Double, Double)] = [(41.7, -72.7), (51.5, -0.1), (35.7, 139.7), (-33.9, 151.2), (64.1, -21.9),
                                          (-22.9, -43.2), (1.3, 103.8), (19.4, -99.1), (60.2, 24.9)]
        for a in points {
            for b in points where a != b {
                // Convert east-positive test data to the west-positive convention.
                let h = try #require(TrigUtils.heading(fromLatitude: a.0, fromLongitude: -a.1, toLatitude: b.0, toLongitude: -b.1))
                let r = Self.reference(a.0, a.1, b.0, b.1)
                #expect(abs(h - r) < 1e-6, "\(a) → \(b): \(h) vs \(r)")
            }
        }
    }

    @Test func nanCasesAreNil() {
        #expect(TrigUtils.heading(fromLatitude: 10, fromLongitude: 20, toLatitude: 10, toLongitude: 20) == nil)
        #expect(TrigUtils.heading(fromLatitude: .nan, fromLongitude: 0, toLatitude: 1, toLongitude: 1) == nil)
        #expect(TrigUtils.heading(fromLatitude: 0, fromLongitude: 0, toLatitude: .infinity, toLongitude: 1) == nil)
    }

    @Test func distance() {
        // A quarter of the equator is π/2 radians.
        #expect(abs(TrigUtils.distance(fromLatitude: 0, fromLongitude: 0, toLatitude: 0, toLongitude: 90) - .pi / 2) < 1e-12)
    }
}
