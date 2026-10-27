import Foundation

/// One line of client ⇄ server traffic, for the traffic window and diagnostics.
public struct TrafficEntry: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        /// Server → client.
        case incoming
        /// Client → server.
        case outgoing
        /// Something the client decided (dropped command, connection state).
        case note
    }
    public var server: ServerID
    public var direction: Direction
    /// Printable text: separators shown as `␟` / `␝`, the digest as `<32-byte digest>`, a ping as `<NUL>`.
    public var text: String

    public init(server: ServerID, direction: Direction, text: String) {
        self.server = server; self.direction = direction; self.text = text
    }

    /// Makes wire text readable (US → ␟, GS → ␝, CR/LF dropped).
    public static func printable(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x1F: out += "␟"
            case 0x1D: out += "␝"
            case 0x1E: out += "␞"
            case 0x0D, 0x0A: break
            case 0x00: out += "<NUL>"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Receives traffic entries from connection actors (any thread).
public typealias TrafficSink = @Sendable (TrafficEntry) -> Void
