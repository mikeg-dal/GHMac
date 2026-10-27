import Foundation
import GHEKit

/// Name ↔ serial mapping (`phidgets.xml`).
public protocol PhidgetMapping: Sendable {
    func name(forSerial serial: Int) async -> String?
    /// nil removes the mapping ("None").
    func setName(_ name: String?, forSerial serial: Int) async
}

/// In-memory mapping for tests and the simulator.
public actor InMemoryPhidgetMapping: PhidgetMapping {
    public private(set) var names: [Int: String]
    public private(set) var saveCount = 0
    public init(_ names: [Int: String] = [:]) { self.names = names }
    public func name(forSerial serial: Int) -> String? { names[serial] }
    public func setName(_ name: String?, forSerial serial: Int) {
        names[serial] = name; saveCount += 1
    }
}

/// One knob action addressed to the knob that produced it.
public struct KnobOutput: Sendable, Equatable {
    public var serial: Int
    public var action: KnobAction
    public init(serial: Int, action: KnobAction) { self.serial = serial; self.action = action }
}

/// Runs a `KnobLogic` per knob, owns the 1.5 s long-press timer, and saves registrations.
public actor KnobController {
    public static let noneChoice = "None"
    public static let cancelChoice = "Cancel"

    private let clock: any GHEClock
    private let mapping: any PhidgetMapping
    private let options: KnobOptions
    /// Registration list (visible rotors, their preset windows, visible switches); the
    /// controller appends "None" and "Cancel".
    private let choicesProvider: @Sendable () async -> [String]
    private var knobs: [Int: KnobLogic] = [:]
    private var choices: [Int: [String]] = [:]
    private var pressGeneration: [Int: Int] = [:]
    private let broadcaster = EventBroadcaster<KnobOutput>()

    public init(clock: any GHEClock = SystemClock(), mapping: any PhidgetMapping, options: KnobOptions = KnobOptions(),
                choices: @escaping @Sendable () async -> [String]) {
        self.clock = clock; self.mapping = mapping; self.options = options; self.choicesProvider = choices
    }

    public nonisolated func outputs() -> AsyncStream<KnobOutput> { broadcaster.subscribe() }

    public func logic(for serial: Int) -> KnobLogic? { knobs[serial] }

    public func setTarget(_ kind: KnobTargetKind, forSerial serial: Int) {
        knobs[serial, default: KnobLogic(options: options)].retarget(kind)
    }

    /// Feeds one hardware event. `currentSpinner` is the bound rotor's spinner value, if any.
    public func handle(_ event: KnobEvent, currentSpinner: Int? = nil) async {
        switch event {
        case .attached(let s):
            if knobs[s] == nil { knobs[s] = KnobLogic(options: options) }
        case .detached(let s):
            pressGeneration[s, default: 0] += 1
        case .delta(let s, let d):
            var k = knobs[s] ?? KnobLogic(options: options)
            let actions = k.turn(d, currentSpinner: currentSpinner)
            knobs[s] = k
            emit(s, actions)
        case .button(let s, true):
            var k = knobs[s] ?? KnobLogic(options: options)
            emit(s, k.press())
            knobs[s] = k
            pressGeneration[s, default: 0] += 1
            let gen = pressGeneration[s]!
            Task { await self.longPressTimer(serial: s, generation: gen) }
        case .button(let s, false):
            pressGeneration[s, default: 0] += 1
            guard var k = knobs[s] else { return }
            let actions = k.release()
            knobs[s] = k
            for a in actions {
                if case .commitRegistration(let i) = a { await commit(serial: s, index: i) }
            }
            emit(s, actions)
        }
    }

    /// Consumes a knob service until its stream ends.
    public func run(_ service: any KnobService) async {
        for await e in service.events() { await handle(e) }
    }

    private func longPressTimer(serial s: Int, generation: Int) async {
        do { try await clock.sleep(for: Timing.phidgetLongPress) } catch { return }
        guard pressGeneration[s] == generation, var k = knobs[s], k.mode == .pressed else { return }
        let list = await choicesProvider() + [Self.noneChoice, Self.cancelChoice]
        guard pressGeneration[s] == generation else { return }
        choices[s] = list
        let current = await mapping.name(forSerial: s).flatMap { list.firstIndex(of: $0) } ?? 0
        let actions = k.longPress(choiceCount: list.count, currentIndex: current)
        knobs[s] = k
        emit(s, actions)
    }

    private func commit(serial s: Int, index: Int) async {
        guard let list = choices[s], list.indices.contains(index) else { return }
        let choice = list[index]
        if choice == Self.cancelChoice { return }
        await mapping.setName(choice == Self.noneChoice ? nil : choice, forSerial: s)
    }

    /// The choice list of the last registration for a knob.
    public func registrationChoices(for serial: Int) -> [String]? { choices[serial] }

    private func emit(_ serial: Int, _ actions: [KnobAction]) {
        for a in actions { broadcaster.yield(KnobOutput(serial: serial, action: a)) }
    }
}
