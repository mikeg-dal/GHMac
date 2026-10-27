import Foundation
import GHEKit

/// One accepted client socket.
///
/// Three tasks per connection:
/// - **reader**: feeds `ServerInputAssembler`, runs the auth state machine and queues command lines;
/// - **commands**: executes queued lines in order, so slow device work never blocks reading
///   while one client's commands stay strictly ordered;
/// - **writer**: drains the outbox, so replies and broadcasts never interleave mid-line.
///
/// EOF, a reset and `QUIT` all end in the same cleanup.
actor ClientConnection: CommandClient {
    private enum OutItem: Sendable {
        case bytes([UInt8])
        /// Close the socket after everything queued before it was written.
        case close
    }
    private enum AuthState: Equatable { case awaitingUser, awaitingDigest, authenticated, closing }

    nonisolated let id: UInt64
    nonisolated let address: String
    nonisolated let stream: any StreamConnection

    private let hub: ServerHub
    private let router: CommandRouter
    private let credentials: any CredentialLookup
    private let clock: any GHEClock
    private let authenticate: Bool

    private var assembler: ServerInputAssembler
    private var state: AuthState
    private var user: String?
    private var challenge: String?
    private var quitting = false
    private var started = false

    private nonisolated let outbox: AsyncStream<OutItem>.Continuation
    private let outboxStream: AsyncStream<OutItem>
    private nonisolated let commands: AsyncStream<String>.Continuation
    private let commandStream: AsyncStream<String>

    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var authTimer: Task<Void, Never>?

    init(id: UInt64, stream: any StreamConnection, hub: ServerHub, router: CommandRouter,
         credentials: any CredentialLookup, clock: any GHEClock, authenticate: Bool) {
        self.id = id
        self.address = stream.peerAddress
        self.stream = stream
        self.hub = hub
        self.router = router
        self.credentials = credentials
        self.clock = clock
        self.authenticate = authenticate
        assembler = ServerInputAssembler(authenticate: authenticate)
        state = authenticate ? .awaitingUser : .authenticated
        (outboxStream, outbox) = AsyncStream<OutItem>.makeStream()
        (commandStream, commands) = AsyncStream<String>.makeStream()
    }

    // MARK: Output (callable from anywhere, ordered)

    /// Queues one already-encoded line.
    nonisolated func enqueue(_ bytes: [UInt8]) { outbox.yield(.bytes(bytes)) }

    nonisolated func send(_ message: ServerMessage) { enqueue(GHWire.encode(message)) }

    nonisolated func reply(_ message: ServerMessage) { send(message) }

    /// Sends `CLOSE` and then closes the socket (server stop, RESTART, auth failure/timeout, over limit).
    nonisolated func closeWithCLOSE() {
        send(.close)
        outbox.yield(.close)
    }

    // MARK: Lifecycle

    /// Starts the tasks. With authentication on, sends `USER:` and starts the 5 s auth timer.
    func start() {
        guard !started else { return }
        started = true
        let stream = stream
        let outItems = outboxStream
        writerTask = Task {
            var dead = false
            for await item in outItems {
                switch item {
                case .bytes(let b):
                    guard !dead else { continue }
                    do { try await stream.send(b) } catch {
                        // Peer gone mid-broadcast: stop writing; closing ends the reader too.
                        dead = true
                        await stream.close()
                    }
                case .close:
                    dead = true
                    await stream.close()
                }
            }
        }
        let lines = commandStream
        commandTask = Task {
            for await line in lines { await self.process(line) }
            await self.finished()
        }
        if authenticate {
            send(.user)
            let clock = clock
            authTimer = Task {
                do { try await clock.sleep(for: Timing.authTimeout) } catch { return }
                await self.authTimedOut()
            }
        }
        readerTask = Task {
            do {
                for try await chunk in stream.incoming { await self.received(chunk) }
            } catch {}
            self.inputEnded()
        }
    }

    // MARK: Input

    private func received(_ chunk: [UInt8]) async {
        guard state != .closing else { return }
        let wasAwaitingUser = state == .awaitingUser
        let sawUser = await handle(assembler.push(chunk))
        // An empty user line (e.g. the Local Controller's "") is skipped by the assembler; a chunk that
        // ended a line without producing a user name means the name was empty.
        if wasAwaitingUser, !sawUser, state == .awaitingUser, chunk.contains(0x0A) {
            await handleUser("")
        }
    }

    /// Returns true if a user name was among the events.
    @discardableResult
    private func handle(_ events: [ServerInputAssembler.Event]) async -> Bool {
        var sawUser = false
        for event in events {
            guard state != .closing else { break }
            switch event {
            case .userName(let name):
                sawUser = true
                await handleUser(name)
            case .digest(let bytes):
                await handleDigest(bytes)
            case .line(let line):
                guard state == .authenticated, !quitting else { continue }
                let trimmed = JavaString.trim(line)
                guard !trimmed.isEmpty else { continue }
                // Every inbound command is echoed to the log as "<cmd>\t \t<ip>". Logged here, on the
                // read path, so the log shows arrival order even while an earlier command is still running.
                await hub.log("\(trimmed)\t \t\(address)")
                commands.yield(trimmed)
            }
        }
        return sawUser
    }

    private func handleUser(_ raw: String) async {
        guard state == .awaitingUser else { return }
        let name = JavaString.trim(raw)   // the trimmed chunk is the user name
        if name.isEmpty {
            // Reject an empty user name at once instead of a silent 5 s timeout.
            await reject()
            return
        }
        user = name
        let text = GHAuth.makeChallenge()
        challenge = text
        send(.pass(challenge: text))
        assembler.expectDigest()
        state = .awaitingDigest
    }

    private func handleDigest(_ digest: [UInt8]) async {
        guard state == .awaitingDigest, let user, let challenge else { return }
        // A fresh hash per check (GHAuth), nothing shared between connections.
        let stored = await credentials.passwordHash(for: user)
        guard state == .awaitingDigest else { return }   // timed out while looking up
        guard let stored, GHAuth.response(user: user, challenge: challenge, passwordHash: stored) == digest else {
            await reject()
            return
        }
        authTimer?.cancel()
        authTimer = nil
        assembler.markAuthenticated()
        state = .authenticated
        await hub.clientAuthenticated(self, user: user)
        // Commands that arrived right behind the digest were held by the assembler until now.
        await handle(assembler.push([]))
    }

    /// `INVALID USER/PASS`, `CLOSE`, close.
    private func reject() async {
        authTimer?.cancel()
        authTimer = nil
        state = .closing
        send(.invalidUserPass)
        closeWithCLOSE()
        await hub.log("Invalid user/pass: \t \t\(address)")
    }

    private func authTimedOut() async {
        guard state == .awaitingUser || state == .awaitingDigest else { return }
        state = .closing
        await hub.log("Auth Timout: \t \t\(address)")
        // Send CLOSE before closing so the client reacts at once.
        closeWithCLOSE()
    }

    /// EOF or reset: let queued commands finish, then clean up.
    private func inputEnded() {
        state = .closing
        authTimer?.cancel()
        authTimer = nil
        commands.finish()
    }

    // MARK: Commands

    private func process(_ line: String) async {
        guard !quitting else { return }
        for command in CommandRouter.parse(line) {
            guard !quitting else { return }
            await router.execute(command, from: self)
        }
    }

    func quit() async {
        guard !quitting else { return }
        quitting = true
        await hub.log("Disconnecting: \t \t\(address)")
        outbox.yield(.close)   // no CLOSE on QUIT
    }

    /// Single cleanup path after the command queue drained (EOF, reset, QUIT, server close).
    private func finished() async {
        outbox.yield(.close)
        outbox.finish()
        await hub.connectionEnded(self)
    }
}
