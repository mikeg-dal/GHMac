import Foundation
import Synchronization
import GHEKit
@testable import GHEClientKit

/// Collects a connection's events in the background.
final class EventLog: Sendable {
    private let events = Mutex<[ConnectionEvent]>([])
    private let ended = Mutex(false)

    func start(_ stream: AsyncStream<ConnectionEvent>) {
        Task {
            for await e in stream { events.withLock { $0.append(e) } }
            ended.withLock { $0 = true }
        }
    }

    var all: [ConnectionEvent] { events.withLock { $0 } }
    var hasEnded: Bool { ended.withLock { $0 } }
    var messages: [ServerMessage] {
        all.compactMap { if case .message(let m) = $0 { m } else { nil } }
    }
    func contains(_ e: ConnectionEvent) -> Bool { all.contains(e) }
    var lost: Bool { all.contains { if case .lost = $0 { true } else { false } } }
}

/// Commands queued on a fake connection.
final class CommandBox: Sendable {
    private let m = Mutex<[ClientCommand]>([])
    func append(_ c: ClientCommand) { m.withLock { $0.append(c) } }
    var all: [ClientCommand] { m.withLock { $0 } }
    func clear() { m.withLock { $0.removeAll() } }
}

/// A scriptable `ServerConnection` for supervisor/manager tests.
actor FakeServerConnection: ServerConnection {
    nonisolated let id: ServerID
    nonisolated let request: ConnectionRequest
    nonisolated let sent = CommandBox()
    private var continuation: AsyncStream<ConnectionEvent>.Continuation?
    private(set) var disconnected = false
    let failConnect: (any Error)?

    init(request: ConnectionRequest, failConnect: (any Error)? = nil) {
        self.id = request.id
        self.request = request
        self.failConnect = failConnect
    }

    func connect() async throws -> AsyncStream<ConnectionEvent> {
        if let failConnect { throw failConnect }
        let (s, c) = AsyncStream<ConnectionEvent>.makeStream()
        continuation = c
        c.yield(.connected)
        return s
    }

    nonisolated func enqueue(_ command: ClientCommand) { sent.append(command) }

    func push(_ event: ConnectionEvent) {
        continuation?.yield(event)
        switch event {
        case .lost, .closedByServer, .invalidCredentials: continuation?.finish(); continuation = nil
        default: break
        }
    }

    func push(line: String) { push(.message(GHWire.decodeServerLine(line))) }

    func disconnect() async {
        disconnected = true
        continuation?.finish()
        continuation = nil
    }
}

/// Creates `FakeServerConnection`s and remembers the latest one per server.
final class FakeConnectionFactory: Sendable {
    private let made = Mutex<[FakeServerConnection]>([])
    private let failing = Mutex<Set<ServerID>>([])

    func make(_ request: ConnectionRequest) -> any ServerConnection {
        let fail = failing.withLock { $0.contains(request.id) }
        let c = FakeServerConnection(request: request, failConnect: fail ? TransportError.openFailed("refused") : nil)
        made.withLock { $0.append(c) }
        return c
    }

    func setFailing(_ id: ServerID, _ on: Bool) {
        failing.withLock { if on { $0.insert(id) } else { $0.remove(id) } }
    }

    func latest(_ id: ServerID) -> FakeServerConnection? { made.withLock { $0.last { $0.id == id } } }
    func count(_ id: ServerID) -> Int { made.withLock { $0.filter { $0.id == id }.count } }
    var total: Int { made.withLock { $0.count } }

    func environment(clock: any GHEClock, resolve: (@Sendable (String) async -> String?)? = nil) -> ConnectionEnvironment {
        ConnectionEnvironment(clock: clock, resolve: resolve ?? { name in name.isEmpty ? nil : name },
                              makeConnection: { self.make($0) })
    }
}

let us = "\u{1F}"
let gs = "\u{1D}"

/// Joins wire fields with US.
func wire(_ fields: String...) -> String { fields.joined(separator: us) }

func text(_ bytes: [UInt8]) -> String { Windows1252.decode(bytes) }
