import Foundation
import Observation
import GHEKit

/// One rotor row (tray panel / map wedge). Per-item observable so a heading update redraws only its row.
@MainActor @Observable
public final class RotorItem: Identifiable {
    public let key: ItemKey
    public nonisolated var id: ItemKey { key }
    public var name: String { key.name }

    /// Last POINT heading; nil until the first one ("--").
    public internal(set) var heading: Double?
    public internal(set) var status: RotorStatus = .ok
    /// Remote RSSI in dBm (0 = wired / unknown).
    public internal(set) var rssi: Int = 0
    /// The row's "active" checkbox: follows logger Alt-J, global presets and ganging.
    public var isActive: Bool
    /// False while the owning server is down (the row is greyed out).
    public internal(set) var isConnected = true

    /// Stack-match state for this antenna; nil until a STACK update names it.
    public internal(set) var stackSelected: Bool?
    public internal(set) var stackStatus: Int = 4
    public internal(set) var stackRSSI: Int = 0
    /// When the last STACK update arrived (drives the 5 s / 8 s watchdog in the UI).
    public internal(set) var stackUpdatedAt: ContinuousClock.Instant?

    init(key: ItemKey, isActive: Bool = false) {
        self.key = key
        self.isActive = isActive
    }

    /// Controls usable (status '0', '2', '3', '4', '8', '9' allow Stop) and server up.
    public var canStop: Bool {
        guard isConnected else { return false }
        switch status {
        case .ok, .moving, .stopped, .turningCW, .turningCCW, .clone: return true
        case .offline, .error, .readOnly, .fixed: return false
        }
    }

    /// Turn/jog/spinner usable.
    public var canTurn: Bool {
        guard isConnected else { return false }
        switch status {
        case .ok, .moving, .stopped, .clone: return true
        default: return false
        }
    }

    func applyPoint(heading: Double, status: RotorStatus, rssi: Int) {
        self.heading = heading
        self.status = status
        self.rssi = rssi
    }

    func applyStack(selected: Bool, status: Int, rssi: Int, at now: ContinuousClock.Instant) {
        stackSelected = selected
        stackStatus = status
        stackRSSI = rssi
        stackUpdatedAt = now
    }

    func clearStack() {
        stackSelected = nil
        stackStatus = 4
        stackRSSI = 0
        stackUpdatedAt = nil
    }
}
