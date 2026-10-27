import Foundation
import GHEKit

/// One `java.util.Properties` file in the client folder, read and written for file compatibility
/// (ISO-8859-1, `\uXXXX` escapes, a comment line plus a `#<date>` line). Writes are atomic.
public struct PropertiesFile: Sendable {
    public let url: URL
    /// The comment written on the first line (`""` writes a bare `#`, nil writes none).
    public let comment: String?

    public init(url: URL, comment: String?) {
        self.url = url
        self.comment = comment
    }

    public init(_ directory: AppDirectories, _ name: String, comment: String?) {
        self.init(url: directory.file(name), comment: comment)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The file's entries, or nil when the file does not exist (or cannot be read).
    public func read() -> JavaProperties? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JavaProperties.parse(data)
    }

    public func readOrEmpty() -> JavaProperties { read() ?? JavaProperties() }

    public func write(_ properties: JavaProperties, date: Date = Date()) throws {
        try AtomicFile.write(properties.serialized(comment: comment, date: date), to: url)
    }

    /// Load-modify-store, keeping every key the caller does not touch (other writers share these files).
    @discardableResult
    public func update(_ body: (inout JavaProperties) -> Void) throws -> JavaProperties {
        var p = readOrEmpty()
        body(&p)
        try write(p)
        return p
    }
}

extension JavaProperties {
    /// All entries in document order.
    public var entries: [(key: String, value: String)] { keys.map { ($0, self[$0] ?? "") } }

    /// Copies every entry of `other` over this document (other wins).
    public mutating func merge(_ other: JavaProperties, overwrite: Bool = true) {
        for k in other.keys where overwrite || self[k] == nil { self[k] = other[k] }
    }

    /// `Properties.getProperty(key, default)`.
    public func value(_ key: String, default defaultValue: String) -> String { self[key] ?? defaultValue }
}

/// File names that were written under one name and read under another. GHMac reads both,
/// writes the canonical name, and removes the stray one on the next write.
public struct MisnamedPropertiesFile: Sendable {
    public let directory: AppDirectories
    public let canonical: String
    public let legacy: String
    /// Whose value wins when both files hold the same key.
    public let legacyWins: Bool
    public let comment: String?

    public var file: PropertiesFile { PropertiesFile(directory, canonical, comment: comment) }

    /// Entries of both files merged. Nil when neither exists.
    public func read() -> JavaProperties? {
        let names = Self.exactNames(in: directory)
        let canonicalDoc = names.contains(canonical) || !names.contains(legacy)
            ? PropertiesFile(directory, canonical, comment: nil).read() : nil
        let legacyDoc = names.contains(legacy) ? PropertiesFile(directory, legacy, comment: nil).read() : nil
        switch (canonicalDoc, legacyDoc) {
        case (nil, nil): return nil
        case (let c?, nil): return c
        case (nil, let l?): return l
        case (var c?, let l?):
            c.merge(l, overwrite: legacyWins)
            return c
        }
    }

    public func readOrEmpty() -> JavaProperties { read() ?? JavaProperties() }

    /// Load (merged) - modify - store under the canonical name, removing the legacy-named file.
    @discardableResult
    public func update(_ body: (inout JavaProperties) -> Void) throws -> JavaProperties {
        var p = readOrEmpty()
        body(&p)
        if Self.exactNames(in: directory).contains(legacy) {
            try? FileManager.default.removeItem(at: directory.file(legacy))
        }
        try file.write(p)
        return p
    }

    /// Exact (case-preserving) file names in the folder, so case-insensitive volumes are handled.
    static func exactNames(in directory: AppDirectories) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.root.path)) ?? [])
    }
}
