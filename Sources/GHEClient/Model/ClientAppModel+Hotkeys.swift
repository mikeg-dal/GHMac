import AppKit
import GHEKit
import GHEClientKit

extension ClientAppModel {
    func wireHotkeys() {
        hotkeys.onAction = { [weak self] target, _ in self?.performHotkey(target) }
        // Only visible panels respond.
        hotkeys.isTargetAvailable = { [weak self] target in
            guard let self else { return false }
            switch target {
            case .rotor: return self.rotor(for: target) != nil
            case .switchPosition: return self.switchItem(for: target) != nil
            case .stack(let name): return self.trayRotors.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
    }

    func rotor(for target: HotkeyTarget) -> RotorItem? {
        trayRotors.first { target.refers(to: $0.key) }
    }

    func switchItem(for target: HotkeyTarget) -> SwitchItem? {
        connections.switches.first { target.refers(to: $0.key) && isSwitchVisible($0.key) }
    }

    /// Actions.
    func performHotkey(_ target: HotkeyTarget) {
        switch target {
        case .rotor(_, _, let command):
            guard let r = rotor(for: target) else { return }
            switch command {
            case .presetTurnCW: stepSpinner(r, by: 1)
            case .presetTurnCCW: stepSpinner(r, by: -1)
            case .executeTurn: turn(r)
            case .executeStop: stop(r)
            case .jogCW: jog(r, clockwise: true)
            case .jogCCW: jog(r, clockwise: false)
            case .turnCW: turnContinuous(r, clockwise: true)
            case .turnCCW: turnContinuous(r, clockwise: false)
            }
        case .switchPosition(_, _, let position):
            guard let sw = switchItem(for: target) else { return }
            if position == HotkeyTarget.cycleForward { cycleSwitch(sw, by: 1) }
            else if position == HotkeyTarget.cycleBackward { cycleSwitch(sw, by: -1) }
            else if sw.isBank { toggleBank(sw, position: position) }
            else { selectSwitch(sw, position: position) }
        case .stack(let name):
            if let r = trayRotors.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { toggleStack(r) }
        }
    }

    /// Caption for a button (CTRL→Ct …), or nil if unbound.
    func hotkeyCaption(_ target: HotkeyTarget) -> String? {
        _ = hotkeyRevision
        return hotkeys.bindings.key(for: target)?.caption
    }

    func hotkeyName(_ target: HotkeyTarget) -> String {
        _ = hotkeyRevision
        return hotkeys.bindings.key(for: target)?.legacyString ?? "None"
    }

    /// Binds a captured key; returns an error message to show, or nil on success.
    func bindHotkey(_ key: KeyName, to target: HotkeyTarget) -> String? {
        do {
            let outcome = try hotkeys.bind(key, to: target)
            switch outcome {
            case .accept:
                saveHotkeys()
                return nil
            case .cancel:
                return nil
            case .invalid(let k):
                return "\(k.legacyString) \(HotkeyRegistration.invalidMessage)"
            }
        } catch {
            saveHotkeys()
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func clearHotkeys(for item: ItemKey) {
        for k in hotkeys.bindings.keys {
            for t in hotkeys.bindings.targets(for: k) where t.refers(to: item) { hotkeys.unbind(t) }
        }
        saveHotkeys()
    }

    func clearAllHotkeys() {
        hotkeys.clear()
        saveHotkeys()
    }

    func restartHotkeys() {
        hotkeys.registerAll()
        hotkeyRevision += 1
    }

    func saveHotkeys() {
        hotkeyRevision += 1
        try? HotkeyStore(directory: directories).save(hotkeys.bindings)
    }

    /// Simulator only: press a bound key (exercises dispatch without global registration).
    func simulatePress(_ key: KeyName) {
        (hotkeyBackend as? InMemoryHotkeyBackend)?.press(key)
    }
}

extension ClientAppModel {
    /// Menu/dialog commands (available once the windows are up).
    var actions: ClientActions? { windows?.menuController?.actions }
}
