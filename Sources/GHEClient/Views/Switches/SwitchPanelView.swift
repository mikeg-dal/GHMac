import SwiftUI
import GHEKit
import GHEClientKit

/// Content of one switch window: picks the panel for the switch's display type.
struct SwitchPanelView: View {
    @Environment(ClientAppModel.self) private var model
    let key: ItemKey

    var body: some View {
        Group {
            if let sw = model.connections.switchItem(key) {
                switch sw.displayType {
                case .map: MapSwitchView(item: sw)
                case .bank: SwitchButtonsView(item: sw, mode: .bank)
                case .band:
                    VStack(spacing: 4) {
                        SwitchButtonsView(item: sw, mode: .exclusive)
                        SoftwareControlToggles(key: key)
                    }
                case .buttons: SwitchButtonsView(item: sw, mode: .exclusive)
                }
            } else if let t = model.connections.tornado(key) {
                TornadoTunerView(item: t)
            } else {
                Text("Switch removed").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Button switch and on/off bank, one view for every size.
struct SwitchButtonsView: View {
    enum Mode { case exclusive, bank }

    @Environment(ClientAppModel.self) private var model
    let item: SwitchItem
    let mode: Mode

    var body: some View {
        let m = SwitchMetrics.forSize(model.settings.switchDisplaySize)
        let error = SwitchColors.statusText(item.status)
        VStack(spacing: 3) {
            Text(item.name)
                .font(m.nameFont)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
            ForEach(item.positionNames, id: \.self) { pos in
                positionButton(pos, m)
            }
        }
        .padding(6)
        .frame(minWidth: 140)
        .background(error != nil ? Color.red : Color.clear)
        .help(error ?? (item.rssi != 0 ? "RSSI: \(item.rssi) dBm" : ""))
        .contextMenu { panelMenu }
    }

    private func positionButton(_ pos: String, _ m: SwitchMetrics) -> some View {
        let locked = mode == .exclusive && item.isLocked(pos)
        let confirmed: Bool
        let pending: Bool
        switch mode {
        case .bank:
            confirmed = item.selected.contains(pos)
            pending = false
        case .exclusive:
            confirmed = item.selectedPosition == pos
            pending = !confirmed && model.pendingSwitch[item.key] == pos
        }
        let fill = fillColor(pos, locked: locked, selected: confirmed, pending: pending)
        let text: Color = SwitchColors.isDark(fill) ? .white : .black
        let target = HotkeyTarget.switchPosition(item.key, pos)
        let caption = model.settings.showHotkeysOnButtons ? model.hotkeyCaption(target) : nil
        return Button {
            if mode == .bank { model.toggleBank(item, position: pos) } else { model.selectSwitch(item, position: pos) }
        } label: {
            VStack(spacing: 0) {
                Text(pos).font(m.buttonFont).lineLimit(1).minimumScaleFactor(0.4)
                if let caption { Text(caption).font(.system(size: 10).italic()) }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(ColoredButtonStyle(fill: fill, textColor: text, enabled: !locked))
        .frame(minHeight: m.buttonHeight)
        .disabled(locked)
        .help(locked ? "Locked out by another switch" : "Hotkey: \(model.hotkeyName(target))")
        .accessibilityIdentifier("switch.\(item.name).\(pos)")
        .accessibilityValue(confirmed ? "selected" : pending ? "pending" : "")
        .contextMenu {
            Button("Assign hotkey for \"\(pos)\"...") { capture(pos) }
            Menu("Button Color for \"\(pos)\"...") {
                Button("Default") { model.setButtonColor(nil, switchKey: item.key, position: pos) }
                ForEach([SwitchButtonColor.green, .red, .yellow, .cyan, .orange, .black], id: \.self) { c in
                    Button(c == .black ? "Black Inverted" : c.rawValue) { model.setButtonColor(c, switchKey: item.key, position: pos) }
                }
            }
        }
    }

    /// Lock (pink) > per-button colour > global colour; UNKNOWN shows the momentary colour on the previous position.
    private func fillColor(_ pos: String, locked: Bool, selected: Bool, pending: Bool) -> Color {
        if locked { return SwitchColors.locked }
        let global = model.settings.switchButtonColor
        if pending { return SwitchColors.momentary(global) }
        if mode == .exclusive, item.isUnknown, model.previousSwitchPosition[item.key] == pos { return SwitchColors.momentary(global) }
        guard selected else { return SwitchColors.unselected }
        if let c = model.buttonColor(switchKey: item.key, position: pos) { return SwitchColors.button(c) }
        if mode == .bank {
            // The bank keywords work in every size.
            let u = pos.uppercased()
            if u.contains("PTT LOCK") { return Color(red: 1, green: 0, blue: 1) }
            if u.contains("RED") { return .red }
            if u.contains("YELLOW") { return Color(red: 1, green: 1, blue: 0) }
        }
        return SwitchColors.global(global)
    }

    @ViewBuilder
    private var panelMenu: some View {
        if mode == .exclusive, let cur = model.displayedPosition(item) {
            Button("Assign keystroke for this position...") { capture(cur) }
        }
        if mode == .exclusive {
            Button("Assign keystroke to cycle forward...") { capture(HotkeyTarget.cycleForward) }
            Button("Assign keystroke to cycle backward...") { capture(HotkeyTarget.cycleBackward) }
        }
        Menu("Clear keys") {
            Button("Clear all hotkeys for this item") { model.clearHotkeys(for: item.key) }
        }
    }

    private func capture(_ position: String) {
        HotkeyCaptureController.capture(model: model, panel: item.name, action: position) { key in
            model.bindHotkey(key, to: .switchPosition(item.key, position))
        }
    }
}

/// Band-switch / Tornado checkboxes: Software Control, VFO-A/Radio 1, VFO-B/Radio 2 (all default on).
struct SoftwareControlToggles: View {
    @Environment(ClientAppModel.self) private var model
    let key: ItemKey

    var body: some View {
        let c = model.switchWindow(key)
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Software Control", isOn: Binding(get: { c.isSoftwareControl },
                                                     set: { v in model.updateSwitchWindow(key) { $0.softwareControl = v } }))
                .accessibilityIdentifier("softwareControl.\(key.name)")
            Group {
                Toggle("VFO-A/Radio 1", isOn: Binding(get: { c.isVFOA }, set: { v in model.updateSwitchWindow(key) { $0.vfoA = v } }))
                Toggle("VFO-B/Radio 2", isOn: Binding(get: { c.isVFOB }, set: { v in model.updateSwitchWindow(key) { $0.vfoB = v } }))
            }
            .disabled(!c.isSoftwareControl)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
