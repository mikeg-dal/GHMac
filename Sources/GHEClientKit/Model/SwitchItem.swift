import Foundation
import Observation
import GHEKit

/// One switch panel (button, map, band or bank).
@MainActor @Observable
public final class SwitchItem: Identifiable {
    public static let unknownState = "UNKNOWN"
    public static let noneSelected = "NONE_SELECTED"

    public let key: ItemKey
    public nonisolated var id: ItemKey { key }
    public var name: String { key.name }

    public internal(set) var descriptor: SwitchDescriptor
    /// Raw state from the last SWITCHUPDATE (nil before the first one).
    public internal(set) var state: String?
    /// Selected positions: one for exclusive switches, any number for banks.
    public internal(set) var selected: Set<String> = []
    /// Switch status: -1 unknown (initial), 0 good, else error.
    public internal(set) var status: Int = -1
    public internal(set) var rssi: Int = 0
    /// Matrix-lockout states from SWITCHLOCKS (positions shown pink/disabled).
    public internal(set) var locks: [String] = []

    init(key: ItemKey, descriptor: SwitchDescriptor) {
        self.key = key
        self.descriptor = descriptor
    }

    /// Unknown types fall back to a button switch.
    public var displayType: SwitchDisplayType { descriptor.kind ?? .buttons }
    public var isBank: Bool { descriptor.displayType == SwitchDisplayType.bank.rawValue }
    public var positionNames: [String] { descriptor.positions.map(\.name) }
    /// The selected position of an exclusive switch (nil when UNKNOWN or none).
    public var selectedPosition: String? { isBank ? nil : selected.first }
    /// True when the server reported UNKNOWN for an exclusive switch.
    public var isUnknown: Bool { !isBank && state == Self.unknownState }

    /// True if `position` is locked out by another matrix switch ("OFF" never is).
    public func isLocked(_ position: String) -> Bool {
        if position.caseInsensitiveCompare("OFF") == .orderedSame { return false }
        return locks.contains { $0.caseInsensitiveCompare(position) == .orderedSame }
    }

    func applyUpdate(state: String, status: Int, rssi: Int) {
        self.state = state
        self.status = status
        self.rssi = rssi
        if isBank {
            // Bank: comma list of ON positions, or NONE_SELECTED.
            selected = state == Self.noneSelected
                ? []
                : Set(JavaString.split(state, separator: ",").filter { !$0.isEmpty })
        } else {
            selected = state == Self.unknownState ? [] : [state]
        }
    }
}

/// Tornado tuner (client-understood only).
@MainActor @Observable
public final class TornadoItem: Identifiable {
    public let key: ItemKey
    public nonisolated var id: ItemKey { key }
    public internal(set) var descriptor: TornadoDescriptor
    public internal(set) var state: TornadoState?

    init(key: ItemKey, descriptor: TornadoDescriptor) {
        self.key = key
        self.descriptor = descriptor
    }
}
