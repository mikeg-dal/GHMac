import AppKit
import SwiftUI
import GHEKit
import GHEClientKit

/// `phidgets.xml` as the knob controller's name ↔ serial mapping.
actor PhidgetFileMapping: PhidgetMapping {
    private let store: PhidgetAssignmentStore
    private let changed: @Sendable (Int, String?) -> Void

    init(store: PhidgetAssignmentStore, changed: @escaping @Sendable (Int, String?) -> Void) {
        self.store = store
        self.changed = changed
    }

    func name(forSerial serial: Int) -> String? { store.load().first { $0.serial == serial }?.name }

    func setName(_ name: String?, forSerial serial: Int) {
        var list = store.load().filter { $0.serial != serial }
        if let name { list.append(PhidgetAssignment(name: name, serial: serial)) }
        try? store.save(list)
        changed(serial, name)
    }
}

/// Phidget "E-Knob" support: runs only when Phidget22 is installed. A knob bound to a rotor sets its
/// turn-to spinner and turns on click; bound to a switch it steps positions; bound to a preset window it
/// picks a preset. Holding the button 1.5 s shows the target list.
@MainActor
final class KnobBridge {
    private let model: ClientAppModel
    private let service: PhidgetKnobService
    private let controller: KnobController
    private var targets: [Int: String] = [:]
    private var choices: [Int: [String]] = [:]
    private var overlay: NSPanel?
    private let overlayState = KnobOverlayState()

    /// nil when Phidget22 is not installed (or in simulator mode).
    static func startIfAvailable(model: ClientAppModel) -> KnobBridge? {
        guard !model.isSimulator else { return nil }
        let service = PhidgetKnobService()
        guard service.isAvailable else { return nil }
        let bridge = KnobBridge(model: model, service: service)
        bridge.run()
        return bridge
    }

    private init(model: ClientAppModel, service: PhidgetKnobService) {
        self.model = model
        self.service = service
        let store = PhidgetAssignmentStore(directory: model.directories)
        var initial: [Int: String] = [:]
        for a in store.load() { initial[a.serial] = a.name }
        targets = initial
        let names = KnobChoices()
        let mapping = PhidgetFileMapping(store: store) { serial, name in
            Task { @MainActor in KnobBridge.current?.retarget(serial, name) }
        }
        controller = KnobController(mapping: mapping, choices: { await names.provide() })
        names.source = { [weak model] in model.map(KnobBridge.choiceNames) ?? [] }
        KnobBridge.current = self
    }

    private static var current: KnobBridge?

    /// Visible rotors, their preset windows (Medium/Large) and visible switches, by "target name".
    static func choiceNames(_ model: ClientAppModel) -> [String] {
        var out: [String] = []
        for r in model.trayRotors where r.status != .fixed {
            out.append(targetName(r.key))
            if model.settings.rotorDisplaySize != .small { out.append(PresetFrameState.name(forRotorShortName: r.name)) }
        }
        for s in model.connections.switches where model.isSwitchVisible(s.key) { out.append(targetName(s.key)) }
        return out
    }

    /// The full name without U+001E (`TH6:17220`), for file compatibility.
    static func targetName(_ key: ItemKey) -> String { key.legacyKey.replacingOccurrences(of: "\u{1E}", with: "") }

    private func run() {
        let service = service, controller = controller
        Task {
            for await event in service.events() {
                var spinner: Int?
                if case .delta(let serial, _) = event, let r = rotor(for: serial) { spinner = model.panelState(r).spinner }
                if case .attached(let serial) = event { await controller.setTarget(kind(for: targets[serial]), forSerial: serial) }
                await controller.handle(event, currentSpinner: spinner)
            }
        }
        Task {
            for await out in controller.outputs() { self.perform(out) }
        }
    }

    private func retarget(_ serial: Int, _ name: String?) {
        targets[serial] = name
        let k = kind(for: name)
        Task { await controller.setTarget(k, forSerial: serial) }
    }

    private func kind(for name: String?) -> KnobTargetKind {
        guard let name else { return .none }
        if name.hasSuffix(" preset selection") { return .presets(count: min(model.presets.count, RotorPresets.maxCount)) }
        if model.connections.rotors.contains(where: { Self.targetName($0.key) == name }) { return .rotor }
        if model.connections.switches.contains(where: { Self.targetName($0.key) == name }) { return .switchPanel }
        return .none
    }

    private func rotor(for serial: Int) -> RotorItem? {
        guard let n = targets[serial] else { return nil }
        return model.trayRotors.first { Self.targetName($0.key) == n }
    }

    private func switchItem(for serial: Int) -> SwitchItem? {
        guard let n = targets[serial] else { return nil }
        return model.connections.switches.first { Self.targetName($0.key) == n && model.isSwitchVisible($0.key) }
    }

    private func perform(_ out: KnobOutput) {
        let s = out.serial
        switch out.action {
        case .setSpinner(let v):
            if let r = rotor(for: s) { model.panelState(r).spinner = v }
        case .executeTurn:
            if let r = rotor(for: s) { model.turn(r) }
        case .movePosition(let d):
            if let sw = switchItem(for: s) { model.cycleSwitch(sw, by: d) }
        case .selectFirstPosition:
            if let sw = switchItem(for: s), let first = sw.positionNames.first { model.selectSwitch(sw, position: first) }
        case .highlightPreset(let i):
            overlayState.highlight = i
        case .clickPreset(let i):
            guard let name = targets[s], i < model.presets.count, let h = model.presets[i].headingValue else { return }
            let short = name.replacingOccurrences(of: " preset selection", with: "")
            if let r = model.trayRotors.first(where: { $0.name == short }) { model.turn(r, to: h) }
        case .beginRegistration(_, let index):
            Task {
                let list = await controller.registrationChoices(for: s) ?? []
                self.showOverlay(list, index: index)
            }
        case .registrationIndex(let i):
            overlayState.index = i
        case .commitRegistration:
            overlay?.orderOut(nil)
        }
    }

    /// PhidgetRegistrationFrame: "Turn knob to select a target:".
    private func showOverlay(_ list: [String], index: Int) {
        overlayState.choices = list
        overlayState.index = index
        if overlay == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "E-Knob"
            p.level = .floating
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: KnobOverlayView(state: overlayState))
            overlay = p
        }
        overlay?.center()
        overlay?.orderFront(nil)
    }
}

/// Main-actor source of the registration list, callable from the controller actor.
final class KnobChoices: @unchecked Sendable {
    @MainActor var source: () -> [String] = { [] }
    func provide() async -> [String] { await MainActor.run { source() } }
}

@MainActor @Observable
final class KnobOverlayState {
    var choices: [String] = []
    var index = 0
    var highlight = 0
}

private struct KnobOverlayView: View {
    let state: KnobOverlayState

    var body: some View {
        VStack(spacing: 8) {
            Text("Turn knob to select a target:")
            Text(state.choices.indices.contains(state.index) ? state.choices[state.index] : "")
                .font(.title3.bold())
            Text("Release the button to choose.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }
}
