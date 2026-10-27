import AppKit
import GHEKit
import GHEClientKit

extension ClientAppModel {
    // MARK: Switch visibility

    /// Switch windows follow `switchbands.ini` like the tray.
    func isSwitchVisible(_ key: ItemKey) -> Bool {
        _ = deviceRevision
        return bands.isVisible(deviceBands: Set(switchSettings(key).bands))
    }

    /// Keys of every switch / Tornado window that should be open, in inventory order.
    var visibleSwitchKeys: [ItemKey] {
        connections.switches.filter { isSwitchVisible($0.key) }.map(\.key)
            + connections.tornados.filter { isSwitchVisible($0.key) }.map(\.key)
    }

    // MARK: Band changes

    /// The Band menu's columns for the current scope ("ALL" first).
    var bandMenuNames: [String] { [Band.allName] + settings.bandScope.columns.map(\.rawValue) }

    /// Manual pick from the Band menu: both slots, then VFO-A band switches get the canonical frequency.
    func pickManualBand(_ name: String) {
        for e in ManualBandFrequencies.events(forPick: name) { handleLogger(e) }
    }

    func setLoggerSource(_ source: LoggerSource) {
        settings.loggerSource = source
        if source == .manual { logSoftware("Manual band selection") }
    }

    func handleLogger(_ event: LoggerEvent) {
        switch event {
        case .band(let slot, let band):
            let old = bands
            if bands.set(slot, to: band) { bandsDidChange(from: old) }
        case .frequency(let vfo, let mhz):
            applyFrequency(mhz, vfo: vfo)
        case .turnActive(let raw):
            connections.turnActive(raw: raw)
        case .stopActive:
            connections.stopActive()
        case .focusRadio:
            break
        case .raw(let text):
            logSoftware(text)
        case .status(let text):
            logSoftware(text)
        }
    }

    private func bandsDidChange(from old: BandState) {
        settings.bandA = bands.a
        settings.bandB = bands.b
        applyDefaultPositions(previousBands: old)
    }

    /// When a switch becomes visible because of a band change, its "Default"/`*` position is selected
    /// (first match only; banks are set ON, never toggled).
    func applyDefaultPositions(previousBands old: BandState) {
        for sw in connections.switches where isSwitchVisible(sw.key) {
            guard !old.isVisible(deviceBands: Set(switchSettings(sw.key).bands)) else { continue }
            switch DefaultPositionRule.action(in: sw.positionNames, isBank: sw.isBank) {
            case .select(let p)?: selectSwitch(sw, position: p)
            case .setOn(let p)?: connections.setSwitch(sw, position: p, on: true)
            case nil: break
            }
        }
    }

    /// Band switches (and Tornado tuners) with Software Control and the matching VFO box checked pick the
    /// position whose range holds the frequency.
    func applyFrequency(_ mhz: Double, vfo: VFO) {
        for sw in connections.switches where sw.displayType == .band && isSwitchVisible(sw.key) {
            let c = switchWindow(sw.key)
            guard c.isSoftwareControl, vfo == .a ? c.isVFOA : c.isVFOB else { continue }
            let positions = sw.descriptor.positions.map {
                BandSwitchPosition(name: $0.name, lowerMHz: $0.lowerMHz, upperMHz: $0.upperMHz)
            }
            let current = pendingSwitch[sw.key] ?? sw.selectedPosition
            if let p = BandSwitchSelector.select(positions: positions, current: current, freqMHz: mhz,
                                                 locked: Set(sw.locks)) {
                selectSwitch(sw, position: p)
            }
        }
        for t in connections.tornados where isSwitchVisible(t.key) {
            let c = switchWindow(t.key)
            guard c.isSoftwareControl, vfo == .a ? c.isVFOA : c.isVFOB else { continue }
            let d = t.descriptor
            var positions: [BandSwitchPosition] = []
            for (i, name) in d.positions.enumerated() {
                let lo = i < d.lower.count ? JavaDouble.parse(d.lower[i]) ?? 0 : 0
                let hi = i < d.upper.count ? JavaDouble.parse(d.upper[i]) ?? 0 : 0
                positions.append(BandSwitchPosition(name: name, lowerMHz: lo, upperMHz: hi))
            }
            // Profile order instead of HashMap order.
            if let p = BandSwitchSelector.select(positions: positions, current: t.state?.position, freqMHz: mhz) {
                connections.setTornado(t, position: p)
            }
        }
    }

    // MARK: Switch commands

    /// Selects a position of an exclusive switch: shown at once (pending) and sent as `SET_SWITCH`.
    func selectSwitch(_ sw: SwitchItem, position: String) {
        guard !sw.isLocked(position) else { return }
        if let cur = sw.selectedPosition { previousSwitchPosition[sw.key] = cur }
        pendingSwitch[sw.key] = position
        connections.setSwitch(sw, position: position)
        let key = sw.key
        Task {
            try? await Task.sleep(for: .seconds(3))
            if self.pendingSwitch[key] == position { self.pendingSwitch[key] = nil }
        }
    }

    func toggleBank(_ sw: SwitchItem, position: String) {
        let on = !sw.selected.contains(position)
        connections.setSwitch(sw, position: position, on: on)
    }

    /// Selected position as displayed (pending selection first).
    func displayedPosition(_ sw: SwitchItem) -> String? {
        pendingSwitch[sw.key] ?? sw.selectedPosition
    }

    /// Hotkey CYCLE_FORWARD / CYCLE_BACKWARD and knob moves: wrap around (skipping locked positions).
    func cycleSwitch(_ sw: SwitchItem, by delta: Int) {
        let names = sw.positionNames
        guard !names.isEmpty, !sw.isBank else { return }
        var i = displayedPosition(sw).flatMap { names.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        for _ in 0..<names.count {
            i = ((i + delta) % names.count + names.count) % names.count
            if !sw.isLocked(names[i]) { break }
        }
        selectSwitch(sw, position: names[i])
    }
}
