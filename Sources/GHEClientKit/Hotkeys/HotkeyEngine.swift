import Foundation

public enum HotkeyError: Error, Equatable, LocalizedError {
    case unknownKey(String)
    case unsupportedKey(String)
    case optionOnlyCombination(String)
    case registrationFailed(String, Int32)
    case accessibilityNotTrusted
    case eventTapUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let k): "\(k) is not a key this Mac can register."
        case .unsupportedKey(let k): "\(k) can't be used as a global hotkey on macOS (enable the event-tap option for media keys)."
        case .optionOnlyCombination(let k):
            "\(k) uses only Option (or Option+Shift). macOS 15 and later refuse these as global hotkeys; add Control or Command."
        case .registrationFailed(let k, let s): "macOS refused the hotkey \(k) (error \(s)). Another app may already use it."
        case .accessibilityNotTrusted: "The event-tap hotkeys need Accessibility permission (System Settings › Privacy & Security › Accessibility)."
        case .eventTapUnavailable: "The keyboard event tap could not be created."
        }
    }
}

/// In-process global hotkeys.
/// Owns the bindings, keeps the backend's registrations in sync, and dispatches presses.
// Dispatch happens on the main actor.
@MainActor
public final class HotkeyEngine {
    public private(set) var bindings: HotkeyBindings
    private let backend: any HotkeyBackend
    /// Keys the backend refused, with the reason (shown as "unsupported" in the Hotkeys window).
    public private(set) var failures: [KeyName: HotkeyError] = [:]
    public private(set) var isSuspended = false

    /// Called once per target bound to the pressed key.
    public var onAction: ((HotkeyTarget, KeyName) -> Void)?
    /// Only targets for which this returns true respond (live, visible panels). nil = all.
    public var isTargetAvailable: ((HotkeyTarget) -> Bool)?
    /// SO2R focus filter: when set, presses are dropped while the other radio has focus.
    public var so2rGate: SO2RGate?

    public init(backend: any HotkeyBackend, bindings: HotkeyBindings = HotkeyBindings()) {
        self.backend = backend
        self.bindings = bindings
        backend.onPress = { [weak self] key in
            MainActor.assumeIsolated { self?.handlePress(key) }
        }
        registerAll()
    }

    /// Replaces all bindings (e.g. after loading hotkeys.json).
    public func setBindings(_ b: HotkeyBindings) {
        bindings = b
        registerAll()
    }

    /// Binds a key captured by the registration sheet. Returns the evaluation outcome;
    /// only `.accept` changes the bindings. Throws if macOS cannot register the key.
    @discardableResult
    public func bind(_ key: KeyName, to target: HotkeyTarget) throws -> HotkeyRegistration.Outcome {
        let outcome = HotkeyRegistration.evaluate(key)
        guard case .accept(let k) = outcome else { return outcome }
        let previous = bindings
        bindings.bind(target, to: k)
        registerAll()
        if let e = failures[k] {
            bindings = previous
            registerAll()
            throw e
        }
        return outcome
    }

    public func unbind(_ target: HotkeyTarget) {
        bindings.unbind(target)
        registerAll()
    }

    /// "Clear hotkeys".
    public func clear() {
        bindings.clear()
        registerAll()
    }

    /// Releases every registration (e.g. while the registration sheet captures a key).
    public func suspend() {
        isSuspended = true
        backend.unregisterAll()
    }

    public func resume() {
        isSuspended = false
        registerAll()
    }

    /// Re-registers everything ("Restart Hotkeys").
    public func registerAll() {
        backend.unregisterAll()
        failures = [:]
        guard !isSuspended else { return }
        for k in bindings.keys {
            do { try backend.register(k) } catch let e as HotkeyError { failures[k] = e } catch {
                failures[k] = .registrationFailed(k.legacyString, -1)
            }
        }
    }

    /// Dispatches a press (called by the backend; public for tests and the simulator).
    public func handlePress(_ key: KeyName) {
        guard !isSuspended else { return }
        if let gate = so2rGate, !gate.accepts { return }
        for t in bindings.targets(for: key) where isTargetAvailable?(t) ?? true {
            onAction?(t, key)
        }
    }
}

/// Backend for tests and the simulator: records registrations, presses on demand.
public final class InMemoryHotkeyBackend: HotkeyBackend {
    public private(set) var registered: Set<KeyName> = []
    /// Keys whose registration fails (to test error paths).
    public var refuse: [KeyName: HotkeyError] = [:]
    public var onPress: ((KeyName) -> Void)?
    public init() {}

    public func register(_ key: KeyName) throws {
        let k = key.normalized
        if let e = refuse[k] { throw e }
        registered.insert(k)
    }
    public func unregister(_ key: KeyName) { registered.remove(key.normalized) }
    public func unregisterAll() { registered.removeAll() }

    /// Simulates the user pressing a key; only registered keys fire, like a real hotkey.
    public func press(_ key: KeyName) {
        guard registered.contains(key.normalized) else { return }
        onPress?(key.normalized)
    }
}
