import Foundation
import GHEKit
import GHEServerKit

/// A `CredentialLookup` backed by a fixed dictionary (tests, simulator).
public struct InMemoryCredentials: CredentialLookup {
    public let hashes: [String: [UInt8]]

    public init(hashes: [String: [UInt8]] = [:]) { self.hashes = hashes }

    /// Users with plain-text passwords, hashed like the server's user manager: P = SHA-256(user ‖ password).
    public init(passwords: [String: String]) {
        var h: [String: [UInt8]] = [:]
        for (user, pw) in passwords { h[user] = GHAuth.passwordHash(user: user, password: pw) }
        hashes = h
    }

    public func passwordHash(for user: String) async -> [UInt8]? { hashes[user] }
}

/// A complete GH server hub on an in-memory listener: no sockets, no network.
/// Used by tests, the E2E suite and the client app's simulator mode.
public final class InProcessServer: Sendable {
    public let listener: MemoryListener
    public let hub: ServerHub
    public let registry: any DeviceRegistryProtocol

    public init(registry: any DeviceRegistryProtocol,
                credentials: any CredentialLookup = InMemoryCredentials(),
                settings: HubSettings = HubSettings(),
                clock: any GHEClock = SystemClock()) {
        let listener = MemoryListener()
        self.listener = listener
        self.registry = registry
        hub = ServerHub(listener: listener, registry: registry, credentials: credentials,
                        settings: settings, clock: clock)
    }

    public func start() async throws { try await hub.start() }
    public func stop() async { await hub.stop() }

    /// Opens a new in-memory connection and returns its client end.
    /// `address` is the peer IP the server sees (locks are keyed by it).
    public func connectClient(from address: String = "127.0.0.1") throws -> MemoryStreamConnection {
        try listener.connect(from: address)
    }

    /// Opens a connection and wraps it in a started `JavaClientEmulator`.
    public func connectEmulator(from address: String = "127.0.0.1") async throws -> JavaClientEmulator {
        let emulator = JavaClientEmulator(connection: try connectClient(from: address))
        await emulator.start()
        return emulator
    }

    /// A `StreamConnector` that connects to this server whatever host/port is asked for (client simulator mode).
    public var connector: MemoryConnector {
        MemoryConnector { [listener] _, _ in try listener.connect(from: "127.0.0.1") }
    }
}
