import Foundation
import Network

/// Shared Network.framework helpers.
enum NW {
    /// TCP with no Nagle delay, a connect timeout and TCP keepalive.
    static func tcpParameters(connectTimeout: Int = 5) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Waits until `conn` is ready. Fails on `.failed`, `.waiting` (refused / unreachable),
    /// `.cancelled`, task cancellation, or `timeout`.
    static func waitReady(_ conn: NWConnection, queue: DispatchQueue, timeout: Duration) async throws {
        let once = OnceFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { ready.resume() }
                    case .failed(let err), .waiting(let err):
                        if once.claim() {
                            conn.cancel()
                            ready.resume(throwing: TransportError.openFailed(err.localizedDescription))
                        }
                    case .cancelled:
                        if once.claim() { ready.resume(throwing: TransportError.openFailed("cancelled")) }
                    default: break
                    }
                }
                conn.start(queue: queue)
                let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + secs) {
                    if once.claim() {
                        conn.cancel()
                        ready.resume(throwing: TransportError.openFailed("connection timed out"))
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    /// Cancels `conn` and waits until it reports `.cancelled` (or `timeout` passes), so a
    /// following reconnect never overlaps it (the RT-21 network module allows ONE connection).
    static func cancelAndWait(_ conn: NWConnection, timeout: Duration = .seconds(1)) async {
        if case .cancelled = conn.state { conn.stateUpdateHandler = nil; return }
        if case .setup = conn.state { conn.cancel(); conn.stateUpdateHandler = nil; return }
        let once = OnceFlag()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            conn.stateUpdateHandler = { state in
                if case .cancelled = state, once.claim() { done.resume() }
            }
            conn.cancel()
            let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
                if once.claim() { done.resume() }
            }
        }
        conn.stateUpdateHandler = nil
    }

    /// Peer IP text for an endpoint ("127.0.0.1"), without scope or IPv4-mapped prefix.
    static func hostText(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        var text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "\(host)"
        }
        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
        if text.lowercased().hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        return text
    }
}
