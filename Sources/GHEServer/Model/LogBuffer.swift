import Foundation
import Observation
import GHEKit

/// The server log window's contents.
///
/// * A ring buffer of the newest `capacity` lines instead of clearing at 1000 lines.
/// * Dates use `yyyy` (calendar year), not week-year.
/// * File ▸ Server Logging appends every line to `ServerLog.txt` as `<date>  <text>`; the flag is read
///   per line, so it applies at once.
@Observable
final class LogBuffer {
    struct Entry: Equatable {
        let sequence: Int
        let text: String
    }

    let capacity: Int
    private(set) var entries: [Entry] = []
    /// Sequence number of the newest line (0 = none yet). Views watch this.
    private(set) var lastSequence = 0
    @ObservationIgnored var logToFile = false
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private var fileHandle: FileHandle?

    init(capacity: Int = 5000, fileURL: URL) {
        self.capacity = capacity
        self.fileURL = fileURL
    }

    /// `yyyy`, not `YYYY`.
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd MMM yyyy  HH:mm:ss"
        return f
    }()

    /// Adds one line: US/RS separators become spaces, the date is appended (`<text>    <date>`).
    func append(_ raw: String, date: Date = Date()) {
        let text = raw.replacingOccurrences(of: "\u{1F}", with: " ").replacingOccurrences(of: "\u{1E}", with: " ")
        let stamp = Self.dateFormatter.string(from: date)
        lastSequence += 1
        entries.append(Entry(sequence: lastSequence, text: "\(text)    \(stamp)"))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        if logToFile { writeToFile("\(stamp)  \(text)\n") }
    }

    /// Lines newer than `sequence`, and whether older ones were dropped in between.
    func entries(after sequence: Int) -> (lines: [Entry], gap: Bool) {
        guard let first = entries.first else { return ([], false) }
        if sequence < first.sequence - 1 { return (entries, true) }
        let start = max(0, sequence - first.sequence + 1)
        return (start < entries.count ? Array(entries[start...]) : [], false)
    }

    var allText: String { entries.map(\.text).joined(separator: "\n") + (entries.isEmpty ? "" : "\n") }

    private func writeToFile(_ line: String) {
        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            _ = try? fileHandle?.seekToEnd()
        }
        guard let fileHandle else { return }
        do { try fileHandle.write(contentsOf: Data(line.utf8)) } catch {
            GHELog.ui.error("ServerLog.txt write failed: \(error.localizedDescription, privacy: .public)")
            try? fileHandle.close()
            self.fileHandle = nil
        }
    }

    func closeFile() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}
