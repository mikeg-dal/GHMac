import XCTest

/// UI tests against `-GHESimulator demo` (the shared DemoScenario: Tower 1 at 45°, Tower 2 seeded 40 m-only,
/// Tower 3, Dipole fixed at 999 → "---", Tower 1 Back, Remote Tower, Antenna Switch "Ant 1…6"/OFF, …) and, for the
/// not-responding rotor, `-GHESimulator scripted` (Tower2 reports status 5). No network, temporary settings.
final class GHEClientUITests: XCTestCase {
    @MainActor private var app = XCUIApplication()

    @MainActor private func launch(_ scenario: String = "demo") {
        continueAfterFailure = false
        app.launchArguments = ["-GHESimulator", scenario]
        app.launch()
        let a = app
        addTeardownBlock { @MainActor in a.terminate() }
    }

    @MainActor private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Picks a main-menu item (the app must be active: its panels don't activate it).
    @MainActor private func menu(_ bar: String, _ item: String) {
        app.activate()
        app.menuBars.menuBarItems[bar].click()
        app.menuBars.menuItems[item].click()
    }

    @MainActor private func headingText(_ name: String) -> String {
        let e = element("heading.\(name)")
        return e.label
    }

    @MainActor func testTrayRowsAppear() {
        launch()
        for name in ["Tower 1", "Tower 2", "Tower 3", "Dipole", "Tower 1 Back", "Remote Tower"] {
            XCTAssertTrue(element("rotorName.\(name)").waitForExistence(timeout: 15), "row \(name)")
        }
        XCTAssertTrue(waitFor { self.headingText("Dipole") == "---" }, "fixed rotor above 360 shows ---")
    }

    @MainActor func testTurnUpdatesHeading() {
        launch()
        let spinner = element("spinner.Tower 1")
        XCTAssertTrue(spinner.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor { self.headingText("Tower 1") == "045" })
        spinner.doubleClick()
        spinner.typeKey("a", modifierFlags: .command)
        spinner.typeText("90")
        element("turn.Tower 1").click()
        // The demo RT-21 turns 5°/s.
        XCTAssertTrue(waitFor(40) { self.headingText("Tower 1") == "090" }, "heading is \(headingText("Tower 1"))")
    }

    @MainActor func testStatusFiveRowIsDisabled() {
        launch("scripted")
        let turn = element("turn.Tower2")
        XCTAssertTrue(turn.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor { !turn.isEnabled })
        XCTAssertFalse(element("stop.Tower2").isEnabled)
        XCTAssertFalse(element("active.Tower2").isEnabled)
        XCTAssertTrue(element("turn.TH6").isEnabled)
    }

    @MainActor func testSwitchPositionSelectedAfterEcho() {
        launch()
        let ant3 = element("switch.Antenna Switch.Ant 3")
        XCTAssertTrue(ant3.waitForExistence(timeout: 20))
        let ant5 = element("switch.Antenna Switch.Ant 5")
        ant5.click()
        XCTAssertTrue(waitFor(15) { (ant5.value as? String) == "selected" }, "value \(String(describing: ant5.value))")
        ant3.click()
        XCTAssertTrue(waitFor(15) { (ant3.value as? String) == "selected" }, "value \(String(describing: ant3.value))")
        XCTAssertNotEqual(ant5.value as? String, "selected")
    }

    @MainActor func testManualBandHidesOffBandRowsAndAllRestores() {
        launch()
        XCTAssertTrue(element("rotorName.Tower 2").waitForExistence(timeout: 15))
        menu("Band", "20M")
        XCTAssertTrue(waitFor { !self.element("rotorName.Tower 2").exists }, "Tower 2 is 40 m only")
        XCTAssertTrue(element("rotorName.Tower 1").exists)
        menu("Band", "ALL")
        XCTAssertTrue(element("rotorName.Tower 2").waitForExistence(timeout: 5))
    }

    @MainActor func testServersWindowShowsSimulatorConnected() {
        launch()
        XCTAssertTrue(element("rotorName.Tower 1").waitForExistence(timeout: 15))
        menu("Configuration", "Servers...")
        let connect = element("serverRow.0.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { (connect.value as? String) == "Connected" }, "value \(String(describing: connect.value))")
        XCTAssertEqual(element("serverRow.0.address").value as? String, "Simulator")
    }

    @MainActor func testDraggingABeamOnTheRotorMapTurnsTheRotor() {
        launch()
        let canvas = element("rotorMap.canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor { self.headingText("Tower 1") == "045" })
        // Other apps' windows may cover the (non-activating) map panel: bring this app forward first.
        app.activate()
        let f = canvas.frame
        let r = min(f.width, f.height) / 2 * 0.7
        let center = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Grab Tower 1's wedge at bearing 45°, drop it at bearing 135°.
        let from = center.withOffset(CGVector(dx: r * sin(.pi / 4), dy: -r * cos(.pi / 4)))
        let to = center.withOffset(CGVector(dx: r * sin(3 * .pi / 4), dy: -r * cos(3 * .pi / 4)))
        from.click(forDuration: 0.3, thenDragTo: to)
        XCTAssertTrue(waitFor(45) {
            guard let h = Int(self.headingText("Tower 1")) else { return false }
            return abs(h - 135) <= 3
        }, "heading is \(headingText("Tower 1"))")
    }
}
