import Testing
import Foundation
import GHEKit
@testable import GHEClientKit

@Suite struct KnobLogicTests {
    /// Relative to the current spinner.
    @Test func tvP1P2() {
        var k = KnobLogic(target: .rotor)
        #expect(k.turn(-45, currentSpinner: 0) == [.setSpinner(45)])
        #expect(k.turn(90, currentSpinner: 45) == [.setSpinner(315)])
    }

    @Test func relativeSeed() {
        var k = KnobLogic(target: .rotor)
        #expect(k.turn(-10, currentSpinner: 200) == [.setSpinner(210)])
        #expect(k.turn(5) == [.setSpinner(205)])   // host doesn't know: continue from last value
        var inv = KnobLogic(target: .rotor, options: KnobOptions(countsPerDegree: 4, inverted: true))
        #expect(inv.turn(2, currentSpinner: 0) == [])
        #expect(inv.turn(2, currentSpinner: 0) == [.setSpinner(1)])
    }

    /// Short click on a rotor target turns.
    @Test func tvP3() {
        var k = KnobLogic(target: .rotor)
        #expect(k.press() == [])
        #expect(k.release() == [.executeTurn])
        #expect(k.release() == [])   // release without press
    }

    /// Delta +3 on a 5-position switch at #1 → movePosition(-3) → #3.
    @Test func tvP5() {
        var k = KnobLogic(target: .switchPanel)
        #expect(k.turn(3) == [.movePosition(-3)])
        #expect(SwitchStepper.step(current: 1, by: -3, count: 5) == 3)
        #expect(SwitchStepper.step(current: 4, by: 1, count: 5) == 0)
    }

    @Test func presetsAndSwitchClick() {
        var p = KnobLogic(target: .presets(count: 4))
        #expect(p.turn(-5) == [.highlightPreset(1)])   // heading 5 % 4
        _ = p.press()
        #expect(p.release() == [.clickPreset(1)])
        var s = KnobLogic(target: .switchPanel)
        _ = s.press(); #expect(s.release() == [.selectFirstPosition])
        var s2 = KnobLogic(target: .switchPanel, options: KnobOptions(switchClickSelectsFirst: false))
        _ = s2.press(); #expect(s2.release() == [])
    }

    @Test func registrationFlow() {
        var k = KnobLogic(target: .rotor)
        _ = k.press()
        #expect(k.longPress(choiceCount: 5, currentIndex: 0) == [.beginRegistration(count: 5, index: 0)])
        #expect(k.turn(-2) == [.registrationIndex(2)])
        #expect(k.turn(3) == [.registrationIndex(4)])   // wraps: 2-3 = -1 → 4
        #expect(k.release() == [.commitRegistration(index: 4)])
        #expect(k.mode == .idle)
    }
}

@Suite struct KnobControllerTests {
    /// Press, hold 1.6 s, turn to index 2, release → target = choices[2], mapping saved.
    @Test func tvP4() async {
        let clock = ManualClock()
        let mapping = InMemoryPhidgetMapping()
        let c = KnobController(clock: clock, mapping: mapping, choices: { ["Tribander", "Tribander Presets", "Ant Switch"] })
        let sink = AutomationEventSink(c.outputs())
        await c.handle(.attached(serial: 42))
        await c.setTarget(.rotor, forSerial: 42)
        await c.handle(.button(serial: 42, pressed: true))
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .milliseconds(1600))
        #expect(await eventually { sink.events.contains(KnobOutput(serial: 42, action: .beginRegistration(count: 5, index: 0))) })
        await c.handle(.delta(serial: 42, -2))
        await c.handle(.button(serial: 42, pressed: false))
        #expect(await mapping.names[42] == "Ant Switch")
        #expect(await mapping.saveCount == 1)
        #expect(await eventually { sink.events.contains(KnobOutput(serial: 42, action: .commitRegistration(index: 2))) })
    }

    /// Short press: the long-press timer is cancelled; release before 1.5 s is a click.
    @Test func shortPressIsClick() async {
        let clock = ManualClock()
        let mapping = InMemoryPhidgetMapping()
        let c = KnobController(clock: clock, mapping: mapping, choices: { ["X"] })
        let sink = AutomationEventSink(c.outputs())
        await c.setTarget(.rotor, forSerial: 1)
        await c.handle(.button(serial: 1, pressed: true))
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .milliseconds(300))
        await c.handle(.button(serial: 1, pressed: false))
        await clock.advance(by: .seconds(2))
        #expect(await eventually { sink.events.contains(KnobOutput(serial: 1, action: .executeTurn)) })
        #expect(!sink.events.contains { if case .beginRegistration = $0.action { true } else { false } })
        #expect(await mapping.saveCount == 0)
    }

    @Test func cancelChoiceSavesNothing() async {
        let clock = ManualClock()
        let mapping = InMemoryPhidgetMapping([7: "Old"])
        let c = KnobController(clock: clock, mapping: mapping, choices: { ["Old"] })
        let sink = AutomationEventSink(c.outputs())
        await c.handle(.button(serial: 7, pressed: true))
        #expect(await eventually { clock.sleeperCount == 1 })
        await clock.advance(by: .milliseconds(1500))
        // Starts on the current mapping ("Old" = 0); choices are Old, None, Cancel.
        #expect(await eventually { sink.events.contains(KnobOutput(serial: 7, action: .beginRegistration(count: 3, index: 0))) })
        await c.handle(.delta(serial: 7, -2))
        await c.handle(.button(serial: 7, pressed: false))
        #expect(await mapping.saveCount == 0)
        #expect(await mapping.names[7] == "Old")
    }
}

@Suite struct Phidget22LoaderTests {
    /// Reports availability without crashing; no physical knob needed.
    @Test func availabilityReported() {
        let installed = FileManager.default.fileExists(atPath: Phidget22Loader.binaryPath)
        switch Phidget22Loader.shared {
        case .success: #expect(installed)
        case .failure(let e):
            // On this Mac Phidget22 is installed and validly signed, so it must load.
            #expect(!installed, "Phidget22 installed but not loaded: \(e)")
            if !installed { #expect(e == .notInstalled) }
        }
        let service = PhidgetKnobService()
        #expect(service.isAvailable == Phidget22Loader.isAvailable)
    }

    @Test func missingFrameworkIsUnavailable() {
        let r = Phidget22Loader.load(frameworkPath: "/nonexistent/X.framework", binaryPath: "/nonexistent/X.framework/X")
        if case .failure(let e) = r { #expect(e == .notInstalled) } else { Issue.record("loaded a missing framework") }
        let s = PhidgetKnobService(api: nil)
        #expect(!s.isAvailable)
        s.start(); s.stop()   // no-ops
    }

    @Test func wrongSignerIsRefused() {
        guard FileManager.default.fileExists(atPath: Phidget22Loader.binaryPath) else { return }
        #expect(Phidget22Loader.signatureProblem(path: Phidget22Loader.frameworkPath,
                                                 requirement: Phidget22Loader.requirement) == nil)
        let bad = #"anchor apple generic and certificate leaf[subject.OU] = "AAAAAAAAAA""#
        #expect(Phidget22Loader.signatureProblem(path: Phidget22Loader.frameworkPath, requirement: bad) != nil)
        if case .failure(let e) = Phidget22Loader.load(requirement: bad) {
            if case .invalidSignature = e {} else { Issue.record("expected invalidSignature, got \(e)") }
        } else { Issue.record("expected refusal") }
    }
}

