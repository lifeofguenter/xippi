import XCTest

/// Adding an account against the test servers (`make up`), on an empty in-memory database.
/// The accounts connect for real; passwords stay in memory.
final class OnboardingUITests: XCTestCase {
    /// The test servers' CA from the repository, as PEM text: the sandboxed app cannot read
    /// the repository, so `-UITestCA` takes the certificate itself.
    private static var testCA: String {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "dev/certs/test-ca.pem")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(trustingTestCA: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestDatabase", "memory", "-ApplePersistenceIgnoreState", "YES",
        ]
        if trustingTestCA {
            app.launchArguments += ["-UITestCA", Self.testCA]
        }
        app.launch()
        return app
    }

    /// Fills in the add-account sheet, which opens by itself without accounts, and logs in.
    @MainActor
    private func logIn(_ app: XCUIApplication, password: String = "xippi-test") {
        let address = app.textFields["add-account-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "add-account sheet")
        address.click()
        address.typeText("alice@prosody.test")
        let secret = app.secureTextFields["add-account-password"]
        secret.click()
        secret.typeText(password)
        let server = app.textFields["add-account-server"]
        server.click()
        server.typeText("localhost")
        app.buttons["add-account-login"].click()
    }

    @MainActor
    func testAddAccountReachesOnline() {
        let app = launch(trustingTestCA: true)
        logIn(app)
        let footer = app.descendants(matching: .any)["account-status"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        XCTAssertTrue(footer.waitForValue("Online", timeout: 10), "footer: \(footer.stringValue)")
    }

    @MainActor
    func testWrongPasswordShowsLoginFailed() {
        let app = launch(trustingTestCA: true)
        logIn(app, password: "wrong")
        let error = app.staticTexts["add-account-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.stringValue, "Login failed: not authorized")
    }

    @MainActor
    func testUntrustedCertificateAsksAndCancelIsTheDefault() {
        let app = launch(trustingTestCA: false)
        logIn(app)
        let sheet = app.descendants(matching: .any)["certificate-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["certificate-host"].stringValue, "prosody.test")
        XCTAssertEqual(app.staticTexts["certificate-reason"].stringValue, "Not trusted")
        // Return takes the default button, Cancel: nothing is trusted.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["add-account-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["add-account-error"].stringValue, "Certificate not trusted")
    }

    @MainActor
    func testTrustingTheCertificateLogsIn() {
        let app = launch(trustingTestCA: false)
        logIn(app)
        let trust = app.buttons["certificate-trust"]
        XCTAssertTrue(trust.waitForExistence(timeout: 10))
        trust.click()
        let footer = app.descendants(matching: .any)["account-status"]
        XCTAssertTrue(footer.waitForValue("Online", timeout: 10), "footer: \(footer.stringValue)")
    }

    @MainActor
    func testRegisterShowsTheServersForm() {
        let app = launch(trustingTestCA: true)
        let newAccount = app.buttons["add-account-register"]
        XCTAssertTrue(newAccount.waitForExistence(timeout: 10))
        newAccount.click()
        let domain = app.textFields["register-domain"]
        domain.click()
        domain.typeText("prosody.test")
        let server = app.textFields["register-server"]
        server.click()
        server.typeText("localhost")
        app.buttons["register-continue"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["form-field:username"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["form-field:password"].exists)
    }
}
