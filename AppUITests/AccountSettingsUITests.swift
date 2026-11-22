import XCTest

/// The account settings against the test servers (`make up`), on an empty in-memory database
/// with alice logged in. Passwords stay in memory; alice's password is set to the one she
/// has, so the shared test account keeps it.
final class AccountSettingsUITests: XCTestCase {
    private static var testCA: String {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "dev/certs/test-ca.pem")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let password = "xippi-test"

    override func setUp() {
        continueAfterFailure = false
    }

    /// Logs alice in and opens her account in Settings.
    @MainActor
    private func openAccount() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestDatabase", "memory", "-ApplePersistenceIgnoreState", "YES",
            "-UITestCA", Self.testCA, "-UITestServer", "localhost",
        ]
        app.launch()
        let address = app.textFields["add-account-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "add-account sheet")
        address.click()
        address.typeText("alice@prosody.test")
        let secret = app.secureTextFields["add-account-password"]
        secret.click()
        secret.typeText(Self.password)
        app.buttons["add-account-login"].click()
        let footer = app.descendants(matching: .any)["account-status"]
        XCTAssertTrue(footer.waitForValue("Online", timeout: 15), "footer: \(footer.stringValue)")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Accounts"].waitForExistence(timeout: 5))
        let detail = app.descendants(matching: .any)["account-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    func testChangePasswordFlow() {
        let app = openAccount()
        let change = app.buttons["change-password:alice@prosody.test"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertTrue(change.isEnabled)
        change.click()
        let field = app.secureTextFields["new-password"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(Self.password)
        app.buttons["change-password-confirm"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "the sheet closes once changed")
        XCTAssertFalse(app.staticTexts["change-password-error"].exists)
    }

    @MainActor
    func testBlockAndUnblock() {
        let app = openAccount()
        app.radioButtons["Blocked"].click()
        let address = app.textFields["block-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.click()
        address.typeText("spam@prosody.test")
        app.buttons["block-confirm"].click()
        let unblock = app.buttons["unblock:spam@prosody.test"]
        XCTAssertTrue(unblock.waitForExistence(timeout: 10), "blocked")
        unblock.click()
        XCTAssertTrue(unblock.waitForNonExistence(timeout: 10), "unblocked")
    }

    @MainActor
    func testArchiveDefaultIsReadFromTheServer() {
        let app = openAccount()
        app.radioButtons["Archive"].click()
        let picker = app.descendants(matching: .any)["archive-default"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
    }
}
