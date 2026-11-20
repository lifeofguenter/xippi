import XCTest

/// OMEMO trust in the inspector, on the sample identities (`-UITestInspectorSamples 1`,
/// seeded data): one verified in both versions, one new and undecided, one trusted, one
/// distrusted, and one device whose key nobody has shown. The decisions on a
/// real exchange are covered by `RoomAdminIntegrationTests.trustAfterAnExchange`.
final class EncryptionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// OMEMO on for the chat; the new device is flagged in the chat; verifying asks first
    /// (Cancel the default), and once every current device is verified the contact shows
    /// "Verified" and the flag goes.
    @MainActor
    func testEnableOMEMOAndVerifyDevice() {
        let app = LiveApp.launchWithSamples()
        XCTAssertTrue(app.openChat("Alice Martin"))
        XCTAssertTrue(
            app.descendants(matching: .any)["banner-new-device"].waitForExistence(timeout: 10),
            "a verified contact's new device is flagged")
        app.buttons["banner-review"].click()

        let choice = app.radioGroups["encryption-toggle"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "inspector open")
        let on = choice.radioButtons["On"]
        on.click()
        XCTAssertTrue(on.waitForValue("1", timeout: 5), "OMEMO on")
        XCTAssertTrue(
            app.images.matching(NSPredicate(format: "label == 'Encrypted'")).firstMatch
                .waitForExistence(timeout: 5), "the composer shows the lock")

        for device in ["device-2002", "device-3003"] {
            let verify = app.descendants(matching: .any)[device].buttons["device-verify"]
            XCTAssertTrue(verify.waitForExistence(timeout: 5), device)
            verify.click()
            let dialog = app.sheets.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 5), "asked before verifying")
            XCTAssertTrue(dialog.buttons["Cancel"].exists)
            dialog.buttons["Verify"].click()
            XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        }

        // A device whose key nobody has shown can only be distrusted, and asks first.
        let keyless = app.descendants(matching: .any)["device-6006"]
        XCTAssertFalse(keyless.buttons["device-verify"].exists)
        XCTAssertFalse(keyless.buttons["device-trust"].exists)
        keyless.buttons["device-distrust"].click()
        let question = app.sheets.firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.buttons["Distrust"].click()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))

        XCTAssertTrue(
            app.descendants(matching: .any)["verified-badge"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["banner-new-device"].waitForNonExistence(timeout: 5))
    }
}
