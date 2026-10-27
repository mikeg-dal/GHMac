import Foundation
import Testing
import GHEKit

/// Polls `condition` until it holds or `timeout` passes (real time).
func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Locates a fixture under Tests/Fixtures by relative path.
enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
}
