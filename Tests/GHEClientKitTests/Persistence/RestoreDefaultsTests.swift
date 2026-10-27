import Foundation
import Testing
import GHEKit
@testable import GHEClientKit

@Suite("Restore Defaults")
struct RestoreDefaultsTests {
    @Test("Restore Defaults deletes the explicit list, keeps Images")
    func restoreDefaults() throws {
        let dir = AppDirectories.temporary(prefix: "test-restore")
        defer { try? FileManager.default.removeItem(at: dir.root) }
        for name in ["settings.ini", "rotornames.ini", "presets.json", "presetFrames.xml", "phidgets.xml",
                     "server.ini", "switchtatus.ini", "hotkeys.json", "gh_client_output.txt"] {
            try PersistenceFixtures.write("x", to: dir.file(name))
        }
        try PersistenceFixtures.write("png", to: dir.subdirectory("Images").file("compass.png"))
        let removed = RestoreDefaults.run(directory: dir)
        #expect(Set(removed) == ["settings.ini", "rotornames.ini", "presets.json", "presetFrames.xml", "phidgets.xml",
                                 "server.ini", "switchtatus.ini", "hotkeys.json"])
        let left = MisnamedPropertiesFile.exactNames(in: dir)
        #expect(left == ["Images", "gh_client_output.txt"])
        #expect(RestoreDefaults.files.contains("mappriority.ini") && RestoreDefaults.files.contains("rotornames.ini"))
    }
}
