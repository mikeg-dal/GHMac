import SwiftUI
import GHEKit
import GHEClientKit

/// One tray row: active box, name, stack indicator, heading, turn-to stepper, Turn, jog, Stop and
/// the beam-colour swatch. One parameterised view for the Small / Medium / Large sizes.
struct RotorRowView: View {
    @Environment(ClientAppModel.self) private var model
    let rotor: RotorItem
    let metrics: RotorRowMetrics

    var body: some View {
        let state = model.panelState(rotor)
        let m = metrics
        HStack(alignment: .center, spacing: m.size == .small ? 4 : 6) {
            activeBox
            nameLabel
            StackIndicator(rotor: rotor, size: m.stackSize, fontSize: m.stackFontSize)
            presetAccess(HeadingDisplay(rotor: rotor, state: state, metrics: m))
                .contextMenu {
                    Toggle("Show tenths (if available)", isOn: Binding(get: { state.showTenths }, set: { state.showTenths = $0 }))
                    if m.presetUI == .popupMenu { presetMenuItems }
                }
            if m.turnStyle == .icon {
                HeadingStepper(rotor: rotor, state: state, metrics: m)
                turnButton
                stopButton
                if m.swatchWidth > 0 { swatch }
            } else {
                VStack(spacing: 2) {
                    HeadingStepper(rotor: rotor, state: state, metrics: m)
                    turnButton
                }
                if m.swatchWidth > 0 { swatch }
                if m.hasJog {
                    jogButton(clockwise: false)
                    jogButton(clockwise: true)
                }
                stopButton
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, m.rowPadding)
        .opacity(rotor.isConnected ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rotorRow.\(rotor.name)")
        .onChange(of: rotor.heading != nil, initial: true) { model.seedSpinner(rotor) }
        .onChange(of: RotorStatusStyle.checkboxEnabled(rotor)) { _, enabled in
            // A box that becomes disabled is also unchecked (status '5' etc.).
            if !enabled && rotor.isActive && rotor.isConnected { model.setActive(rotor, false) }
        }
    }

    // MARK: Parts

    private var activeBox: some View {
        Toggle("", isOn: Binding(get: { rotor.isActive }, set: { model.setActive(rotor, $0) }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .controlSize(metrics.size == .large ? .large : .regular)
            .frame(width: metrics.checkboxWidth)
            .disabled(!RotorStatusStyle.checkboxEnabled(rotor))
            .help("Active: follows logger turns and global presets")
            .accessibilityIdentifier("active.\(rotor.name)")
    }

    private var nameLabel: some View {
        let server = model.serverDescription(rotor.key.server)
        return presetAccess(
            Text(rotor.name)
                .font(metrics.nameFont)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: metrics.nameWidth, alignment: .leading)
                .contentShape(Rectangle())
        )
        .help("Rotor Location:\nServer: \(server.name)\nIP Addr: \(server.address)\nPort: \(server.port)")
        .accessibilityIdentifier("rotorName.\(rotor.name)")
    }

    /// Small: a pop-up menu of the global presets. Medium/Large: the rotor's preset window.
    @ViewBuilder
    private func presetAccess<V: View>(_ content: V) -> some View {
        if metrics.presetUI == .popupMenu {
            Menu { presetMenuItems } label: { content }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!rotor.canTurn)
        } else {
            content
                .onTapGesture { if rotor.canTurn { model.windows?.showPresets(for: rotor) } }
        }
    }

    @ViewBuilder
    private var presetMenuItems: some View {
        if model.presets.isEmpty {
            Text("No presets")
        }
        ForEach(Array(model.presets.enumerated()), id: \.offset) { _, p in
            Button(p.name) { if let h = p.headingValue { model.turn(rotor, to: h) } }
        }
    }

    private var turnButton: some View {
        Button { model.turn(rotor) } label: {
            if metrics.turnStyle == .icon {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 14)).foregroundStyle(.green)
                    .opacity(rotor.canTurn ? 1 : 0.35)
            } else {
                Text("Turn").font(metrics.buttonFont).frame(width: metrics.spinnerWidth - 12)
            }
        }
        .controlSize(metrics.size == .small ? .small : .regular)
        .frame(width: metrics.turnStyle == .icon ? 35 : metrics.spinnerWidth)
        .disabled(!rotor.canTurn)
        .help(turnTooltip)
        .accessibilityIdentifier("turn.\(rotor.name)")
        .contextMenu {
            hotkeyItem("Assign hotkey to turn rotor to preset heading...", .executeTurn)
            if metrics.size == .small {
                hotkeyItem("Set hotkey to turn rotor CCW...", .turnCCW)
                hotkeyItem("Set hotkey to turn rotor CW...", .turnCW)
            }
            Divider()
            Button("Clear hotkeys for this rotor") { model.clearHotkeys(for: rotor.key) }
        }
    }

    private var turnTooltip: String {
        var t = "Turn to preset hotkey: \(model.hotkeyName(.rotor(rotor.key, .executeTurn)))"
        if metrics.size == .small {
            t += "\nTurn CCW hotkey: \(model.hotkeyName(.rotor(rotor.key, .turnCCW)))"
            t += "\nTurn CW hotkey: \(model.hotkeyName(.rotor(rotor.key, .turnCW)))"
        }
        return t
    }

    private var stopButton: some View {
        let target = HotkeyTarget.rotor(rotor.key, .executeStop)
        return Button { model.stop(rotor) } label: {
            if metrics.turnStyle == .icon {
                Image(systemName: "stop.circle.fill").font(.system(size: 14)).foregroundStyle(.red)
                    .opacity(rotor.canStop ? 1 : 0.35)
            } else {
                ButtonCaption(title: "Stop", caption: caption(target), font: metrics.buttonFont, width: metrics.stopWidth - 12)
            }
        }
        .controlSize(metrics.size == .small ? .small : .regular)
        .frame(width: metrics.stopWidth)
        .disabled(!rotor.canStop)
        .help("Stop\nHotkey: \(model.hotkeyName(target))")
        .accessibilityIdentifier("stop.\(rotor.name)")
        .contextMenu { hotkeyItem("Assign hotkey to stop rotor...", .executeStop) }
    }

    private func jogButton(clockwise: Bool) -> some View {
        let cmd: RotorHotkeyCommand = clockwise ? .jogCW : .jogCCW
        let target = HotkeyTarget.rotor(rotor.key, cmd)
        // The caption is plain text.
        return Button { model.jog(rotor, clockwise: clockwise) } label: {
            ButtonCaption(title: clockwise ? ">>" : "<<", caption: caption(target), font: metrics.jogFont,
                          width: metrics.jogWidth - 12)
        }
        .frame(width: metrics.jogWidth)
        .disabled(!rotor.canTurn)
        .help("Jog \(clockwise ? "CW" : "CCW")\nHotkey: \(model.hotkeyName(target))")
        .accessibilityIdentifier("\(clockwise ? "jogCW" : "jogCCW").\(rotor.name)")
        .contextMenu {
            if metrics.size == .large {
                hotkeyItem(clockwise ? "Assign Hotkey to JOG CW..." : "Assign Hotkey to JOG CCW...", cmd)
            } else {
                hotkeyItem(clockwise ? "Assign hotkey to jog rotor CW..." : "Set hotkey to jog rotor CCW...", cmd)
            }
        }
    }

    private var swatch: some View {
        Rectangle()
            .fill(Color(nsColor: model.beamColor(rotor)))
            .frame(width: metrics.swatchWidth, height: metrics.headingHeight)
            .accessibilityHidden(true)
    }

    private func caption(_ target: HotkeyTarget) -> String? {
        model.settings.showHotkeysOnButtons ? model.hotkeyCaption(target) : nil
    }

    private func hotkeyItem(_ title: String, _ cmd: RotorHotkeyCommand) -> some View {
        Button(title) {
            HotkeyCaptureController.capture(model: model, panel: rotor.name, action: cmd.rawValue) { key in
                model.bindHotkey(key, to: .rotor(rotor.key, cmd))
            }
        }
    }
}

/// A button title with an optional italic hotkey caption underneath.
struct ButtonCaption: View {
    let title: String
    let caption: String?
    let font: Font
    var width: CGFloat? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(font)
            if let caption {
                Text(caption).font(.system(size: 9).italic()).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(minWidth: width)
    }
}
