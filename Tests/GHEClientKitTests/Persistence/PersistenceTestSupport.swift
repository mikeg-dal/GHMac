import Foundation
import GHEKit
@testable import GHEClientKit

/// Helpers for the persistence tests.
enum PersistenceFixtures {
    static func data(_ name: String) throws -> Data { try Fixtures.data("client/" + name) }

    static let tower = "Tower 40m\u{1E}:17220"
    static let yagi = "Yagi Top\u{1E}:17220"
    static let bandSwitch = "Band SW\u{1E}:17220"

    /// Lines of a Properties file without the `#<date>` line, as a set (Java writes Hashtable order).
    static func bodyLines(_ data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1 { lines.remove(at: 1) } // the date line (after the comment line)
        return Set(lines.filter { !$0.isEmpty })
    }

    static func write(_ text: String, to url: URL) throws {
        try AtomicFile.write(Data(text.utf8), to: url)
    }
}
