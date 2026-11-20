import XCTest

/// The call UI against the app's fake call manager (`-UITestCall`), which plays Alice Martin.
final class CallUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func launch(call scenario: String) -> XCUIApplication {
        let app = XCUIApplication.seeded(messages: 10)
        app.launchArguments += ["-UITestCall", scenario]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testIncomingCallShowsThePanel() {
        let app = launch(call: "incoming-video")
        XCTAssertTrue(app.incomingCallPanel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.label("Alice Martin", in: app.incomingCallPanel).exists)
        XCTAssertTrue(app.label("Incoming video call", in: app.incomingCallPanel).exists)
        XCTAssertTrue(app.buttons["call-accept"].exists)
        XCTAssertTrue(app.buttons["call-accept-video"].exists)
        XCTAssertTrue(app.buttons["call-decline"].exists)
    }

    @MainActor
    func testIncomingAudioCallOffersNoVideo() {
        let app = launch(call: "incoming-audio")
        XCTAssertTrue(app.incomingCallPanel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.label("Incoming audio call", in: app.incomingCallPanel).exists)
        XCTAssertFalse(app.buttons["call-accept-video"].exists)
    }

    @MainActor
    func testAcceptOpensTheCallWindow() {
        let app = launch(call: "incoming-video")
        XCTAssertTrue(app.buttons["call-accept-video"].waitForExistence(timeout: 10))
        app.buttons["call-accept-video"].click()
        XCTAssertTrue(app.callWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.incomingCallPanel.waitForNonExistence(timeout: 5))
        for control in ["call-mute", "call-video", "call-screen-share", "call-devices"] {
            XCTAssertTrue(app.buttons[control].exists, control)
        }
        XCTAssertTrue(app.buttons["call-hang-up"].exists)
    }

    @MainActor
    func testDeclineClosesThePanel() {
        let app = launch(call: "incoming-audio")
        XCTAssertTrue(app.buttons["call-decline"].waitForExistence(timeout: 10))
        app.buttons["call-decline"].click()
        XCTAssertTrue(app.incomingCallPanel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.callWindow.exists)
    }

    @MainActor
    func testHangUpClosesTheWindow() {
        let app = launch(call: "incoming-audio")
        XCTAssertTrue(app.buttons["call-accept"].waitForExistence(timeout: 10))
        app.buttons["call-accept"].click()
        XCTAssertTrue(app.callWindow.waitForExistence(timeout: 10))
        app.buttons["call-hang-up"].click()
        XCTAssertTrue(app.callWindow.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testMuteShortcutTogglesTheLabel() {
        let app = launch(call: "outgoing-audio")
        XCTAssertTrue(app.callWindow.waitForExistence(timeout: 10))
        let mute = app.buttons["call-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        XCTAssertEqual(mute.label, "Mute")
        app.typeKey("d", modifierFlags: .command)
        let unmute = NSPredicate(format: "label == 'Unmute'")
        let expectation = XCTNSPredicateExpectation(predicate: unmute, object: mute)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}

extension CallUITests {
    @MainActor
    func testDeniedMicrophoneOnStartShowsThePrivacyButton() {
        let app = launch(call: "outgoing-denied")
        XCTAssertTrue(app.callWindow.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.label("Call failed: no microphone access", in: app.callWindow).waitForExistence(
                timeout: 5))
        XCTAssertTrue(app.buttons["call-privacy-settings"].exists)
        XCTAssertFalse(app.buttons["call-hang-up"].exists, "no controls on a call that never ran")
    }
}

extension XCUIApplication {
    var incomingCallPanel: XCUIElement { descendants(matching: .any)["incoming-call"] }
    var callWindow: XCUIElement { descendants(matching: .any)["call-window"] }
}
