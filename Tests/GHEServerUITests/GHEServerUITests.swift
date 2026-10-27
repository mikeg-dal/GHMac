import XCTest

/// UI tests against `-GHESimulator demo` (in-memory devices and listener; no ports are opened).
@MainActor
final class GHEServerUITests: XCTestCase {
    private var app = XCUIApplication()

    private func launch() {
        continueAfterFailure = false
        app.launchArguments = ["-GHESimulator", "demo", "-GHENoQuitConfirm", "YES"]
        app.launch()
        XCTAssertTrue(app.textViews["serverLog"].waitForExistence(timeout: 15))
    }

    override func tearDown() async throws {
        await MainActor.run { app.terminate() }
    }

    // MARK: Helpers

    private func menu(_ menu: String, _ items: String...) {
        app.menuBars.menuBarItems[menu].click()
        for item in items { app.menuBars.menuItems[item].firstMatch.click() }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// macOS puts a Text's string in `value`.
    private func text(_ id: String) -> String {
        let e = app.staticTexts[id]
        return (e.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? e.label
    }

    private var logText: String { app.textViews["serverLog"].value as? String ?? "" }

    private func openDeviceManager() {
        menu("Server", "Device Manager…")
        XCTAssertTrue(app.buttons["deviceStatus.0"].waitForExistence(timeout: 10))
    }

    private func status(_ row: Int) -> String { app.buttons["deviceStatus.\(row)"].label }

    // MARK: Tests

    func testMainWindowShowsServerStartedAndAConnection() {
        launch()
        waitUntil("Server started.") { logText.contains("Server started.") }
        waitUntil("connection count") { text("statusConnections") == "1/4" }
        XCTAssertEqual(app.images["serverStatus"].label, "Server Running")
    }

    func testStopAndStartToggleTheStatus() {
        launch()
        waitUntil("running") { app.images["serverStatus"].label == "Server Running" }
        menu("Server", "Stop Server")
        waitUntil("stopped") { app.images["serverStatus"].label == "Server stopped" }
        waitUntil("Server stopped.") { logText.contains("Server stopped.") }
        waitUntil("no connections") { text("statusConnections") == "0/4" }
        menu("Server", "Start Server…")
        waitUntil("running again") { app.images["serverStatus"].label == "Server Running" }
        waitUntil("connection count") { text("statusConnections") == "1/4" }
    }

    func testDeviceManagerListsDemoRowsConnectedAndTogglesARow() {
        launch()
        openDeviceManager()
        for row in [0, 1, 3, 4, 5, 9, 10, 11] {
            waitUntil("row \(row) connected", timeout: 20) { status(row) == "Connected" }
        }
        XCTAssertEqual(status(20), "Disconnected")
        app.buttons["deviceStatus.1"].click()
        waitUntil("row 1 disconnected") { status(1) == "Disconnected" }
        app.buttons["deviceStatus.1"].click()
        waitUntil("row 1 connected again") { status(1) == "Connected" }
    }

    func testFixedAntennaPromptAccepts999() {
        launch()
        openDeviceManager()
        waitUntil("fixed connected") { status(3) == "Connected" }
        app.buttons["deviceStatus.3"].click()
        waitUntil("fixed disconnected") { status(3) == "Disconnected" }
        app.buttons["deviceStatus.3"].click()
        let field = app.textFields["devicePromptField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("999")
        app.buttons["devicePromptOK"].click()
        waitUntil("fixed connected at 999") { status(3) == "Connected" }
    }

    func testWioEditorOpensEditsAndSaves() {
        launch()
        openDeviceManager()
        menu("Edit", "WIO Profile Editor…")
        let editor = app.windows["wioEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let open = editor.menuButtons["Open Profile"]
        if !open.waitForExistence(timeout: 3) { print(editor.debugDescription) }
        open.click()
        app.menuItems["Demo 6-Way"].firstMatch.click()
        let name = editor.textFields["wioName.0"]
        waitUntil("profile loaded") { (name.value as? String) == "Ant 1" }
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Ant One")
        if !editor.staticTexts["wioDirty"].waitForExistence(timeout: 5) { print("DUMP>>", name.value ?? "nil", editor.debugDescription) }
        XCTAssertTrue(editor.staticTexts["wioDirty"].exists)
        editor.buttons["wioSave"].click()
        XCTAssertTrue(editor.staticTexts["wioSaved"].waitForExistence(timeout: 5))
    }

    func testCreateMasterPasswordThenAddUser() {
        launch()
        menu("Server", "Users/Passwords", "Users…")
        let pw = app.secureTextFields["newPasswordField"]
        XCTAssertTrue(pw.waitForExistence(timeout: 5))
        pw.click(); pw.typeText("secret1")
        let confirm = app.secureTextFields["confirmPasswordField"]
        confirm.click(); confirm.typeText("secret1")
        app.buttons["newPasswordOK"].click()
        XCTAssertTrue(app.buttons["addUser"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["removeUser"].isEnabled)
        app.buttons["addUser"].click()
        let user = app.textFields["userNameField"]
        XCTAssertTrue(user.waitForExistence(timeout: 5))
        user.click(); user.typeText("alice")
        let p1 = app.secureTextFields["userPasswordField"]
        p1.click(); p1.typeText("hunter22")
        let p2 = app.secureTextFields["userConfirmField"]
        p2.click(); p2.typeText("hunter22")
        app.buttons["userOK"].click()
        XCTAssertTrue(app.staticTexts["user.alice"].waitForExistence(timeout: 5))
        app.buttons["userManagerOK"].click()
        // Reopen: now the master password is asked for, and alice was saved.
        menu("Server", "Users/Passwords", "Users…")
        let gate = app.secureTextFields["masterPasswordField"]
        XCTAssertTrue(gate.waitForExistence(timeout: 5))
        gate.click(); gate.typeText("secret1")
        app.buttons["masterPasswordOK"].click()
        XCTAssertTrue(app.staticTexts["user.alice"].waitForExistence(timeout: 5))
    }
}
