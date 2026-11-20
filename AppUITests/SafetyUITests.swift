import XCTest

/// Block and Report spam reachable from a chat and from a contact (spec 13, App Review
/// guideline 1.2). Each asks first, and the question's default is Cancel: Return sends
/// nothing.
final class SafetyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The sidebar's menu on a 1:1 chat offers Block and Report spam; Block asks first.
    @MainActor
    func testSidebarMenuAsksBeforeBlocking() {
        let app = XCUIApplication.seeded()
        app.launch()
        let row = app.chatRow("Alice Martin")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        XCTAssertTrue(app.menuItems["Report spam"].exists)
        app.menuItems["Block"].click()
        Self.expectCancelledQuestion(app, title: "Block Alice Martin?", action: "Block")
    }

    /// I6: a Block that fails (seeded accounts never connect) says so over the window, and the
    /// chat of the person being blocked is not opened for it.
    @MainActor
    func testFailedBlockShowsAnAlertWithoutOpeningTheChat() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let row = app.chatRow("Alice Martin")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        app.menuItems["Block"].click()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        dialog.buttons["Block"].click()

        XCTAssertTrue(
            app.label("Block failed: not connected").waitForExistence(timeout: 5),
            "the failure is shown")
        XCTAssertEqual(app.composer.placeholderValue, "Message Bob Chen", "Bob's chat stays open")
        app.buttons["Close"].click()
    }

    /// Someone else's message offers Block sender and Report spam; the report asks first.
    @MainActor
    func testMessageMenuReportsAfterAsking() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let message = app.message("I'll check `prosodyctl`")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.rightClick()
        XCTAssertTrue(app.menuItems["Block sender"].exists)
        app.menuItems["Report spam"].click()
        Self.expectCancelledQuestion(
            app, title: "Report Bob Chen as spam?", action: "Report and block")
    }

    /// A room member's actions offer Block and Report spam.
    @MainActor
    func testMemberMenuOffersBlockAndReport() {
        let app = LiveApp.launchWithSamples()
        XCTAssertTrue(app.openChat("prosody"))
        app.typeKey("i", modifierFlags: [.command, .option])
        let actions = app.descendants(matching: .any)["member-actions-dave"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "dave's actions")
        actions.click()
        XCTAssertTrue(app.menuItems["Report spam"].exists)
        app.menuItems["Block"].click()
        Self.expectCancelledQuestion(app, title: "Block dave?", action: "Block")
    }

    /// A member known only by nickname is offered "Ignore this nickname in this room", never
    /// Block (R72).
    @MainActor
    func testNickOnlyMemberIsIgnoredByNickname() {
        let app = LiveApp.launchWithSamples()
        XCTAssertTrue(app.openChat("prosody"))
        app.typeKey("i", modifierFlags: [.command, .option])
        let actions = app.descendants(matching: .any)["member-actions-erin"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "erin's actions")
        actions.click()
        XCTAssertFalse(app.menuItems["Block"].exists)
        app.menuItems["Ignore this nickname in this room"].click()
        Self.expectCancelledQuestion(
            app, title: "Ignore this nickname in this room?", action: "Ignore")
    }

    /// The question names whom, the red button names the action, and Return takes Cancel.
    @MainActor
    private static func expectCancelledQuestion(
        _ app: XCUIApplication, title: String, action: String
    ) {
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "asked first")
        XCTAssertTrue(app.label(title, in: dialog).exists)
        XCTAssertTrue(dialog.buttons[action].exists)
        XCTAssertTrue(dialog.buttons["Cancel"].exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
    }
}
