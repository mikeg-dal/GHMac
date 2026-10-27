import Foundation
import GHEKit
import GHEServerKit

/// Launch argument that switches an app into simulator mode: `-GHESimulator demo`.
public enum GHESimulator {
    public static let argument = "-GHESimulator"

    /// The scenario name if the app was launched in simulator mode.
    public static var requestedScenario: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: argument) else { return nil }
        return i + 1 < args.count ? args[i + 1] : "demo"
    }
}
