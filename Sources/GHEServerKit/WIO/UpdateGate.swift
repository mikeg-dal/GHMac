import Foundation
import GHEKit

/// The "fire on change or every 5th response" rule shared by WIOSwitch and WIOStackMatch.
///
/// The gate stores the new values first, so updates carry the current status and RSSI.
struct UpdateGate {
    private(set) var lastRelays: [Bool] = []
    private(set) var status: Int
    private(set) var rssi = 0
    private var counter = 0

    init(initialStatus: Int) { status = initialStatus }

    /// Returns (fire, relaysChanged).
    mutating func accept(_ s: RemoteSnapshot) -> (fire: Bool, changed: Bool, relaysChanged: Bool) {
        let relaysChanged = s.relays != lastRelays
        let changed = relaysChanged || s.status != status || s.rssi != rssi
        let fire: Bool
        if changed {
            fire = true
            counter = 0
        } else {
            fire = counter % Timing.wioUpdateEveryNthResponse == 0
        }
        counter += 1
        lastRelays = s.relays
        status = s.status
        rssi = s.rssi
        return (fire, changed, relaysChanged)
    }
}
