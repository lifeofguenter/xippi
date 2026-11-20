import XCTest

/// `xmpp:` links opened from outside, on seeded data (3 accounts; "Bob Chen" is
/// bob@example.com on the second account only).
final class URIUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.waitForSeed(), "seeded data")
        return app
    }

    /// A message link opens the chat its one account has, with the text in the composer and
    /// nothing sent.
    @MainActor
    func testOpeningURIOpensChat() throws {
        let app = try launch()
        let url = try XCTUnwrap(URL(string: "xmpp:bob@example.com?message;body=Hello%20Bob"))
        app.open(url)
        XCTAssertTrue(
            app.wait(for: app.composer, placeholder: "Message Bob Chen", timeout: 10),
            "chat opened")
        XCTAssertTrue(
            app.composer.waitForValue("Hello Bob"), "composer: \(app.composer.stringValue)")
        XCTAssertFalse(app.message("Hello Bob").exists, "sent without asking")
    }

    /// A join link never joins by itself: the sheet asks, with the room filled in and the
    /// account to choose.
    @MainActor
    func testJoinURIAsksFirst() throws {
        let app = try launch()
        let url = try XCTUnwrap(URL(string: "xmpp:newroom@conference.example.org?join"))
        app.open(url)
        let sheet = app.descendants(matching: .any)["link-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "join sheet")
        XCTAssertTrue(app.label("newroom@conference.example.org").exists)
        XCTAssertTrue(app.popUpButtons["link-account"].exists, "account choice")
        XCTAssertFalse(app.chatRow("newroom").exists, "joined without asking")
        app.buttons["link-cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 2), "sheet closed")
        XCTAssertFalse(app.chatRow("newroom").exists)
    }

    /// A link that would remove a contact does nothing.
    @MainActor
    func testRemoveURIIsIgnored() throws {
        let app = try launch()
        let url = try XCTUnwrap(URL(string: "xmpp:bob@example.com?remove"))
        app.open(url)
        XCTAssertFalse(
            app.descendants(matching: .any)["link-sheet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.chatRow("Bob Chen").exists)
    }
}
