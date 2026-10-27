import Foundation

/// Splits a byte stream into lines like Java's `BufferedReader.readLine` (`\n`, `\r` or
/// `\r\n`), keeping partial lines across chunks.
// One framer per connection, so lines that arrive together are all delivered.
public struct N3FJPLineFramer: Sendable {
    private var buffer: [UInt8] = []
    private var skipLF = false
    public init() {}

    public mutating func push(_ bytes: some Sequence<UInt8>) -> [String] {
        var lines: [String] = []
        for b in bytes {
            if skipLF { skipLF = false; if b == 0x0A { continue } }
            if b == 0x0A || b == 0x0D {
                lines.append(LoggerText.decode(buffer)); buffer.removeAll(keepingCapacity: true)
                skipLF = b == 0x0D
            } else {
                buffer.append(b)
            }
        }
        return lines
    }

    /// The trailing partial line at end of stream (readLine returns it), if any.
    public mutating func flush() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : LoggerText.decode(buffer)
    }
}
