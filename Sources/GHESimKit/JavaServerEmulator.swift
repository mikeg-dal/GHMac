import Foundation
import Synchronization
import GHEKit

/// Mimics a server receive loop over in-memory connections,
/// so client tests can check the framing needed for wire compatibility:
/// every received chunk is one `read()` of at most 256 bytes, `trim()`med and split on `\n`;
/// in the PASS stage the digest is compared against the WHOLE chunk.
///
/// Rule breaks are recorded as `violations` instead of being silently tolerated.
public final class JavaServerEmulator: Sendable {
    public enum ViolationKind: String, Sendable, Equatable {
        /// The PASS-stage chunk was not exactly the 32-byte digest (something was coalesced with it).
        case digestNotAlone
        /// A chunk longer than the server's 256-byte read buffer.
        case chunkTooLong
        /// A NUL byte inside a chunk that also carried a command.
        case nulInCommandChunk
    }

    public struct Violation: Sendable, Equatable {
        public var kind: ViolationKind
        public var chunk: [UInt8]
    }

    public enum Phase: Sendable, Equatable { case awaitingUser, awaitingDigest, authenticated, closed }

    /// One accepted connection.
    public final class Session: Sendable {
        public let index: Int
        let server: MemoryStreamConnection
        let client: MemoryStreamConnection
        fileprivate struct State {
            var phase: Phase
            var user: String?
            var chunks: [[UInt8]] = []
            var commands: [String] = []
            var pings = 0
            var violations: [Violation] = []
            var eof = false
            var quit = false
        }
        fileprivate let state: Mutex<State>

        fileprivate init(index: Int, authenticate: Bool, server: MemoryStreamConnection, client: MemoryStreamConnection) {
            self.index = index
            self.server = server
            self.client = client
            state = Mutex(State(phase: authenticate ? .awaitingUser : .authenticated))
        }

        public var phase: Phase { state.withLock { $0.phase } }
        public var user: String? { state.withLock { $0.user } }
        /// Every chunk received, exactly as delivered (one per client write).
        public var chunks: [[UInt8]] { state.withLock { $0.chunks } }
        /// Command lines parsed (`\n` split, trailing `\r` removed for convenience).
        public var commands: [String] { state.withLock { $0.commands } }
        /// Chunks that trimmed to nothing and were only NUL bytes (keepalives).
        public var pings: Int { state.withLock { $0.pings } }
        public var violations: [Violation] { state.withLock { $0.violations } }
        /// The client closed its end.
        public var sawEOF: Bool { state.withLock { $0.eof } }
        public var sawQuit: Bool { state.withLock { $0.quit } }

        /// Sends one server line (CP1252 + CR LF).
        public func send(_ line: String) async {
            try? await server.send(Windows1252.encode(line) + GHSeparator.crlf)
        }

        /// Sends raw bytes (e.g. several lines in one TCP segment).
        public func sendRaw(_ bytes: [UInt8]) async { try? await server.send(bytes) }

        /// Closes the server end: the client sees EOF.
        public func close() async {
            state.withLock { $0.phase = .closed }
            await server.close()
        }

        /// TCP reset.
        public func reset() { server.reset() }
    }

    private struct State {
        var sessions: [Session] = []
        var refuse = false
        var connectAttempts = 0
    }

    public let authenticate: Bool
    public let challenge: String
    /// user → P (password hash).
    public let users: [String: [UInt8]]
    /// Lines sent right after a successful login (auth on) or right after accept (auth off).
    public let inventory: [String]
    private let state = Mutex(State())

    public init(authenticate: Bool = false, users: [String: [UInt8]] = [:],
                challenge: String = "0.7316931046151538-81283467123456789011665432101234",
                inventory: [String] = []) {
        self.authenticate = authenticate
        self.users = users
        self.challenge = challenge
        self.inventory = inventory
    }

    /// Makes connections refused (server down) until set back to false.
    public var refusesConnections: Bool {
        get { state.withLock { $0.refuse } }
        set { state.withLock { $0.refuse = newValue } }
    }

    public var sessions: [Session] { state.withLock { $0.sessions } }
    public var current: Session? { state.withLock { $0.sessions.last } }
    public var connectAttempts: Int { state.withLock { $0.connectAttempts } }

    /// A connector for `GHServerConnection`; each connect is a new session.
    public func connector() -> MemoryConnector {
        MemoryConnector { host, _ in try await self.accept(clientAddress: "127.0.0.1", serverAddress: host) }
    }

    private func accept(clientAddress: String, serverAddress: String) async throws -> any StreamConnection {
        let refuse = state.withLock { s -> Bool in s.connectAttempts += 1; return s.refuse }
        if refuse { throw TransportError.openFailed("Connection refused") }
        let (client, server) = MemoryStreamConnection.pair(clientAddress: clientAddress, serverAddress: serverAddress)
        let session = state.withLock { s -> Session in
            let session = Session(index: s.sessions.count, authenticate: authenticate, server: server, client: client)
            s.sessions.append(session)
            return session
        }
        if authenticate {
            await session.send("USER:")
        } else {
            for line in inventory { await session.send(line) }
        }
        Task { await self.receiveLoop(session) }
        return client
    }

    private func receiveLoop(_ session: Session) async {
        do {
            for try await chunk in session.server.incoming {
                await handle(chunk, session)
            }
        } catch {}
        session.state.withLock { $0.eof = true }
    }

    private func handle(_ chunk: [UInt8], _ session: Session) async {
        let phase = session.state.withLock { s -> Phase in
            s.chunks.append(chunk)
            if chunk.count > 256 { s.violations.append(Violation(kind: .chunkTooLong, chunk: chunk)) }
            return s.phase
        }
        let raw = JavaString.trim(Windows1252.decode(chunk))
        if raw.isEmpty {
            if chunk.allSatisfy({ $0 == 0 }) { session.state.withLock { $0.pings += 1 } }
            return
        }
        switch phase {
        case .awaitingUser:
            session.state.withLock { $0.user = raw; $0.phase = .awaitingDigest }
            await session.send("PASS:" + challenge)
        case .awaitingDigest:
            let user = session.user ?? ""
            let expected = users[user].map { GHAuth.response(user: user, challenge: challenge, passwordHash: $0) }
            if chunk.count != 32 {
                session.state.withLock { $0.violations.append(Violation(kind: .digestNotAlone, chunk: chunk)) }
            }
            if let expected, expected == chunk {
                session.state.withLock { $0.phase = .authenticated }
                for line in inventory { await session.send(line) }
                await session.send("")   // the always-empty LOCATIONS line
            } else {
                await session.send("INVALID USER/PASS")
                await session.send("CLOSE")
                await session.close()
            }
        case .authenticated:
            session.state.withLock { s in
                if chunk.contains(0) { s.violations.append(Violation(kind: .nulInCommandChunk, chunk: chunk)) }
                for line in JavaString.split(raw, separator: "\n") {
                    let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    s.commands.append(clean)
                    if JavaString.startsWith(line, "QUIT") { s.quit = true }
                }
            }
        case .closed:
            break
        }
    }
}
