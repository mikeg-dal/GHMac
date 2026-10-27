import Foundation

/// Encodes and decodes wire lines. Text is CP1252; every
/// encoded line ends with CR LF.
public enum GHWire {
    /// Server → client line bytes, including CR LF.
    public static func encode(_ message: ServerMessage) -> [UInt8] {
        Windows1252.encode(GHServerLineCodec.text(message)) + GHSeparator.crlf
    }

    /// Decodes one server → client line (terminator already removed), using the
    /// client's prefix-dispatch order. Never traps; bad lines → `.ignored`.
    public static func decodeServerLine(_ line: String) -> ServerMessage {
        GHServerLineCodec.decode(line)
    }

    /// Client → server command bytes, including CR LF. Must be < 256 bytes for wire compatibility.
    public static func encode(_ command: ClientCommand) -> [UInt8] {
        Windows1252.encode(GHClientLineCodec.text(command)) + GHSeparator.crlf
    }

    /// Decodes one client → server line as the server would, including the
    /// `\r` split for TURN/SET_STACK/SET_SWITCH/STOP. Malformed lines yield `[]`.
    public static func decodeClientLine(_ line: String) -> [ClientCommand] {
        GHClientLineCodec.decode(line)
    }
}

/// Client side: splits server bytes into lines on `\n`, `\r\n` or a lone `\r`,
/// exactly like `BufferedReader.readLine()`, including a `\r` at the end of one chunk followed
/// by `\n` at the start of the next.
public struct ClientLineDecoder: Sendable {
    /// Lines longer than this are discarded (defensive bound; real lines are < 1 KB).
    static let maxLineBytes = 1 << 20
    private var current: [UInt8] = []
    private var skipLF = false
    private var overflow = false

    public init() {}

    /// Returns complete lines (decoded from CP1252, terminators removed).
    public mutating func push(_ bytes: [UInt8]) -> [String] {
        var lines: [String] = []
        for b in bytes {
            if skipLF {
                skipLF = false
                if b == 0x0A { continue }
            }
            if b == 0x0A || b == 0x0D {
                if !overflow { lines.append(Windows1252.decode(current)) }
                current.removeAll(keepingCapacity: true)
                overflow = false
                skipLF = b == 0x0D
            } else if current.count < Self.maxLineBytes {
                current.append(b)
            } else {
                overflow = true
            }
        }
        return lines
    }
}

/// Server side: turns raw client bytes into user name / 32-byte digest / command lines.
/// Handles well-formed clients: buffers across reads,
/// drops NUL bytes, splits on `\n`, strips a trailing `\r`.
///
/// Phases: in `.awaitingUser` the first non-empty line (trimmed) is the user name, and the
/// assembler then moves to `.awaitingDigest` by itself so a digest coalesced with the user line
/// is not mistaken for text. In `.awaitingDigest` the next 32 raw bytes (NUL, CR and LF included)
/// are the digest; after that, input is held until `markAuthenticated()`. Call `push([])` after
/// `markAuthenticated()` to release any command lines that arrived early.
public struct ServerInputAssembler: Sendable {
    public enum Event: Sendable, Equatable {
        case userName(String)
        case digest([UInt8])
        case line(String)
    }
    public enum Phase: Sendable, Equatable { case awaitingUser, awaitingDigest, authenticated }

    /// Unterminated input beyond this is discarded (defensive bound).
    static let maxBuffered = 64 * 1024
    public private(set) var phase: Phase
    private var buffer: [UInt8] = []
    private var digestDelivered = false

    public init(authenticate: Bool) { phase = authenticate ? .awaitingUser : .authenticated }

    /// Call after sending `PASS:`; the next 32 raw bytes are the digest.
    /// (Idempotent: the assembler already switched phase when it reported the user name.)
    public mutating func expectDigest() {
        if phase != .awaitingDigest {
            phase = .awaitingDigest
            digestDelivered = false
        }
    }
    /// Call after the digest is accepted.
    public mutating func markAuthenticated() { phase = .authenticated }

    public mutating func push(_ bytes: [UInt8]) -> [Event] {
        buffer += bytes
        var events: [Event] = []
        loop: while true {
            switch phase {
            case .awaitingDigest:
                // For wire compatibility: exactly 32 raw bytes, NUL/CR/LF included.
                guard !digestDelivered, buffer.count >= 32 else { break loop }
                events.append(.digest(Array(buffer.prefix(32))))
                buffer.removeFirst(32)
                digestDelivered = true
            case .awaitingUser, .authenticated:
                // NUL keepalives are dropped wherever they land (outside the digest).
                guard let nl = buffer.firstIndex(of: 0x0A) else {
                    if buffer.count > Self.maxBuffered { buffer.removeAll() }
                    if buffer.allSatisfy({ $0 == 0 }) { buffer.removeAll() }
                    break loop
                }
                let raw = buffer[..<nl].filter { $0 != 0 }
                buffer.removeFirst(nl + 1)
                // The trailing CR is stripped from every line, then Java trim().
                let text = JavaString.trim(Windows1252.decode(raw.last == 0x0D ? raw.dropLast() : raw[...]))
                if text.isEmpty { continue }
                if phase == .awaitingUser {
                    events.append(.userName(text))
                    phase = .awaitingDigest
                    digestDelivered = false
                } else {
                    events.append(.line(text))
                }
            }
        }
        return events
    }
}
