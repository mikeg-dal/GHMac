import Foundation
@testable import GHEKit

/// Small helpers shared by the codec tests.
enum Hex {
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = hex.utf8.makeIterator()
        func nibble(_ c: UInt8) -> UInt8 {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            default: c - 0x41 + 10
            }
        }
        while let hi = it.next(), let lo = it.next() { out.append(nibble(hi) << 4 | nibble(lo)) }
        return out
    }

    static func string(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func utf8(_ hex: String) -> String { String(decoding: bytes(hex), as: UTF8.self) }
}

/// Reads a tab-separated fixture into rows (UTF-8, "\n" lines, empty lines skipped).
func fixtureRows(_ path: String) throws -> [[String]] {
    let text = String(decoding: try Fixtures.data(path), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map {
        $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Wire text with readable separators: ␟ → U+001F, ␝ → U+001D, ␞ → U+001E, ␍␊ → CR LF.
func wire(_ s: String) -> [UInt8] {
    let t = s.replacingOccurrences(of: "␟", with: "\u{1F}")
        .replacingOccurrences(of: "␝", with: "\u{1D}")
        .replacingOccurrences(of: "␞", with: "\u{1E}")
        .replacingOccurrences(of: "␍", with: "\r")
        .replacingOccurrences(of: "␊", with: "\n")
    return Windows1252.encode(t)
}

func wireText(_ s: String) -> String { Windows1252.decode(wire(s)) }
