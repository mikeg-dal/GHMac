import Foundation
import Observation
import GHEKit
import GHEServerKit

/// One Device Manager row: its editable fields, the enable/disable matrix
/// and the slot controller that runs the device. One observable per row, so a status change
/// redraws only that row.
@Observable
final class DeviceRowModel: Identifiable {
    let order: Int
    var id: Int { order }

    var name: String { didSet { if name != oldValue { changed() } } }
    var port: String { didSet { if port != oldValue { changed() } } }
    var deviceType: String { didSet { if deviceType != oldValue { typeChanged() } } }
    var subType: String { didSet { if subType != oldValue { changed() } } }
    var wioAddress: Int? { didSet { if wioAddress != oldValue { changed() } } }
    var basePTT: Bool { didSet { if basePTT != oldValue { onBasePTTChange?(self); changed() } } }
    var initialState: Bool { didSet { if initialState != oldValue { changed() } } }
    var fixedHeading: Double? { didSet { if fixedHeading != oldValue { changed() } } }
    var cloneOffset: Double? { didSet { if cloneOffset != oldValue { changed() } } }
    @ObservationIgnored private var extraAttributes: [String: String]

    private(set) var status: SlotStatus = .disconnected
    /// True while a user-initiated connect is in flight (prevents double clicks).
    var isBusy = false

    @ObservationIgnored let slot: DeviceSlotController
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onBasePTTChange: ((DeviceRowModel) -> Void)?
    @ObservationIgnored var onSlotEvent: ((DeviceRowModel, SlotEvent) -> Void)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(config c: DevicePanelConfig, slot: DeviceSlotController) {
        order = c.order
        name = c.name
        port = c.port
        // Legacy WIO 8 / WIO 6 are already mapped to GHE Base by DeviceManagerXML.
        deviceType = c.type == nil ? DeviceType.rt21.rawValue : c.deviceType
        subType = c.subType
        wioAddress = c.wioAddress
        basePTT = c.basePTT
        initialState = c.initialState
        fixedHeading = c.fixedHeading
        cloneOffset = c.cloneOffset
        extraAttributes = c.extraAttributes
        self.slot = slot
        let stream = slot.events.subscribe()
        eventTask = Task { [weak self] in
            for await e in stream { self?.handle(e) }
        }
    }

    isolated deinit { eventTask?.cancel() }

    var type: DeviceType { DeviceType(rawValue: deviceType) ?? .rt21 }
    var isEmpty: Bool { name.isEmpty }

    var config: DevicePanelConfig {
        DevicePanelConfig(order: order, name: name, port: port, deviceType: deviceType, subType: subType,
                          wioAddress: wioAddress, basePTT: basePTT, initialState: initialState,
                          fixedHeading: fixedHeading, cloneOffset: cloneOffset, extraAttributes: extraAttributes)
    }

    // MARK: Status

    /// Connected, connecting, validating or retrying: the toggle is "pressed" and the fields are locked.
    var isActive: Bool {
        switch status {
        case .disconnected, .error: false
        default: true
        }
    }

    private func handle(_ e: SlotEvent) {
        if case .status(let s) = e { status = s }
        onSlotEvent?(self, e)
    }

    // MARK: Enable/disable matrix

    var fieldsEnabled: Bool { !isActive && !isBusy }
    /// Base PTT only for GHE Base and Virtual Switch.
    var basePTTEnabled: Bool { fieldsEnabled && usesBase }
    var subTypeEnabled: Bool { fieldsEnabled && usesBase }
    var wioAddressEnabled: Bool { fieldsEnabled && (type == .gheBase || type == .clonedAntenna) }
    var portEnabled: Bool { fieldsEnabled && type != .fixedAntenna }
    var usesBase: Bool { type == .gheBase || type == .virtualSwitch }

    /// Applies the forced values of a type change (`deviceTypeComboActionPerformed`).
    private func typeChanged() {
        switch type {
        case .gheBase:
            break
        case .virtualSwitch:
            wioAddress = 0
        case .clonedAntenna:
            subType = DevicePanelConfig.notApplicable
        case .rt21, .dcu1, .fixedAntenna:
            subType = DevicePanelConfig.notApplicable
            wioAddress = nil
        }
        if !usesBase { basePTT = false }
        changed()
    }

    private func changed() { onChange?() }

    /// Loads values without firing change callbacks.
    func replace(with c: DevicePanelConfig) {
        let cb = onChange, ptt = onBasePTTChange
        onChange = nil; onBasePTTChange = nil
        name = c.name; port = c.port
        deviceType = c.type == nil ? DeviceType.rt21.rawValue : c.deviceType
        subType = c.subType; wioAddress = c.wioAddress; basePTT = c.basePTT
        initialState = c.initialState; fixedHeading = c.fixedHeading; cloneOffset = c.cloneOffset
        extraAttributes = c.extraAttributes
        onChange = cb; onBasePTTChange = ptt
    }
}

extension SlotStatus {
    var isError: Bool { if case .error = self { true } else { false } }
}
