import SwiftUI
import AppKit
import GHEKit
import GHEClientKit

/// Rotor Map window: legend checkboxes on the left, the beam map on the right.
struct RotorMapWindowView: View {
    @Environment(ClientAppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            MapLegend()
            Divider()
            RotorMapView()
                .frame(minWidth: 200, minHeight: 200)
        }
        .frame(minWidth: 300, minHeight: 240)
    }
}

/// One checkbox per mapped rotor, on its beam colour (no 6-rotor cap).
struct MapLegend: View {
    @Environment(ClientAppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.mapRotors) { r in
                    Toggle(r.name, isOn: Binding(get: { model.isOnMapLegendChecked(r.name) },
                                                 set: { model.setMapVisible($0, shortName: r.name) }))
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: model.beamColor(r)))
                        .accessibilityIdentifier("mapLegend.\(r.name)")
                }
            }
            .padding(4)
        }
        .frame(width: 110)
    }
}

/// Geometry shared by drawing and hit-testing.
struct MapGeometry {
    let size: CGSize
    var side: CGFloat { min(size.width, size.height) }
    var square: CGRect { CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side) }
    var center: CGPoint { CGPoint(x: square.midX, y: square.midY) }

    /// Radius of the i-th beam: each later rotor is inset by 5 % of the square (square, not width).
    func radius(_ index: Int) -> CGFloat { max(side / 2 - side * 0.05 * CGFloat(index), 4) }

    /// Compass bearing (north up, clockwise) of a point, and its distance from the centre.
    func polar(_ p: CGPoint) -> (bearing: Double, distance: CGFloat) {
        let dx = p.x - center.x, dy = p.y - center.y
        var b = atan2(dx, -dy) * 180 / .pi
        if b < 0 { b += 360 }
        return (b, hypot(dx, dy))
    }

    func point(bearing: Double, radius: CGFloat) -> CGPoint {
        let t = (bearing - 90) * .pi / 180
        return CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
    }

    /// Wedge `heading ± bw/2` (a full disc for bw ≥ 360).
    func wedge(heading: Double, beamwidth: Double, radius: CGFloat) -> Path {
        var p = Path()
        if beamwidth >= 360 {
            p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            return p
        }
        p.move(to: center)
        let start = heading - beamwidth / 2
        let steps = max(2, Int(beamwidth / 2))
        for i in 0...steps { p.addLine(to: point(bearing: start + beamwidth * Double(i) / Double(steps), radius: radius)) }
        p.closeSubpath()
        return p
    }

    /// True if `bearing` lies within `heading ± bw/2`, wrapping through north.
    static func contains(bearing: Double, heading: Double, beamwidth: Double) -> Bool {
        if beamwidth >= 360 { return true }
        var d = (bearing - heading).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return abs(d) <= beamwidth / 2
    }
}

/// The beam map: background image in the centred square, translucent wedges, drag-to-turn.
struct RotorMapView: View {
    @Environment(ClientAppModel.self) private var model
    @State private var drag: DragState?

    struct DragState: Equatable {
        var key: ItemKey
        var offset: Double
        var heading: Double
    }

    /// Drawn rotors in map order with their ring index.
    private var drawn: [(index: Int, rotor: RotorItem)] {
        model.mapRotors.enumerated().filter { model.isOnMapLegendChecked($0.element.name) }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        GeometryReader { geo in
            let g = MapGeometry(size: geo.size)
            let items = drawn
            let image = backgroundImage
            ZStack {
                Color.white
                Canvas { ctx, _ in
                    if let image {
                        ctx.draw(Image(nsImage: image).resizable().interpolation(.high), in: g.square)
                    }
                    for (i, r) in items {
                        guard let h = r.heading, h <= 360 else { continue }
                        let bw = Double(model.rotorSettings(r.key).beamWidth)
                        let color = Color(nsColor: model.beamColor(r))
                        if drag?.key == r.key { continue }
                        ctx.fill(g.wedge(heading: h, beamwidth: bw, radius: g.radius(i)), with: .color(color.opacity(0.5)))
                    }
                    if let d = drag, let (i, r) = items.first(where: { $0.rotor.key == d.key }) {
                        let bw = Double(model.rotorSettings(r.key).beamWidth)
                        let color = Color(nsColor: model.beamColor(r))
                        ctx.fill(g.wedge(heading: d.heading, beamwidth: bw, radius: g.radius(i)), with: .color(color.opacity(0.8)))
                        var line = Path()
                        line.move(to: g.center)
                        line.addLine(to: g.point(bearing: d.heading, radius: g.radius(i)))
                        ctx.stroke(line, with: .color(.black), lineWidth: 1.5)
                    }
                }
                MapMouseOverlay(
                    down: { p in beginDrag(at: p, g, items) },
                    dragged: { p in updateDrag(at: p, g) },
                    up: { endDrag() },
                    exited: { drag = nil },
                    menu: { p in contextMenu(at: p, g, items) })
                    .accessibilityIdentifier("rotorMap.canvas")
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(drag.map { String(format: "%03.0f", $0.heading) } ?? "")
        }
    }

    // MARK: Hit testing

    private func hit(_ p: CGPoint, _ g: MapGeometry, _ items: [(index: Int, rotor: RotorItem)]) -> RotorItem? {
        let polar = g.polar(p)
        var found: RotorItem?
        for (i, r) in items {
            guard let h = r.heading, h <= 360, polar.distance <= g.radius(i) else { continue }
            let bw = Double(model.rotorSettings(r.key).beamWidth)
            if MapGeometry.contains(bearing: polar.bearing, heading: h, beamwidth: bw) { found = r }   // last match wins
        }
        return found
    }

    private func beginDrag(at p: CGPoint, _ g: MapGeometry, _ items: [(index: Int, rotor: RotorItem)]) {
        GHELog.ui.debug("map down \(p.x) \(p.y) size \(g.size.width)x\(g.size.height) polar \(g.polar(p).bearing) \(g.polar(p).distance)")
        guard let r = hit(p, g, items), r.canTurn, let h = r.heading else { return }
        let b = g.polar(p).bearing
        drag = DragState(key: r.key, offset: b - h, heading: h)
    }

    private func updateDrag(at p: CGPoint, _ g: MapGeometry) {
        guard var d = drag else { return }
        d.heading = MapAngle.wrap(g.polar(p).bearing - d.offset)
        drag = d
        if let r = model.connections.rotor(d.key) { model.panelState(r).spinner = Int(d.heading.rounded()) % 360 }
    }

    private func endDrag() {
        GHELog.ui.debug("map up \(drag?.heading ?? -1)")
        guard let d = drag else { return }
        drag = nil
        if let r = model.connections.rotor(d.key) { model.turn(r, to: d.heading) }
    }

    /// Right-click: stops the rotor under the mouse and shows the map menu.
    private func contextMenu(at p: CGPoint, _ g: MapGeometry, _ items: [(index: Int, rotor: RotorItem)]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let hitRotor = hit(p, g, items)
        if let r = hitRotor { model.stop(r) }
        m.addItem(ActionItem("Change Image...", modifiers: []) { [model] in
            if let url = model.actions?.chooseImage(title: "Select your Rotor Map Image") {
                model.mapSettings.background = url.path
                model.saveMapSettings()
            }
        })
        m.addItem(ActionItem("Set to default background image", modifiers: []) { [model] in
            model.mapSettings.background = model.defaultCompassURL.path
            model.saveMapSettings()
        })
        if let r = hitRotor {
            m.addItem(.separator())
            m.addItem(ActionItem("Set Beam Color...", modifiers: []) { [model] in
                ColorPanelHelper.shared.show(title: "Choose color for beam pattern:", initial: model.beamColor(r)) { c in
                    model.updateRotorSettings(r.key) { $0.color = c.rgbValue }
                }
            })
            m.addItem(ActionItem("Reset Beam Color...", modifiers: []) { [model] in
                model.updateRotorSettings(r.key) { $0.color = nil }
            })
        }
        return m
    }

    /// A missing image falls back to Images/compass.png, then the bundled compass (no chooser at startup).
    private var backgroundImage: NSImage? {
        let candidates = [model.mapSettings.background, model.defaultCompassURL.path,
                          Bundle.main.url(forResource: "compass", withExtension: "png")?.path].compactMap { $0 }
        for path in candidates { if let img = MapImageCache.image(path) { return img } }
        return nil
    }
}

/// Decoded background pictures by path (shared by the rotor map and map switches).
@MainActor
enum MapImageCache {
    private static var images: [String: NSImage] = [:]

    static func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        images[path] = i
        return i
    }
}

enum MapAngle {
    static func wrap(_ h: Double) -> Double {
        let v = h.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}

/// AppKit mouse handling for the map (left drag, right-click menu, first click on an inactive panel).
struct MapMouseOverlay: NSViewRepresentable {
    var down: (CGPoint) -> Void
    var dragged: (CGPoint) -> Void
    var up: () -> Void
    var exited: () -> Void
    var menu: (CGPoint) -> NSMenu

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ v: MouseView, context: Context) {
        v.down = down; v.dragged = dragged; v.up = up; v.exited = exited; v.menuProvider = menu
    }

    final class MouseView: NSView {
        var down: (CGPoint) -> Void = { _ in }
        var dragged: (CGPoint) -> Void = { _ in }
        var up: () -> Void = {}
        var exited: () -> Void = {}
        var menuProvider: (CGPoint) -> NSMenu = { _ in NSMenu() }
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .image }
        override func accessibilityLabel() -> String? { "Rotor map" }
        override func isAccessibilityEnabled() -> Bool { true }

        private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

        override func mouseDown(with e: NSEvent) {
            if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
            down(local(e))
        }
        override func mouseDragged(with e: NSEvent) { dragged(local(e)) }
        override func mouseUp(with e: NSEvent) { dragged(local(e)); up() }
        override func rightMouseDown(with e: NSEvent) {
            NSMenu.popUpContextMenu(menuProvider(local(e)), with: e, for: self)
        }
        override func mouseExited(with event: NSEvent) { exited() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }
    }
}

/// Shared NSColorPanel with a closure callback.
@MainActor
final class ColorPanelHelper: NSObject {
    static let shared = ColorPanelHelper()
    private var onChange: ((NSColor) -> Void)?

    func show(title: String, initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        let p = NSColorPanel.shared
        self.onChange = nil
        p.title = title
        p.showsAlpha = false
        p.color = initial
        self.onChange = onChange
        p.setTarget(self)
        p.setAction(#selector(changed(_:)))
        NSApp.activate()
        p.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) { onChange?(sender.color) }
}
