import Foundation
import GHEKit

/// Saved WIO switch positions, one Java Properties file per switch:
/// `switchstate<URLEncoder.encode(name)>.properties` holding `<name>=<state>`.
/// For On/Off banks the state is the comma-separated list of selected positions.
public actor SwitchStateStore: SwitchStatePersisting {
    public static let prefix = "switchstate"
    public static let suffix = ".properties"

    public let directory: AppDirectories
    private let now: @Sendable () -> Date

    public init(directory: AppDirectories, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `switchstateAnt+Switch.properties` for "Ant Switch".
    public static func fileName(forSwitch name: String) -> String {
        prefix + JavaURLCoding.encode(name) + suffix
    }

    public func fileURL(forSwitch name: String) -> URL { directory.file(Self.fileName(forSwitch: name)) }

    public func loadState(forSwitch name: String) async -> String? {
        guard let data = try? Data(contentsOf: fileURL(forSwitch: name)) else { return nil }
        return JavaProperties.parse(data)[name]
    }

    /// Re-stores whatever else the file held plus `<name>=<state>`, with an empty comment line.
    public func saveState(_ state: String, forSwitch name: String) async {
        let url = fileURL(forSwitch: name)
        var props = (try? Data(contentsOf: url)).map(JavaProperties.parse) ?? JavaProperties()
        props[name] = state
        do {
            try AtomicFile.write(props.serialized(comment: "", date: now()), to: url)
        } catch {
            GHELog.devices.error("Could not save switch state for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Switch names with a saved state file in the folder (decoded from the file names).
    public func savedSwitchNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.root.path)) ?? []
        return files.filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(Self.suffix) }
            .map { JavaURLCoding.decode(String($0.dropFirst(Self.prefix.count).dropLast(Self.suffix.count))) }
            .sorted()
    }
}
