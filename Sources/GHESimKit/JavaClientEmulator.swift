import Foundation
import GHEKit

/// A scripted client for tests and the simulator.
///
/// It writes `user` CR LF, the raw 32-byte
/// digest alone with no terminator, single NUL keepalives, CR LF commands, one write each — plus
/// helpers to coalesce or split writes the way TCP might. Received bytes are split into lines like
/// Java's `BufferedReader.readLine()` (`\n`, `\r\n` or a lone `\r`), decoded as CP1252.
public actor JavaClientEmulator {
    public enum EmulatorError: Error, Equatable {
        case timeout(String)
        case closed
    }

    public nonisolated let connection: any StreamConnection
    public private(set) var receivedLines: [String] = []
    public private(set) var receivedBytes: [UInt8] = []
    /// True once the server closed the connection (EOF or reset).
    public private(set) var isClosed = false

    private var pending: [UInt8] = []
    private var lastWasCR = false
    private var reader: Task<Void, Never>?

    public init(connection: any StreamConnection) {
        self.connection = connection
    }

    /// Starts recording what the server sends. Called by the convenience constructors.
    public func start() {
        guard reader == nil else { return }
        let conn = connection
        reader = Task {
            do {
                for try await chunk in conn.incoming { self.ingest(chunk) }
            } catch {}
            self.markClosed()
        }
    }

    // MARK: Sending (each call = one write = one chunk at the server)

    /// One text line + CR LF in a single write.
    public func send(_ line: String) async throws {
        try await sendRaw(Windows1252.encode(line) + GHSeparator.crlf)
    }

    /// Several lines in ONE write, as Nagle coalescing would deliver them.
    public func sendCoalesced(_ lines: [String]) async throws {
        try await sendRaw(lines.flatMap { Windows1252.encode($0) + GHSeparator.crlf })
    }

    /// One line (+ CR LF) split into two writes after `splitAt` bytes.
    public func sendSplit(_ line: String, at splitAt: Int) async throws {
        let bytes = Windows1252.encode(line) + GHSeparator.crlf
        let cut = min(max(0, splitAt), bytes.count)
        try await sendRaw(Array(bytes[..<cut]))
        try await sendRaw(Array(bytes[cut...]))
    }

    /// The keepalive: a single 0x00 byte.
    public func sendKeepalive() async throws { try await sendRaw([0x00]) }

    public func sendRaw(_ bytes: [UInt8]) async throws {
        try await connection.send(bytes)
    }

    /// Closes the socket. `QUIT` is never actually flushed.
    public func disconnect() async {
        await connection.close()
    }

    // MARK: Authentication

    /// Waits for `USER:`, sends the user line, waits for `PASS:<challenge>`, sends the 32-byte digest alone.
    public func login(user: String, password: String, timeout: Duration = .seconds(2)) async throws {
        try await login(user: user, passwordHash: GHAuth.passwordHash(user: user, password: password), timeout: timeout)
    }

    /// Same with the stored hash P.
    public func login(user: String, passwordHash: [UInt8], timeout: Duration = .seconds(2)) async throws {
        _ = try await waitForLine(timeout: timeout) { $0.hasPrefix("USER:") }
        try await send(user)
        let pass = try await waitForLine(timeout: timeout) { $0.hasPrefix("PASS:") }
        let challenge = JavaString.split(pass, separator: ":", limit: 2).dropFirst().first ?? ""
        try await sendRaw(GHAuth.response(user: user, challenge: challenge, passwordHash: passwordHash))
    }

    // MARK: Waiting (real time; the server under test may still use a ManualClock)

    /// Returns the first received line matching `predicate`, waiting up to `timeout`.
    @discardableResult
    public func waitForLine(timeout: Duration = .seconds(2), _ predicate: @Sendable (String) -> Bool) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let l = receivedLines.first(where: predicate) { return l }
            if isClosed { throw EmulatorError.closed }
            if ContinuousClock.now >= deadline { throw EmulatorError.timeout("no matching line in \(receivedLines)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Waits until at least `count` lines arrived; returns all received lines.
    @discardableResult
    public func waitForLines(_ count: Int, timeout: Duration = .seconds(2)) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while receivedLines.count < count {
            if isClosed { throw EmulatorError.closed }
            if ContinuousClock.now >= deadline { throw EmulatorError.timeout("have \(receivedLines)") }
            try await Task.sleep(for: .milliseconds(2))
        }
        return receivedLines
    }

    /// Waits until the server closed the connection.
    public func waitUntilClosed(timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isClosed {
            if ContinuousClock.now >= deadline { throw EmulatorError.timeout("still open; lines \(receivedLines)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    public func clearReceived() {
        receivedLines.removeAll()
        receivedBytes.removeAll()
    }

    // MARK: Reading

    private func ingest(_ chunk: [UInt8]) {
        receivedBytes += chunk
        for b in chunk {
            if b == 0x0A {
                if lastWasCR { lastWasCR = false; continue }   // second half of CR LF
                flushLine()
            } else if b == 0x0D {
                flushLine()
                lastWasCR = true
                continue
            } else {
                pending.append(b)
            }
            lastWasCR = false
        }
    }

    private func flushLine() {
        receivedLines.append(Windows1252.decode(pending))
        pending.removeAll()
    }

    private func markClosed() { isClosed = true }
}
