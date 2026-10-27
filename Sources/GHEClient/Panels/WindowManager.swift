import AppKit
import SwiftUI
import GHEKit
import GHEClientKit

/// Creates, shows and hides every client window and applies the File / Configuration window options
/// (Always On Top, Lock Window Positions, Reset Window Positions).
@MainActor
final class WindowManager {
    let model: ClientAppModel
    weak var menuController: MenuController?
    private(set) var tray: PanelController!
    private var map: PanelController?
    private var switchPanels: [ItemKey: PanelController] = [:]
    private var switchTitleLoops: [ItemKey: ObservationLoop] = [:]
    private var presetPanels: [String: PanelController] = [:]
    private var configWindows: [String: PanelController] = [:]
    private var loops: [ObservationLoop] = []
    /// The user closed the map by hand: keep it closed until the map's rotor set changes.
    private var mapClosedByUser = false

    init(model: ClientAppModel) {
        self.model = model
        model.windows = self
    }

    // MARK: Startup

    func start() {
        tray = PanelController(id: "trayWindow", title: model.trayTitle, kind: .operatingPanel, resizable: false) {
            TrayView().environment(model)
        }
        tray.shouldClose = { NSApp.terminate(nil); return false }
        tray.setJavaFrame(x: model.settings.x, y: model.settings.y)
        tray.frameChanged = { [weak self] _ in
            guard let self else { return }
            let f = self.tray.javaFrame
            self.model.settings.x = f.x
            self.model.settings.y = f.y
        }
        tray.show()
        // Re-place after the first SwiftUI layout has sized the window.
        let (x, y) = (model.settings.x, model.settings.y)
        DispatchQueue.main.async { [weak self] in self?.tray.setJavaFrame(x: x, y: y) }

        loops.append(ObservationLoop({ [model] in model.trayTitle }) { [weak self] title in self?.tray.window.title = title })
        loops.append(ObservationLoop({ [model] in model.settings.alwaysOnTop }) { [weak self] _ in self?.applyLevels() })
        loops.append(ObservationLoop({ [model] in model.windowsLocked }) { [weak self] _ in self?.applyLock() })
        loops.append(ObservationLoop({ [model] in model.visibleSwitchKeys }) { [weak self] keys in self?.reconcileSwitches(keys) })
        loops.append(ObservationLoop({ [model] in model.mapRotors.map(\.key) }) { [weak self] keys in self?.reconcileMap(keys) })
        loops.append(ObservationLoop({ [model] in model.settings.globalPresetsVisible }) { [weak self] on in
            self?.setGlobalPresetsVisible(on)
        })
        loops.append(ObservationLoop({ [model] in model.settings.switchDisplaySize }) { [weak self] _ in self?.refitSwitches() })
        loops.append(ObservationLoop({ [model] in model.trayRotors.map(\.key) }) { [weak self] keys in self?.reconcilePresetPanels(keys) })
    }

    var allControllers: [PanelController] {
        [tray].compactMap { $0 } + [map].compactMap { $0 } + Array(switchPanels.values) + Array(presetPanels.values)
            + Array(configWindows.values)
    }

    func raiseOperatingPanels() {
        let panels = [map].compactMap { $0 } + Array(switchPanels.values) + Array(presetPanels.values) + [tray].compactMap { $0 }
        for p in panels where p.isVisible { p.window.orderFront(nil) }
    }

    // MARK: Options

    /// Always On Top: tray and switch windows. Preset windows always float.
    private func applyLevels() {
        let on = model.settings.alwaysOnTop
        tray.setFloating(on)
        for p in switchPanels.values { p.setFloating(on) }
        for p in presetPanels.values { p.setFloating(true) }
    }

    private func applyLock() {
        for c in allControllers { c.setLocked(model.windowsLocked) }
    }

    /// File ▸ Reset Window Positions: unlock, then move every open window to the top-left corner.
    func resetPositions() {
        model.windowsLocked = false
        for c in allControllers where c.isVisible { c.moveToOrigin() }
        saveAllWindowFrames()
    }

    // MARK: Switch windows

    private func reconcileSwitches(_ keys: [ItemKey]) {
        let wanted = Set(keys)
        for (key, panel) in switchPanels where !wanted.contains(key) {
            switchTitleLoops[key]?.cancel()
            switchTitleLoops[key] = nil
            panel.hide()
            switchPanels[key] = nil
        }
        for key in keys where switchPanels[key] == nil { openSwitch(key) }
    }

    private func openSwitch(_ key: ItemKey) {
        let config = model.switchWindow(key)
        let panel = PanelController(id: "switchWindow.\(key.name)", title: "", kind: .operatingPanel, resizable: true) {
            SwitchPanelView(key: key).environment(model)
        }
        if let w = config.width, let h = config.height {
            panel.window.setContentSize(NSSize(width: w, height: h))
        }
        if let x = config.x, let y = config.y {
            panel.setJavaFrame(x: x, y: y, width: config.width, height: config.height)
        } else {
            // New switch windows are cascaded so they don't stack.
            let f = tray.javaFrame
            // Tiled to the right of the tray and map, wrapping to a row below them.
            let mapWidth = map.map { $0.javaFrame.width + 8 } ?? 0
            let startX = f.x + f.width + 8 + mapWidth
            let screenW = Int(NSScreen.screens.first?.visibleFrame.width ?? 1440)
            let perRow = max(1, (screenW - startX) / 258)
            let i = switchPanels.count
            let x = i < perRow ? startX + i * 258 : (i - perRow) * 258
            let y = i < perRow ? f.y : f.y + max(f.height, 450) + 8
            panel.setJavaFrame(x: x, y: y)
        }
        panel.frameChanged = { [weak self, weak panel] _ in
            guard let panel else { return }
            let f = panel.javaFrame
            self?.model.updateSwitchWindow(key) { $0.x = f.x; $0.y = f.y; $0.width = f.width; $0.height = f.height }
        }
        // Closing a switch window only hides it until it is shown again by a band change.
        panel.didClose = { [weak self] in
            self?.switchPanels[key] = nil
            self?.switchTitleLoops[key]?.cancel()
            self?.switchTitleLoops[key] = nil
        }
        panel.setFloating(model.settings.alwaysOnTop)
        panel.setLocked(model.windowsLocked)
        switchTitleLoops[key] = ObservationLoop({ [model] in Self.switchTitle(model, key) }) { [weak panel] t in panel?.window.title = t }
        switchPanels[key] = panel
        panel.show()
        if config.width == nil {
            // Default switch window is 250 × 310.
            let isMap = model.connections.switchItem(key)?.displayType == .map
            DispatchQueue.main.async { panel.fitToContent(minimum: NSSize(width: 250, height: isMap ? 310 : 0)) }
        }
    }

    /// Changing the switch size or colour resizes the panels to fit.
    private func refitSwitches() {
        DispatchQueue.main.async { [weak self] in
            for p in self?.switchPanels.values ?? [:].values { p.fitToContent(minimum: NSSize(width: 250, height: 0)) }
        }
    }

    /// `"<rssi>dBm"`, or `"Error"`.
    static func switchTitle(_ model: ClientAppModel, _ key: ItemKey) -> String {
        if let sw = model.connections.switchItem(key) {
            if sw.status > 0 && sw.status != 9 { return "Error" }
            return "\(sw.rssi)dBm"
        }
        if let t = model.connections.tornado(key), let st = t.state {
            return st.status != 0 ? "Error" : "\(st.rssi)dBm"
        }
        return "0dBm"
    }

    // MARK: Rotor map

    private func reconcileMap(_ keys: [ItemKey]) {
        if keys.isEmpty {
            map?.hide()
            mapClosedByUser = false
            return
        }
        if map == nil {
            let s = model.mapSettings
            let panel = PanelController(id: "rotorMapWindow", title: "Rotor Map", kind: .operatingPanel, resizable: true,
                                        contentSizedToFit: false) {
                RotorMapWindowView().environment(model)
            }
            if s.x == 0 && s.y == 0 {
                // First run: start beside the tray instead of under it.
                let t = tray.javaFrame
                panel.setJavaFrame(x: t.x + max(t.width, 581) + 8, y: t.y, width: s.width, height: s.height)
            } else {
                panel.setJavaFrame(x: s.x, y: s.y, width: s.width, height: s.height)
            }
            panel.frameChanged = { [weak self, weak panel] _ in
                guard let self, let panel else { return }
                let f = panel.javaFrame
                self.model.mapSettings.x = f.x; self.model.mapSettings.y = f.y
                self.model.mapSettings.width = f.width; self.model.mapSettings.height = f.height
                self.model.saveMapSettings()
            }
            panel.shouldClose = { [weak self] in self?.mapClosedByUser = true; return true }
            panel.setLocked(model.windowsLocked)
            map = panel
        }
        if !mapClosedByUser, map?.isVisible == false { map?.show() }
    }

    func showMap() {
        mapClosedByUser = false
        if map == nil { reconcileMap(model.mapRotors.map(\.key)) }
        map?.show(activate: false)
    }

    // MARK: Presets windows

    static let globalPresetsID = PresetFrameState.globalName

    /// Medium/Large: clicking the rotor name or heading opens its preset window (always on top).
    func showPresets(for rotor: RotorItem) {
        let name = PresetFrameState.name(forRotorShortName: rotor.name)
        let key = rotor.key
        let panel = presetPanels[name] ?? makePresetPanel(name: name) {
            PresetPanelView(target: .rotor(key), frameName: name).environment(self.model)
        }
        panel.show()
    }

    func hidePresets(frameName: String) { presetPanels[frameName]?.hide() }

    private func setGlobalPresetsVisible(_ on: Bool) {
        let name = Self.globalPresetsID
        if on {
            let panel = presetPanels[name] ?? makePresetPanel(name: name) {
                PresetPanelView(target: .global, frameName: name).environment(self.model)
            }
            panel.show()
        } else {
            presetPanels[name]?.hide()
        }
    }

    /// Restores preset windows that were open at quit once their rotor appears; hides those whose rotor went.
    private func reconcilePresetPanels(_ keys: [ItemKey]) {
        let rotors = model.trayRotors
        for r in rotors {
            let name = PresetFrameState.name(forRotorShortName: r.name)
            if presetPanels[name] == nil, model.presetFrameStates[name]?.visible == true, model.settings.rotorDisplaySize != .small {
                showPresets(for: r)
            }
        }
        let names = Set(rotors.map { PresetFrameState.name(forRotorShortName: $0.name) })
        for (name, p) in presetPanels where name != Self.globalPresetsID && !names.contains(name) { p.hide() }
    }

    private func makePresetPanel<V: View>(name: String, @ViewBuilder content: () -> V) -> PanelController {
        // The title names the rotor.
        let title = name == Self.globalPresetsID ? "Global Presets"
            : name.replacingOccurrences(of: " preset selection", with: "") + " Presets"
        let panel = PanelController(id: "presetWindow.\(name)", title: title, kind: .operatingPanel,
                                    resizable: true, contentSizedToFit: false, content: content)
        let s = model.settings
        if let f = model.presetFrameStates[name] {
            panel.setJavaFrame(x: f.x, y: f.y, width: f.width, height: f.height)
        } else {
            let t = tray.javaFrame
            panel.setJavaFrame(x: t.x + 40, y: t.y + t.height, width: s.presetEntryWidth, height: s.presetEntryHeight)
        }
        panel.frameChanged = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            let f = panel.javaFrame
            self.model.settings.presetEntryWidth = f.width
            self.model.settings.presetEntryHeight = f.height
        }
        if name == Self.globalPresetsID {
            panel.didClose = { [weak self] in self?.model.settings.globalPresetsVisible = false }
        }
        panel.setFloating(true)
        panel.setLocked(model.windowsLocked)
        presetPanels[name] = panel
        return panel
    }

    // MARK: Config windows

    /// Opens (or brings forward) a configuration window; these activate the app like normal windows.
    func openConfig<V: View>(_ id: String, title: String, resizable: Bool = false, recreate: Bool = false,
                             size: NSSize? = nil, @ViewBuilder content: () -> V) {
        if recreate, let old = configWindows[id] { old.hide(); configWindows[id] = nil }
        if let w = configWindows[id] {
            w.show(activate: true)
            return
        }
        let c = PanelController(id: id, title: title, kind: .configWindow, resizable: resizable,
                                contentSizedToFit: !resizable) {
            content().environment(model)
        }
        c.window.center()
        c.setLocked(model.windowsLocked)
        configWindows[id] = c
        c.show(activate: true)
        if let size {
            // After the hosting view's first layout, which would otherwise shrink the window to its minimum.
            DispatchQueue.main.async {
                c.window.setContentSize(size)
                c.window.center()
            }
        }
    }

    func closeConfig(_ id: String) {
        configWindows[id]?.window.close()
    }

    func isConfigVisible(_ id: String) -> Bool { configWindows[id]?.isVisible ?? false }

    // MARK: Saving

    /// Tray x/y, map frame and presetFrames.xml (written at quit; switch frames save on move).
    func saveAllWindowFrames() {
        guard !model.skipSaveOnQuit else { return }
        if let tray {
            let f = tray.javaFrame
            model.settings.x = f.x; model.settings.y = f.y
        }
        var frames: [PresetFrameState] = []
        for (name, p) in presetPanels {
            let f = p.javaFrame
            frames.append(PresetFrameState(name: name, visible: p.isVisible, keepVisible: model.presetKeepVisible[name] ?? false,
                                           x: f.x, y: f.y, width: f.width, height: f.height))
        }
        for (name, f) in model.presetFrameStates where presetPanels[name] == nil { frames.append(f) }
        try? PresetFramesStore(directory: model.directories).save(frames.sorted { $0.name < $1.name })
    }
}
