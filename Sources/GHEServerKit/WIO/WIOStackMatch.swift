import Foundation
import GHEKit

/// A STACK-worthy change of a stack match.
public struct WIOStackUpdate: Sendable, Equatable {
    public var names: [String]
    /// Always four entries (a1…a4).
    public var selected: [Bool]
    public var status: Int
    public var rssi: Int
}

/// A stack-match box on a remote. The device name is a comma list of
/// antenna names; antenna *i+1* is `names[i]`.
public actor WIOStackMatch {
    public nonisolated let names: [String]
    public nonisolated let type: WIOStackType
    private let remote: PhysicalRemote
    /// True if a rotor with exactly this name is currently connected (added) on the server.
    private let isRotorConnected: @Sendable (String) async -> Bool
    public private(set) var antennas = [true, true, true, true]
    private var gate = UpdateGate(initialStatus: 4)
    private var pump: Task<Void, Never>?
    private var continuation: AsyncStream<WIOStackUpdate>.Continuation?
    private var started = false

    /// `name` is the panel name: comma-separated antenna names (each trimmed, empty pieces dropped at the end).
    public init(name: String, type: WIOStackType, remote: PhysicalRemote,
                isRotorConnected: @escaping @Sendable (String) async -> Bool) {
        self.names = Self.antennaNames(from: name)
        self.type = type
        self.remote = remote
        self.isRotorConnected = isRotorConnected
    }

    /// Java `split(",")` (trailing empty pieces dropped) with each name trimmed.
    public static func antennaNames(from panelName: String) -> [String] {
        var parts = panelName.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The wire name (`STACKADD` / `STACK`): names re-joined with commas.
    public nonisolated var wireName: String { names.joined(separator: ",") }

    public func start() async -> AsyncStream<WIOStackUpdate> {
        let (stream, c) = AsyncStream<WIOStackUpdate>.makeStream()
        guard !started else { c.finish(); return stream }
        started = true
        continuation = c
        let snaps = remote.snapshots.subscribe()
        await remote.attach()
        pump = Task { [weak self] in
            for await s in snaps { await self?.physicalStatusChanged(s) }
            await self?.linkEnded()
        }
        return stream
    }

    /// OK2ZAW: on add, OK2ZAW types push all-on; other types send nothing.
    public func initializeStack() async {
        if let pins = StackEncoding.ok2zawInitialPins(type) { await remote.request(mask: pins) }
    }

    /// Toggles every antenna whose name matches (ignoring case).
    public func setAntenna(named antenna: String, _ on: Bool) async {
        for (i, n) in names.enumerated() where n.caseInsensitiveCompare(antenna) == .orderedSame {
            await setAntenna(i + 1, on)
        }
    }

    /// Sets antenna 1…4. Antennas that aren't connected rotors are forced off first; a selection with no
    /// antenna reverts the toggled antenna (sets it to `!on`).
    public func setAntenna(_ index: Int, _ on: Bool) async {
        guard (1...4).contains(index) else { return }
        for (i, n) in names.prefix(4).enumerated() where !(await isRotorConnected(n)) {
            antennas[i] = false
        }
        antennas[index - 1] = on
        do {
            let pins = try StackEncoding.pins(type, antennas)
            await remote.request(mask: pins)
        } catch {
            antennas[index - 1] = !on
        }
    }

    public func close() async {
        guard started else { return }
        started = false
        pump?.cancel()
        await remote.detach()
        continuation?.finish()
        continuation = nil
    }

    private func physicalStatusChanged(_ s: RemoteSnapshot) {
        let r = gate.accept(s)
        if r.fire {
            continuation?.yield(WIOStackUpdate(names: names, selected: antennas, status: gate.status, rssi: gate.rssi))
        }
    }

    private func linkEnded() {
        continuation?.finish()
        continuation = nil
    }
}
