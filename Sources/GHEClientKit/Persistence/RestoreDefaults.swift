import Foundation
import GHEKit

/// Configuration ▸ Restore Defaults… The app asks for confirmation, calls `run`, then quits.
///
/// Deletes everything that describes the setup, including `rotornames.ini`, `presets.json`,
/// `presetFrames.xml` and `phidgets.xml`. Kept: `Images/` (user
/// pictures), logs, and saved passwords (they have their own "Delete saved Passwords…" command).
public enum RestoreDefaults {
    /// Files removed from the client folder.
    public static let files: [String] = [
        ClientFileName.settings, ClientFileName.rotorBands, ClientFileName.rotorMapBands, ClientFileName.rotorStatus,
        ClientFileName.rotorPriority, ClientFileName.rotorBeamWidth, ClientFileName.rotorColors, ClientFileName.rotorMap,
        ClientFileName.rotorMapVisibility, ClientFileName.switchBands, ClientFileName.switchSettings,
        ClientFileName.switchStatus, ClientFileName.switchStatusLegacy,
        ClientFileName.switchWindowsJSON, ClientFileName.mapPriority, ClientFileName.mapPriorityLegacy,
        ClientFileName.switchPriority, ClientFileName.server, ClientFileName.buttonColors,
        ClientFileName.rotorNames, ClientFileName.presetsJSON,
        ClientFileName.presetFrames, ClientFileName.phidgets,
    ]

    /// Files removed from the common folder .
    public static let commonFiles: [String] = [ClientFileName.hotkeysJSON]

    /// Deletes the files; returns the names actually removed.
    @discardableResult
    public static func run(directory: AppDirectories, commonDirectory: AppDirectories? = nil) -> [String] {
        var removed: [String] = []
        let fm = FileManager.default
        func remove(_ names: [String], in dir: AppDirectories) {
            // Exact names on disk, so case-insensitive volumes don't report a file twice.
            let present = MisnamedPropertiesFile.exactNames(in: dir)
            for name in names where present.contains(name) {
                if (try? fm.removeItem(at: dir.file(name))) != nil { removed.append(name) }
            }
        }
        remove(files, in: directory)
        remove(commonFiles, in: commonDirectory ?? directory)
        return removed
    }
}
