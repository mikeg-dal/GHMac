import SwiftUI
import AppKit
import GHEKit
import GHEClientKit

/// Map switch: the selected position's wedge over a picture; clicking picks the
/// direction, the centre picks the omni position.
struct MapSwitchView: View {
    @Environment(ClientAppModel.self) private var model
    let item: SwitchItem
    @State private var stickyOn = false
    @State private var stickyPosition: String?

    private var omni: SwitchPosition? { item.descriptor.positions.first { $0.beamwidth > 180 } }

    var body: some View {
        let error = SwitchColors.statusText(item.status)
        let selected = model.displayedPosition(item)
        VStack(spacing: 4) {
            Text(item.name).font(.system(size: 18, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
            ZStack(alignment: .topLeading) {
                if let error {
                    Color.red
                    Text(SwitchColors.shortStatusText(item.status))
                        .font(.title2.bold()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .help(error)
                } else {
                    GeometryReader { geo in
                        let g = MapGeometry(size: geo.size)
                        Canvas { ctx, _ in draw(ctx, g, selected: selected) }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in click(at: v.location, g) })
                    }
                }
                if let sel = selected, model.settings.showHotkeysOnButtons,
                   let cap = model.hotkeyCaption(.switchPosition(item.key, sel)) {
                    Text(cap).font(.caption.bold()).padding(3)
                }
            }
            .frame(minWidth: 160, minHeight: 160)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.name) map")
            .accessibilityValue(selected ?? "")
            .accessibilityIdentifier("mapSwitch.\(item.name)")
            if model.settings.showDropOnSwitches { selectionBox }
        }
        .padding(6)
        .contextMenu { menu }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ g: MapGeometry, selected: String?) {
        if let img = backgroundImage {
            ctx.draw(Image(nsImage: img).resizable(), in: g.square)
        } else {
            ctx.fill(Path(ellipseIn: g.square), with: .color(Color(white: 0.75).opacity(0.5)))
        }
        guard let sel = selected, let p = item.descriptor.positions.first(where: { $0.name == sel }) else { return }
        let color = beamColor.opacity(0.5)
        let r = g.side / 2
        ctx.fill(g.wedge(heading: Double(p.heading), beamwidth: Double(p.beamwidth), radius: r), with: .color(color))
        if p.bidirectional && p.beamwidth < 360 {
            ctx.fill(g.wedge(heading: Double(p.heading + 180), beamwidth: Double(p.beamwidth), radius: r), with: .color(color))
        }
    }

    private var beamColor: Color {
        if let c = model.switchWindow(item.key).beamColor { return Color(nsColor: NSColor(rgb: c)) }
        return SwitchColors.global(model.settings.switchButtonColor)
    }

    private var backgroundImage: NSImage? {
        switch model.switchWindow(item.key).image {
        case .none?: return nil
        case .file(let path)?: return MapImageCache.image(path) ?? defaultImage
        case nil: return defaultImage
        }
    }

    private var defaultImage: NSImage? {
        if let p = model.switchWindowConfig.lastImage, let i = MapImageCache.image(p) { return i }
        return MapImageCache.image(model.defaultCompassURL.path)
            ?? Bundle.main.path(forResource: "compass", ofType: "png").flatMap(MapImageCache.image)
    }

    // MARK: Clicking

    /// Wedges that wrap past north and reciprocal lobes are clickable; positions are tried in
    /// profile order; no match → omni.
    private func click(at p: CGPoint, _ g: MapGeometry) {
        let polar = g.polar(p)
        if polar.distance <= 0.15 * g.side, let o = omni { model.selectSwitch(item, position: o.name); return }
        for pos in item.descriptor.positions where pos.beamwidth <= 180 {
            let bw = Double(pos.beamwidth)
            if MapGeometry.contains(bearing: polar.bearing, heading: Double(pos.heading), beamwidth: bw)
                || (pos.bidirectional && MapGeometry.contains(bearing: polar.bearing, heading: Double(pos.heading + 180), beamwidth: bw)) {
                model.selectSwitch(item, position: pos.name)
                return
            }
        }
        if let o = omni { model.selectSwitch(item, position: o.name) }
    }

    // MARK: Selection box

    private var selectionBox: some View {
        let fwd = model.settings.showHotkeysOnButtons ? model.hotkeyCaption(.switchPosition(item.key, HotkeyTarget.cycleForward)) : nil
        let back = model.settings.showHotkeysOnButtons ? model.hotkeyCaption(.switchPosition(item.key, HotkeyTarget.cycleBackward)) : nil
        return HStack {
            Button(back.map { "<\($0)<" } ?? "<<") { model.cycleSwitch(item, by: -1) }
                .accessibilityIdentifier("mapSwitchBack.\(item.name)")
            if model.isStickyEnabled {
                Toggle("Sticky", isOn: Binding(get: { stickyOn }, set: { on in
                    stickyOn = on
                    stickyPosition = on ? model.displayedPosition(item) : nil
                    model.setSticky(item.key, position: stickyPosition)
                }))
                .toggleStyle(.button)
            }
            Button(fwd.map { ">\($0)>" } ?? ">>") { model.cycleSwitch(item, by: 1) }
                .accessibilityIdentifier("mapSwitchForward.\(item.name)")
        }
    }

    // MARK: Menu

    @ViewBuilder
    private var menu: some View {
        if let cur = model.displayedPosition(item) {
            Button("Assign hotkey for current position: \(cur)") { capture(cur) }
        }
        Button("Assign hotkey to cycle forward...") { capture(HotkeyTarget.cycleForward) }
        Button("Assign hotkey to cycle backward...") { capture(HotkeyTarget.cycleBackward) }
        Divider()
        Button("Set custom background image...") {
            if let url = model.actions?.chooseImage(title: "Select background image", prompt: "Set as background") {
                model.updateSwitchWindow(item.key) { $0.image = .file(path: url.path) }
            }
        }
        Button("Set to default background") { model.updateSwitchWindow(item.key) { $0.image = nil } }
        Button("Remove background image...") { model.updateSwitchWindow(item.key) { $0.image = SwitchWindowImage.none } }
        Button("Set beam color...") {
            ColorPanelHelper.shared.show(title: "Choose color for beam pattern:", initial: NSColor(beamColor)) { c in
                model.updateSwitchWindow(item.key) { $0.beamColor = c.rgbValue }
            }
        }
        Button("Reset beam color") { model.updateSwitchWindow(item.key) { $0.beamColor = nil } }
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

/// Tornado tuner.
struct TornadoTunerView: View {
    @Environment(ClientAppModel.self) private var model
    let item: TornadoItem
    @State private var confirmRotor: String?

    var body: some View {
        let d = item.descriptor
        let st = item.state
        VStack(spacing: 6) {
            Text(d.name).font(.system(size: 14, weight: .bold))
            ForEach(Array(d.rotors.enumerated()), id: \.offset) { i, rotor in
                HStack(spacing: 4) {
                    Text(rotor).frame(width: 100, alignment: .leading).lineLimit(1)
                    Button("<<") { model.connections.tornadoTurn(item, rotor: rotor, cw: false) }
                    // The heading is read-only.
                    Text(Self.format(st.flatMap { i < $0.headings.count ? $0.headings[i] : nil }))
                        .font(.system(size: 14, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(red: 1, green: 1, blue: 102 / 255))
                        .frame(width: 50, height: 22)
                        .background(Color.black)
                        .contextMenu { Button("Calibrate") { confirmRotor = rotor } }
                    Button(">>") { model.connections.tornadoTurn(item, rotor: rotor, cw: true) }
                }
            }
            ForEach(d.positions, id: \.self) { pos in
                Button { model.connections.setTornado(item, position: pos) } label: {
                    Text(pos).font(.system(size: 24))
                }
                .buttonStyle(ColoredButtonStyle(fill: st?.position == pos ? Color(red: 0, green: 1, blue: 0) : SwitchColors.unselected,
                                                textColor: .black))
                .frame(minHeight: 36)
                .accessibilityIdentifier("tornado.\(d.name).\(pos)")
            }
            SoftwareControlToggles(key: item.key)
        }
        .padding(6)
        .background(st.map { $0.status != 0 } == true ? Color.red : Color.clear)
        .alert("Calibrate?", isPresented: Binding(get: { confirmRotor != nil }, set: { if !$0 { confirmRotor = nil } })) {
            Button("Yes") { if let r = confirmRotor { model.connections.tornadoCalibrate(item, rotor: r) } }
            Button("No", role: .cancel) {}
        } message: {
            Text("Do you want to calibrate this device?")
        }
    }

    static func format(_ raw: String?) -> String {
        guard let raw, let v = JavaDouble.parse(raw) else { return "---" }
        return String(format: "%03d", Int(v.rounded()))
    }
}
