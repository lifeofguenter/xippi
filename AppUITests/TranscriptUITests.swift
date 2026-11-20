import XCTest

/// Sending, editing and replying through `StoreOnlyCommands`, on seeded data.
final class TranscriptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSendAppearsAtBottom() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))

        app.composer.click()
        app.composer.typeText("Hello from the test\r")

        let sent = app.message("Hello from the test")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertTrue(app.composer.waitForValue(""))
        let lowest = app.messages.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        XCTAssertEqual(sent.frame.maxY, lowest, accuracy: 1, "The pending message is the newest")
        XCTAssertTrue(app.message(saying: "Hello from the test, Sending").exists)
    }

    @MainActor
    func testUpArrowEditsLastMessage() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        app.composer.click()
        app.composer.typeText("First version\r")
        XCTAssertTrue(app.message("First version").waitForExistence(timeout: 5))

        app.composer.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(app.composer.waitForValue("First version"))
        app.composer.typeKey("a", modifierFlags: .command)
        app.composer.typeText("Second version\r")

        XCTAssertTrue(app.message("Second version").waitForExistence(timeout: 5))
        XCTAssertTrue(app.message("First version").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.message(saying: "Second version, edited · Sending").exists)
    }

    @MainActor
    func testReplyShowsQuote() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))

        let original = app.message("I'll check `prosodyctl`")
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.rightClick()
        app.menuItems["Reply"].click()

        let context = app.descendants(matching: .any)["composer-context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertTrue(app.label("Reply to Bob Chen", in: context).exists)

        app.composer.typeText("On it\r")
        XCTAssertTrue(app.message("On it").waitForExistence(timeout: 5))
        XCTAssertTrue(context.waitForNonExistence(timeout: 5))
        let reply = app.message(
            saying: "Reply to Bob Chen, I'll check `prosodyctl`, On it")
        XCTAssertTrue(reply.waitForExistence(timeout: 5), "The reply shows the quoted text")
    }

    /// Clicking a downloaded attachment opens it in Quick Look.
    @MainActor
    func testAttachmentOpensQuickLook() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Alice Martin"))
        let attachment = app.transcript.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'release-notes.txt'")).firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        attachment.click()
        let preview = app.windows.matching(NSPredicate(format: "title CONTAINS 'release-notes'"))
            .firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Quick Look shows the file")
        XCTAssertTrue(app.message(saying: "removed").exists)
    }

    /// "Remove for everyone" on our own message asks first, then the message shows as removed.
    @MainActor
    func testRemoveOwnMessageForEveryone() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        app.composer.click()
        app.composer.typeText("Wrong chat\r")
        let sent = app.message("Wrong chat")
        XCTAssertTrue(sent.waitForExistence(timeout: 5))

        sent.rightClick()
        app.menuItems["Remove for everyone"].click()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "asked first")
        remove.click()

        XCTAssertTrue(sent.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.message(saying: "removed").exists)
    }

    /// VoiceOver reads a message once: the message is one element, with its menu items as its
    /// actions, and the text inside is not an element of its own (I9).
    @MainActor
    func testMessageTextIsReadOnce() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let message = app.message("I'll check `prosodyctl`")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // The text is read once, by the message itself.
        XCTAssertEqual(
            message.textViews.count, 0, "the text view inside is not read a second time")
    }
}
