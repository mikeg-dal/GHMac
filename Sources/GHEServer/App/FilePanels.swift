import AppKit
import UniformTypeIdentifiers

/// Open/save panels used by the File menu.
@MainActor
enum FilePanels {
    /// File ▸ Save Log…
    static func saveLog(_ log: LogBuffer) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ServerLog \(Self.stamp()).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(log.allText.utf8).write(to: url, options: .atomic) } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: Date())
    }
}
