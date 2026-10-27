import Foundation
import Observation
import GHEKit

/// Row state in the Servers dialog (111…555).
public enum ConnectionState: Int, Sendable, Hashable, CaseIterable {
    case disconnected = 111
    case connected = 222
    case retrying = 333
    case connecting = 444
    case disconnecting = 555

    /// The toggle button's caption.
    public var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connected: "Connected"
        case .retrying: "Retrying"
        case .connecting: "Connecting"
        case .disconnecting: "Disconnecting"
        }
    }
}

/// What the user typed in one Servers-dialog row.
public struct ServerRowConfig: Sendable, Hashable {
    public var address: String
    /// Port as typed (validated on connect).
    public var port: String
    public var kind: ServerKind
    public var user: String
    /// The password field. Only used to compute the hash on connect; empty → saved hash for `user`.
    public var password: String
    /// Terminal servers only: name of the synthetic rotor.
    public var rotorName: String
    /// Terminal servers only: `AI2;` (default) or `BI2;`.
    public var terminalPoll: TerminalServerConnection.PollCommand

    public init(address: String = "", port: String = "", kind: ServerKind = .ghServer, user: String = "",
                password: String = "", rotorName: String = "",
                terminalPoll: TerminalServerConnection.PollCommand = .integer) {
        self.address = address; self.port = port; self.kind = kind; self.user = user
        self.password = password; self.rotorName = rotorName; self.terminalPoll = terminalPoll
    }
}

/// Callbacks from a supervisor to its owner (the `ConnectionManager`).
@MainActor
protocol ConnectionSupervisorDelegate: AnyObject {
    /// True if another row is already using `id` ("Already Connected").
    func supervisor(_ s: ConnectionSupervisor, isInUse id: ServerID) -> Bool
    func supervisor(_ s: ConnectionSupervisor, didConnect id: ServerID)
    func supervisor(_ s: ConnectionSupervisor, received message: ServerMessage, from id: ServerID)
    /// Link lost or CLOSE: grey the server's rotors, drop its switches.
    func supervisor(_ s: ConnectionSupervisor, didLose id: ServerID)
    /// User disconnect or invalid credentials: remove the server's items.
    func supervisor(_ s: ConnectionSupervisor, didEnd id: ServerID)
    func savedPasswordHash(user: String) -> [UInt8]?
    func storePasswordHash(_ hash: [UInt8], user: String)
    var trafficSink: TrafficSink? { get }
}

/// Drives one Servers-dialog row: validation, connect, 15 s retry, user disconnect.
@MainActor @Observable
public final class ConnectionSupervisor: Identifiable {
    /// Row index 0…9.
    public let id: Int
    public var config: ServerRowConfig
    public private(set) var state: ConnectionState = .disconnected
    /// The Messages column.
    public private(set) var message = ""
    /// Resolved `hostAddress:port` while the row is in use.
    public private(set) var serverID: ServerID?

    /// Row controls are editable only while disconnected (`enableControls`).
    public var controlsEnabled: Bool { state == .disconnected }

    @ObservationIgnored let environment: ConnectionEnvironment
    @ObservationIgnored weak var delegate: (any ConnectionSupervisorDelegate)?
    /// The live connection (connected, connecting or retrying).
    @ObservationIgnored private(set) var connection: (any ServerConnection)?
    @ObservationIgnored private var passwordHash: [UInt8] = []
    @ObservationIgnored private var rotorName = ""
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var attemptTask: Task<Void, Never>?
    /// Bumped whenever an attempt is abandoned so its late events are ignored.
    @ObservationIgnored private var generation = 0

    public init(id: Int, config: ServerRowConfig = ServerRowConfig(), environment: ConnectionEnvironment) {
        self.id = id
        self.config = config
        self.environment = environment
    }

    /// The toggle button (`connectButtonActionPerformed`).
    public func toggle() {
        Task { await toggleNow() }
    }

    public func toggleNow() async {
        if state == .disconnected { await connect() } else { await disconnect() }
    }

    /// Validates the row and starts connecting. Messages and checks are kept for compatibility.
    public func connect() async {
        guard state == .disconnected else { return }
        retryTask?.cancel()
        message = ""
        // Integer port, else "Invalid TCP port".
        // Also require 1…65535.
        guard let port = JavaString.parseInt(config.port), (1...65535).contains(port) else {
            message = "Invalid TCP port"
            return
        }
        let address = JavaString.trim(config.address)
        guard !address.isEmpty else {
            message = "No IP Address"
            return
        }
        var hash: [UInt8] = []
        if config.kind == .ghServer {
            if config.password.isEmpty {
                hash = delegate?.savedPasswordHash(user: config.user)
                    ?? GHAuth.passwordHash(user: config.user, password: "")
            } else {
                hash = GHAuth.passwordHash(user: config.user, password: config.password)
            }
            if config.password.contains(" ") {
                message = "No spaces in password"
                return
            }
        }
        state = .connecting
        let resolved = await environment.resolve(address)
        guard state == .connecting else { return }   // user cancelled while resolving
        guard let host = resolved else {
            // Stop here.
            state = .disconnected
            message = "Unknown host"
            return
        }
        let sid = ServerID(host: host, port: UInt16(port))
        if delegate?.supervisor(self, isInUse: sid) == true {
            state = .disconnected
            message = "Already Connected"
            return
        }
        serverID = sid
        passwordHash = hash
        rotorName = config.rotorName
        if config.kind == .ghServer { delegate?.storePasswordHash(hash, user: config.user) }
        startAttempt()
    }

    /// User disconnect: QUIT, close, remove the server's items. Also cancels a pending retry.
    public func disconnect() async {
        retryTask?.cancel()
        retryTask = nil
        guard state != .disconnected else { return }
        generation += 1
        state = .disconnecting
        let conn = connection
        connection = nil
        await conn?.disconnect()
        if let sid = serverID { delegate?.supervisor(self, didEnd: sid) }
        serverID = nil
        state = .disconnected
    }

    // MARK: Attempts

    private func startAttempt() {
        guard let sid = serverID else { return }
        generation += 1
        let gen = generation
        let request = ConnectionRequest(id: sid, kind: config.kind, user: config.user, passwordHash: passwordHash,
                                        rotorName: rotorName, terminalPoll: config.terminalPoll,
                                        traffic: delegate?.trafficSink)
        let conn = environment.makeConnection(request)
        connection = conn
        attemptTask = Task { [weak self] in
            do {
                let events = try await conn.connect()
                for await event in events {
                    guard let self, self.generation == gen else { return }
                    self.handle(event, sid)
                }
            } catch {
                guard let self, self.generation == gen else { return }
                self.attemptFailed(error, sid)
            }
        }
    }

    private func handle(_ event: ConnectionEvent, _ sid: ServerID) {
        switch event {
        case .connected:
            retryTask?.cancel()
            state = .connected
            message = ""
            delegate?.supervisor(self, didConnect: sid)
        case .message(let m):
            delegate?.supervisor(self, received: m, from: sid)
        case .invalidCredentials:
            // No retry after an auth failure (`setInvalid`).
            generation += 1
            let conn = connection
            connection = nil
            Task { await conn?.disconnect() }
            delegate?.supervisor(self, didEnd: sid)
            serverID = nil
            state = .disconnected
            message = "Invalid user/pass"
        case .closedByServer, .lost:
            linkDown(sid)
        }
    }

    private func attemptFailed(_ error: any Error, _ sid: ServerID) {
        if case TransportError.endpointBusy = error { message = "Already in use" }
        linkDown(sid)
    }

    /// Disconnect event (`serverHasDisconnected`): Retrying unless the user was disconnecting.
    private func linkDown(_ sid: ServerID) {
        generation += 1
        connection = nil
        delegate?.supervisor(self, didLose: sid)
        if state == .disconnecting || state == .disconnected {
            state = .disconnected
            return
        }
        state = .retrying
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let clock = environment.clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(for: Timing.clientRetryDelay) } catch { return }
            guard let self, !Task.isCancelled, self.state == .retrying else { return }
            self.startAttempt()
        }
    }
}
