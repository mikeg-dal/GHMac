import Foundation
import Observation
import GHEKit

/// One antenna of a stack-match device (STACKADD names; hotkey target `<name>␞:<port>`).
@MainActor @Observable
public final class StackItem: Identifiable {
    public let key: ItemKey
    public nonisolated var id: ItemKey { key }
    public var name: String { key.name }
    /// All antenna names of the stack device this antenna belongs to.
    public internal(set) var group: [String]
    public internal(set) var selected = false
    /// Stack-match status; 4 = no response until the first update.
    public internal(set) var status: Int = 4
    public internal(set) var rssi: Int = 0
    public internal(set) var isConnected = true

    init(key: ItemKey, group: [String]) {
        self.key = key
        self.group = group
    }
}

/// One line of the "Device RSSI Test" window.
public struct RSSIEntry: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case rotor = "ROTOR", switchBox = "SWITCH", stack = "STACK" }
    public var key: ItemKey
    public var kind: Kind
    public var rssi: Int
    public var id: String { "\(kind.rawValue)|\(key)" }
    /// `"<name>  <rssi>dBm   [ROTOR]"`.
    public var line: String { "\(key.name)  \(rssi)dBm   [\(kind.rawValue)]" }
}
