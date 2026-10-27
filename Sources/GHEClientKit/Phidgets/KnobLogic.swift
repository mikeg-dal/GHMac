import Foundation

/// What a knob is bound to.
public enum KnobTargetKind: Sendable, Equatable {
    case none
    /// A rotor: turning sets the turn-to spinner; a click turns.
    case rotor
    /// A switch panel: one position per count; a click selects the first position.
    case switchPanel
    /// A preset window with `count` visible buttons.
    case presets(count: Int)
}

/// Knob behaviour options.
public struct KnobOptions: Sendable, Equatable {
    /// Counts per degree on rotor targets.
    public var countsPerDegree: Int
    /// Reverse the turning direction.
    public var inverted: Bool
    /// A click on a switch target selects its first ("home") position.
    public var switchClickSelectsFirst: Bool
    public init(countsPerDegree: Int = 1, inverted: Bool = false, switchClickSelectsFirst: Bool = true) {
        self.countsPerDegree = max(1, countsPerDegree); self.inverted = inverted
        self.switchClickSelectsFirst = switchClickSelectsFirst
    }
}

/// What the host should do in response to knob input.
public enum KnobAction: Sendable, Equatable {
    case setSpinner(Int)
    /// Move a switch by this many positions (wrapping).
    case movePosition(Int)
    case highlightPreset(Int)
    case executeTurn
    case selectFirstPosition
    /// Click the highlighted preset (or show the preset window if hidden).
    case clickPreset(Int)
    /// Long press: show the registration list (`count` choices, `index` selected).
    case beginRegistration(count: Int, index: Int)
    case registrationIndex(Int)
    /// Release during registration: choose `choices[index]`.
    case commitRegistration(index: Int)
}

/// Pure knob state machine.
public struct KnobLogic: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case idle, pressed, registering(count: Int, index: Int) }

    public var target: KnobTargetKind
    public var options: KnobOptions
    public private(set) var mode: Mode = .idle
    /// Raw counts since attach (presets use the absolute heading from this).
    public private(set) var counter = 0
    /// Rotor value last set by the knob, used when the host does not know the spinner.
    public private(set) var lastSpinner: Int?
    /// Counts not yet worth a whole degree.
    private var remainder = 0

    public init(target: KnobTargetKind = .none, options: KnobOptions = KnobOptions()) {
        self.target = target; self.options = options
    }

    /// Rebinding resets the rotor seed.
    public mutating func retarget(_ t: KnobTargetKind) {
        target = t; lastSpinner = nil; remainder = 0
    }

    /// Absolute heading: `(36_000_000 − counter) mod 360`.
    public var legacyHeading: Int { Self.mod(-counter, 360) }

    /// An encoder position change of `rawDelta` counts. `currentSpinner` is the rotor's
    /// current turn-to value, if known.
    public mutating func turn(_ rawDelta: Int, currentSpinner: Int? = nil) -> [KnobAction] {
        let d = options.inverted ? -rawDelta : rawDelta
        counter += d
        if case .registering(let n, let i) = mode {
            let next = Self.mod(i - d, max(n, 1))
            mode = .registering(count: n, index: next)
            return [.registrationIndex(next)]
        }
        switch target {
        case .none:
            return []
        case .rotor:
            // Relative to the current value instead of an absolute counter from attach.
            remainder += d
            let degrees = remainder / options.countsPerDegree
            remainder -= degrees * options.countsPerDegree
            guard degrees != 0 else { return [] }
            let base = currentSpinner ?? lastSpinner ?? 0
            let v = Self.mod(base - degrees, 360)   // positive counts decrease
            lastSpinner = v
            return [.setSpinner(v)]
        case .switchPanel:
            return [.movePosition(-d)]
        case .presets(let n):
            return n > 0 ? [.highlightPreset(legacyHeading % n)] : []
        }
    }

    /// Button pressed. The host starts the 1.5 s long-press timer.
    public mutating func press() -> [KnobAction] {
        if mode == .idle { mode = .pressed }
        return []
    }

    /// The long-press timer fired while still pressed: enter registration.
    public mutating func longPress(choiceCount: Int, currentIndex: Int = 0) -> [KnobAction] {
        guard mode == .pressed else { return [] }
        let i = choiceCount > 0 ? Self.mod(currentIndex, choiceCount) : 0
        mode = .registering(count: choiceCount, index: i)
        return [.beginRegistration(count: choiceCount, index: i)]
    }

    /// Button released: commit a registration or perform the click.
    public mutating func release() -> [KnobAction] {
        switch mode {
        case .idle:
            return []
        case .registering(_, let i):
            mode = .idle
            return [.commitRegistration(index: i)]
        case .pressed:
            mode = .idle
            switch target {
            case .none: return []
            case .rotor: return [.executeTurn]
            case .switchPanel: return options.switchClickSelectsFirst ? [.selectFirstPosition] : []
            case .presets(let n): return [.clickPreset(n > 0 ? legacyHeading % n : 0)]
            }
        }
    }

    static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}

/// Switch stepping with wrap (`movePosition`).
public enum SwitchStepper {
    public static func step(current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return KnobLogic.mod(current + delta, count)
    }
}
