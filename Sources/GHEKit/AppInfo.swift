import Foundation

/// Names, links and the disclaimer shown by both apps.
public enum AppInfo {
    public static let productName = "GHMac"
    public static let serverName = "GHMac Server"
    public static let clientName = "GHMac Client"
    public static let projectURL = URL(string: "https://github.com/mikeg-dal/GHMac")!

    /// Shown in each app's About box. Keep in sync with the README.
    public static let disclaimer = """
        An independent, free, personal project. Not affiliated with, endorsed by or supported by \
        Green Heron Engineering. Please don't contact Green Heron Engineering about this software.

        No one provides support for it. Provided "as is", without warranty of any kind (MIT License). \
        Use at your own risk, including any risk to your equipment.
        """

    /// The app's own version from its Info.plist.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
