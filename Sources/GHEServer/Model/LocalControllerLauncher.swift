import AppKit

/// Settings ▸ Launch Local Controller…: opens the GHMac Client app with `-LocalController <port>`.
enum LocalControllerLauncher {
    static let clientBundleID = "com.mikegarcia.GHMacClient"
    static let clientAppName = "GHMac Client.app"

    /// The client next to this app, else wherever Launch Services knows it.
    static func clientAppURL() -> URL? {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(clientAppName)
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: clientBundleID)
    }

    static func launch(_ url: URL, port: Int, completion: @escaping @MainActor (Error?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-LocalController", String(port)]
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Task { @MainActor in completion(error) }
        }
    }
}
