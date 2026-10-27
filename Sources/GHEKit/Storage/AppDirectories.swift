import Foundation
import os

/// Where each app keeps its files: Application Support, inside the sandbox container.
public struct AppDirectories: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/<folderName>/`, created if missing.
    public static func applicationSupport(folderName: String) -> AppDirectories {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = AppDirectories(root: base.appendingPathComponent(folderName, isDirectory: true))
        dir.ensureExists()
        return dir
    }

    /// A fresh temporary directory (tests, simulator mode).
    public static func temporary(prefix: String = "GHE") -> AppDirectories {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let dir = AppDirectories(root: url)
        dir.ensureExists()
        return dir
    }

    public static let serverFolderName = "GHMac Server"
    public static let clientFolderName = "GHMac Client"

    public func file(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: false) }

    public func subdirectory(_ name: String) -> AppDirectories {
        let d = AppDirectories(root: root.appendingPathComponent(name, isDirectory: true))
        d.ensureExists()
        return d
    }

    public func ensureExists() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// Writes data atomically (temp file + rename).
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Shared loggers.
public enum GHELog {
    public static let subsystem = "com.mikegarcia.GHMac"
    public static let transport = Logger(subsystem: subsystem, category: "transport")
    public static let wire = Logger(subsystem: subsystem, category: "wire")
    public static let devices = Logger(subsystem: subsystem, category: "devices")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let integrations = Logger(subsystem: subsystem, category: "integrations")
}
