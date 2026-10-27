import AppKit
import Observation
import GHEKit
import GHEClientKit

/// Per-row UI state of a rotor panel: the turn-to spinner, "Show tenths" and the jog accumulator.
@MainActor @Observable
final class RotorPanelState {
    /// The heading spinner (0…360).
    var spinner: Int
    /// Options popup ▸ "Show tenths (if available)" (not persisted).
    var showTenths = false
    /// The spinner was seeded from the first reported heading.
    @ObservationIgnored var seeded = false
    @ObservationIgnored var jogTask: Task<Void, Never>?
    @ObservationIgnored var turnLockoutUntil: ContinuousClock.Instant?

    init(spinner: Int) { self.spinner = spinner }
}

/// The six map/beam colours used when a rotor has no colour of its own.
enum RotorBeamColors {
    static let base: [UInt32] = [0x64FF64, 0xFF6464, 0x96FFFF, 0xFFFF64, 0xFF64FF, 0x6464FF]
}

extension ClientAppModel {
    // MARK: Visibility

    /// Tray rule: the rotor's tray bands contain band A or B, or a band is "ALL".
    func isTrayVisible(_ key: ItemKey) -> Bool {
        _ = deviceRevision
        return bands.isVisible(deviceBands: Set(rotorSettings(key).trayBands))
    }

    /// Map rule: map bands contain A or B, or a band is "ALL" (case-insensitive, both slots).
    func isMapVisible(_ key: ItemKey) -> Bool {
        _ = deviceRevision
        return bands.isVisible(deviceBands: Set(rotorSettings(key).mapBands))
    }

    /// Tray rows in Tray "Order".
    var trayRotors: [RotorItem] {
        connections.rotors.filter { isTrayVisible($0.key) }
            .sorted { rotorSettings($0.key).priority < rotorSettings($1.key).priority }
    }

    /// Rotors drawn on the map, in map order (no 6-rotor cap).
    var mapRotors: [RotorItem] {
        connections.rotors.filter { isMapVisible($0.key) }
            .sorted { rotorSettings($0.key).mapPriority < rotorSettings($1.key).mapPriority }
    }

    /// Beam colour: own colour from rotorcolors.ini, else the base colour by map order.
    func beamColor(_ rotor: RotorItem) -> NSColor {
        if let rgb = rotorSettings(rotor.key).color { return NSColor(rgb: rgb) }
        let i = mapRotors.firstIndex { $0.key == rotor.key } ?? connections.rotors.firstIndex { $0.key == rotor.key } ?? 0
        return NSColor(rgb: RotorBeamColors.base[i % RotorBeamColors.base.count])
    }

    // MARK: Panel state

    func panelState(_ rotor: RotorItem) -> RotorPanelState {
        if let s = panelStates[rotor.key] { return s }
        let s = RotorPanelState(spinner: Int((rotor.heading ?? 0).rounded()) % 361)
        s.seeded = rotor.heading.map { $0 <= 360 } ?? false
        panelStates[rotor.key] = s
        return s
    }

    /// Puts the first real heading into the spinner.
    func seedSpinner(_ rotor: RotorItem) {
        let s = panelState(rotor)
        guard !s.seeded, let h = rotor.heading, h <= 360 else { return }
        s.seeded = true
        s.spinner = Int(h.rounded()) % 360
    }

    // MARK: Commands

    /// Turn: `TURN␟name␟<spinner>` (ganged through ConnectionManager).
    func turn(_ rotor: RotorItem) {
        guard rotor.canTurn else { return }
        connections.turn(rotor, to: .heading(Double(panelState(rotor).spinner)))
    }

    func turn(_ rotor: RotorItem, to heading: Double) {
        guard rotor.canTurn else { return }
        panelState(rotor).spinner = Int(heading.rounded()) % 360
        connections.turn(rotor, to: .heading(Double(panelState(rotor).spinner)))
    }

    func stop(_ rotor: RotorItem) {
        guard rotor.canStop else { return }
        connections.stop(rotor)
    }

    /// Spinner ± step. Modular wrap (355 + 10 → 5, 5 − 10 → 355).
    func stepSpinner(_ rotor: RotorItem, by direction: Int) {
        let state = panelState(rotor)
        state.spinner = Self.wrapStep(state.spinner, step: settings.rotorStepSize * direction)
    }

    nonisolated static func wrapStep(_ value: Int, step: Int) -> Int {
        let v = (value + step) % 360
        return v < 0 ? v + 360 : v
    }

    /// Jog (Medium/Large): clicks within 1 s accumulate, then Turn fires once.
    /// The burst starts from the stored heading, not the display text.
    func jog(_ rotor: RotorItem, clockwise: Bool) {
        guard rotor.canTurn else { return }
        let state = panelState(rotor)
        if state.jogTask == nil, let h = rotor.heading, h <= 360 {
            state.spinner = Int(h.rounded()) % 360
        }
        stepSpinner(rotor, by: clockwise ? 1 : -1)
        state.jogTask?.cancel()
        state.jogTask = Task {
            try? await Task.sleep(for: Timing.jogDebounce)
            guard !Task.isCancelled else { return }
            state.jogTask = nil
            self.turn(rotor)
        }
    }

    /// TURN_CW / TURN_CCW hotkeys: `TURN␟name␟CW|CCW`, 500 ms lockout.
    func turnContinuous(_ rotor: RotorItem, clockwise: Bool) {
        let state = panelState(rotor)
        let now = ContinuousClock.now
        if let until = state.turnLockoutUntil, now < until { return }
        state.turnLockoutUntil = now.advanced(by: Timing.turnHotkeyLockout)
        connections.turn(rotor, to: clockwise ? .cw : .ccw)
    }

    /// Global presets frame: every active, visible rotor.
    func turnActiveRotors(to heading: String) {
        connections.turnActive(raw: heading)
    }

    func toggleStack(_ rotor: RotorItem) {
        guard rotor.stackStatus == 0, let selected = rotor.stackSelected else { return }
        connections.setStack(rotor.key, selected: !selected)
    }

    func setActive(_ rotor: RotorItem, _ active: Bool) {
        rotor.isActive = active
        updateRotorSettings(rotor.key) { $0.active = active }
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    var rgbValue: UInt32 {
        let c = usingColorSpace(.sRGB) ?? self
        let r = UInt32((c.redComponent * 255).rounded()), g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
