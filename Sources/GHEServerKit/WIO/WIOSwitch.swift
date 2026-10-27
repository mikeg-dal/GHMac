import Foundation
import Synchronization
import GHEKit

/// A SWITCHUPDATE-worthy change of a WIO switch.
public struct WIOSwitchUpdate: Sendable, Equatable {
    public var name: String
    public var state: String
    public var status: Int
    public var rssi: Int
}

/// A relay switch driven by a WIO profile. Virtual switches use the
/// same type on address 0 with no hardware I/O.
public actor WIOSwitch {
    public static let unknownState = "UNKNOWN"
    public static let noneSelected = "NONE_SELECTED"

    public nonisolated let name: String
    public nonisolated let profile: WioProfile
    public nonisolated let descriptor: SwitchDescriptor

    private let remote: PhysicalRemote
    private let persistence: any SwitchStatePersisting
    /// Live state, readable without awaiting (matrix lockout checks, SWITCHLOCKS).
    private let stateBox = Mutex<String>(WIOSwitch.unknownState)
    private var position = WIOSwitch.unknownState
    private var selected: [String] = []
    private var gate = UpdateGate(initialStatus: -1)
    private var pump: Task<Void, Never>?
    private var continuation: AsyncStream<WIOSwitchUpdate>.Continuation?
    private var started = false

    public init(name: String, profile: WioProfile, remote: PhysicalRemote,
                persistence: any SwitchStatePersisting = InMemorySwitchStateStore()) {
        self.name = name
        self.profile = profile
        self.descriptor = profile.descriptor(deviceName: name)
        self.remote = remote
        self.persistence = persistence
    }

    public nonisolated var isVirtual: Bool { profile.virtualSwitch }
    public nonisolated var isMatrixLockout: Bool { profile.matrixLockout }
    private var isBank: Bool { profile.displayType == .bank }

    /// The state clients see: the position, or the bank's comma list / `NONE_SELECTED`.
    public nonisolated var currentState: String { stateBox.withLock { $0 } }

    /// Restores the saved state (image only, no I/O), attaches to the remote and returns the update stream.
    /// The stream ends on `close()` or when the Base link is lost.
    public func start() async -> AsyncStream<WIOSwitchUpdate> {
        let (stream, c) = AsyncStream<WIOSwitchUpdate>.makeStream()
        guard !started else { c.finish(); return stream }
        started = true
        continuation = c
        let saved = await persistence.loadState(forSwitch: name)
        let snaps = remote.snapshots.subscribe()
        await remote.attach()
        if isBank {
            // A missing file for banks is treated as nothing selected.
            let names = (saved ?? Self.noneSelected).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            selected = []
            for n in names where profile.positionNames.contains(n) && !selected.contains(n) { selected.append(n) }
            if let first = selected.first {
                position = first
                if !isVirtual { await remote.initialize(mask: profile.bankMask(selected: selected)) }
            }
        } else if let saved, profile.positionNames.contains(saved) {
            position = saved
            await remote.initialize(mask: profile.mask(for: saved))
        } else {
            // A null state is kept when nothing was saved.
            position = saved ?? Self.unknownState
        }
        publishState()
        pump = Task { [weak self] in
            for await s in snaps { await self?.physicalStatusChanged(s) }
            await self?.linkEnded()
        }
        return stream
    }

    /// `setState(pos)`: banks toggle the position; virtual switches only record it.
    public func setState(_ pos: String) async {
        guard profile.positionNames.contains(pos) else { return }
        if isBank { await setState(pos, on: !selected.contains(pos)); return }
        position = pos
        publishState()
        if isVirtual {
            await persistence.saveState(currentState, forSwitch: name)
        } else {
            await remote.request(mask: profile.mask(for: pos))
        }
    }

    /// `setState(pos, on)` for ON/OFF banks.
    public func setState(_ pos: String, on: Bool) async {
        guard profile.positionNames.contains(pos) else { return }
        if on, !selected.contains(pos) { selected.append(pos) }
        if !on { selected.removeAll { $0 == pos } }
        position = pos
        publishState()
        await remote.request(mask: profile.bankMask(selected: selected))
    }

    public func close() async {
        guard started else { return }
        started = false
        pump?.cancel()
        await remote.detach()
        await persistence.saveState(currentState, forSwitch: name)
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internals

    private func publishState() {
        let s = isBank ? (selected.isEmpty ? Self.noneSelected : selected.joined(separator: ",")) : position
        stateBox.withLock { $0 = s }
    }

    private func physicalStatusChanged(_ s: RemoteSnapshot) async {
        let r = gate.accept(s)
        if r.changed && profile.isAllMomentary {
            if !profile.momentaryPins.contains(where: { $0 < s.relays.count && s.relays[$0] }) {
                position = Self.unknownState
                publishState()
            }
        }
        if r.fire {
            continuation?.yield(WIOSwitchUpdate(name: name, state: currentState, status: gate.status, rssi: gate.rssi))
        }
        if r.relaysChanged { await persistence.saveState(currentState, forSwitch: name) }
    }

    private func linkEnded() {
        continuation?.finish()
        continuation = nil
    }
}
