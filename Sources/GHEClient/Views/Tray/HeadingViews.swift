import SwiftUI
import GHEKit
import GHEClientKit

/// The heading box: black background, status-coloured digits.
struct HeadingDisplay: View {
    @Environment(ClientAppModel.self) private var model
    let rotor: RotorItem
    let state: RotorPanelState
    let metrics: RotorRowMetrics

    /// The text to show ("--" before the first POINT, "---" for a fixed rotor above 360).
    static func text(_ rotor: RotorItem, tenths: Bool) -> String {
        guard rotor.isConnected else { return "" }
        guard let h = rotor.heading else { return "--" }
        // Fixed rotor: a heading above 360 means "no direction". No integer parse.
        if rotor.status == .fixed && h > 360 { return "---" }
        return tenths ? String(format: "%05.1f", h) : String(format: "%03d", Int(h.rounded()) % 361)
    }

    var body: some View {
        let text = Self.text(rotor, tenths: state.showTenths)
        let color = RotorStatusStyle.color(rotor.status)
        ZStack {
            Rectangle().fill(.black)
            if rotor.status == .offline && rotor.isConnected {
                VStack(spacing: 0) {
                    Text(text).font(.system(size: metrics.headingFontSize * 0.8, weight: .bold)).monospacedDigit()
                    Text("OFFLINE").font(.system(size: max(7, metrics.headingFontSize * 0.3), weight: .bold))
                }
                .foregroundStyle(.red)
            } else {
                Text(text)
                    .font(.system(size: metrics.headingFontSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            // The turning direction is shown.
            HStack {
                DirectionMark(text: "<", on: rotor.status == .turningCCW, size: metrics.headingFontSize)
                Spacer(minLength: 0)
                DirectionMark(text: ">", on: rotor.status == .turningCW, size: metrics.headingFontSize)
            }
            .padding(.horizontal, 1)
        }
        .frame(width: metrics.headingWidth, height: metrics.headingHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(text)
        .accessibilityIdentifier("heading.\(rotor.name)")
    }

    private var tooltip: String {
        if !rotor.isConnected { return "Server disconnected" }
        if let t = RotorStatusStyle.tooltip(rotor.status) { return t }
        var t = metrics.presetUI == .window ? "Click for Presets!" : "Click for Presets!\nTurn CCW hotkey: \(model.hotkeyName(.rotor(rotor.key, .turnCCW)))\nTurn CW hotkey: \(model.hotkeyName(.rotor(rotor.key, .turnCW)))"
        if rotor.rssi != 0 { t += "\nRSSI: \(rotor.rssi) dBm" }
        return t
    }
}

private struct DirectionMark: View {
    let text: String
    let on: Bool
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: max(8, size * 0.45), weight: .heavy))
            .foregroundStyle(on ? Color.red : Color.clear)
            .accessibilityHidden(true)
    }
}

/// The turn-to heading spinner: 0…360, step `rotorStepSize`, modular wrap; Return turns.
struct HeadingStepper: View {
    @Environment(ClientAppModel.self) private var model
    let rotor: RotorItem
    let state: RotorPanelState
    let metrics: RotorRowMetrics

    var body: some View {
        HStack(spacing: 0) {
            TextField("", value: Binding(get: { state.spinner }, set: { state.spinner = min(max($0, 0), 360) }),
                      format: .number.grouping(.never))
                .font(.system(size: metrics.spinnerFontSize))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: metrics.spinnerWidth - 14)
                .onSubmit { model.turn(rotor) }
                .accessibilityIdentifier("spinner.\(rotor.name)")
            Stepper("", onIncrement: { model.stepSpinner(rotor, by: 1) }, onDecrement: { model.stepSpinner(rotor, by: -1) })
                .labelsHidden()
                .controlSize(metrics.size == .small ? .mini : .small)
                .accessibilityIdentifier("stepper.\(rotor.name)")
        }
        .disabled(!rotor.canTurn)
        .help("Preset heading\nHotkey Spin CCW: \(model.hotkeyName(.rotor(rotor.key, .presetTurnCCW)))\nHotkey Spin CW: \(model.hotkeyName(.rotor(rotor.key, .presetTurnCW)))")
        .contextMenu {
            Button("Assign preset CCW hotkey...") { capture(.presetTurnCCW) }
            Button("Assign preset CW hotkey...") { capture(.presetTurnCW) }
        }
    }

    private func capture(_ cmd: RotorHotkeyCommand) {
        HotkeyCaptureController.capture(model: model, panel: rotor.name, action: cmd.rawValue) { key in
            model.bindHotkey(key, to: .rotor(rotor.key, cmd))
        }
    }
}

/// Stack-match oval. Watchdog: no update for 8 s greys it out.
struct StackIndicator: View {
    @Environment(ClientAppModel.self) private var model
    let rotor: RotorItem
    let size: CGFloat
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let live = isLive
            let selected = rotor.stackSelected ?? false
            let ok = rotor.stackStatus == 0
            let fill: Color = !live ? .clear : ok ? (selected ? .green : .gray) : (selected ? .red : Color(red: 200 / 255, green: 0, blue: 0))
            let caption = model.hotkeyCaption(.stack(name: rotor.name))
            ZStack {
                Circle().fill(fill).padding(2)
                if live, let caption, model.settings.showHotkeysOnButtons {
                    Text(caption).font(.system(size: fontSize, weight: .bold)).foregroundStyle(.black)
                        .lineLimit(1).minimumScaleFactor(0.5).padding(4)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onTapGesture { if live { model.toggleStack(rotor) } }
            .help(tooltip(live: live))
            .accessibilityElement()
            .accessibilityLabel(live ? (selected ? "Stack selected" : "Stack not selected") : "No stack match")
            .accessibilityIdentifier("stack.\(rotor.name)")
            .contextMenu {
                if live {
                    Button("Assign Hotkey...") {
                        HotkeyCaptureController.capture(model: model, panel: rotor.name, action: "Stack") { key in
                            model.bindHotkey(key, to: .stack(name: rotor.name))
                        }
                    }
                }
            }
        }
    }

    private var isLive: Bool {
        guard rotor.isConnected, rotor.stackSelected != nil, let at = rotor.stackUpdatedAt else { return false }
        return at.duration(to: .now) < Timing.stackWatchdogSecond
    }

    private func tooltip(live: Bool) -> String {
        guard live else { return "No stack match connected" }
        if rotor.stackStatus == 4 { return "Stack match not responding" }
        if rotor.stackStatus != 0 { return "Error state:\(rotor.stackStatus)" }
        var t = "Hotkey: \(model.hotkeyName(.stack(name: rotor.name)))"
        if rotor.stackRSSI != 0 { t += "\nRSSI: \(rotor.stackRSSI) dBm" }
        return t
    }
}
