import Foundation
import GHEKit

/// The `wioProfiles/` folder: loads every `*.xml`, reports bad files instead of half-building them,
/// and serves profiles by `<devicename>` (the Device Manager subtype).
public actor WioProfileStore: WioProfileLookup {
    public static let directoryName = "wioProfiles"
    /// Built-in Device Manager subtypes; a profile with one of these names is shadowed.
    public static let builtInSubtypes = [
        "N/A", "RT-21", "Stack Match (1-4)", "Stack Match (5-8)", "Four Stack (GHE)", "LBS Stack",
        "OK2ZAW (1-4)", "OK2ZAW (5-8)",
    ]

    public struct Issue: Sendable, Equatable {
        public var file: String
        public var message: String
        public var isError: Bool
    }

    public let directory: URL
    private var byName: [String: WioProfile] = [:]
    private var files: [String: URL] = [:]
    public private(set) var issues: [Issue] = []

    public init(directory: URL) { self.directory = directory }

    /// `<root>/wioProfiles`, created if missing.
    public init(appDirectories: AppDirectories) {
        self.directory = appDirectories.subdirectory(Self.directoryName).root
    }

    /// Re-reads the folder. Files are visited in name order; a duplicate `<devicename>` keeps the
    /// later file (with a warning).
    @discardableResult
    public func reload() -> [Issue] {
        byName = [:]; files = [:]; issues = []
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            let file = url.lastPathComponent
            let r = WioProfileXML.load(from: url)
            for w in r.warnings { issues.append(Issue(file: file, message: w, isError: false)) }
            guard let p = r.profile else {
                for e in r.errors { issues.append(Issue(file: file, message: e, isError: true)) }
                continue
            }
            if let other = files[p.name] {
                issues.append(Issue(file: file, message: "Profile name \"\(p.name)\" is also used by \(other.lastPathComponent); this file wins.", isError: false))
            }
            if Self.builtInSubtypes.contains(p.name) {
                issues.append(Issue(file: file, message: "Profile name \"\(p.name)\" is a built-in subtype and is hidden by it.", isError: false))
            }
            byName[p.name] = p
            files[p.name] = url
        }
        return issues
    }

    public func profile(named name: String) async -> WioProfile? { byName[name] }

    /// Profile names for the Subtype menu, sorted.
    public func profileNames() -> [String] { byName.keys.sorted() }

    public func allProfiles() -> [WioProfile] { byName.keys.sorted().compactMap { byName[$0] } }

    /// The file a profile was loaded from.
    public func fileURL(forProfile name: String) -> URL? { files[name] }

    /// Saves a profile to `fileName` (".xml" added if missing) and reloads.
    @discardableResult
    public func save(_ profile: WioProfile, fileName: String) throws -> URL {
        var name = fileName
        if !name.lowercased().hasSuffix(".xml") { name += ".xml" }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try WioProfileXML.write(profile, to: url)
        reload()
        return url
    }
}
