import XCTest

final class SettingsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openSettings() -> XCUIApplication {
        let app = XCUIApplication.seeded(messages: 10)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Accounts"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testCommandCommaOpensSettings() {
        let app = openSettings()
        XCTAssertTrue(app.descendants(matching: .any)["settings-accounts"].exists)
    }

    @MainActor
    func testSwitchingTabs() {
        let app = openSettings()
        for (tab, identifier) in [
            ("General", "settings-general"),
            ("Notifications", "settings-notifications"),
            ("Appearance", "settings-appearance"),
            ("Privacy & Media", "settings-privacy"),
            ("Calls", "settings-calls"),
            ("Advanced", "settings-advanced"),
            ("Accounts", "settings-accounts"),
        ] {
            app.toolbars.buttons[tab].click()
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
                "\(tab) tab")
        }
    }

    @MainActor
    func testAddingAKeyword() {
        let app = openSettings()
        app.toolbars.buttons["Notifications"].click()
        let field = app.textFields["keyword-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("deploy\r")
        XCTAssertTrue(app.staticTexts["deploy"].waitForExistence(timeout: 5))
    }
}
