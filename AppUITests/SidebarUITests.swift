import XCTest

/// The sidebar, the quick switcher and the filters, on seeded data: pinned chats are "prosody",
/// "Bob Chen" and "xsf"; "Alice Martin" is read.
final class SidebarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPinnedChatsFirst() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.chatRow("prosody").waitForExistence(timeout: 20))

        let rows = app.chatRows.allElementsBoundByIndex.map(\.identifier)
        XCTAssertGreaterThan(rows.count, 9)
        XCTAssertEqual(
            Set(rows.prefix(3)), ["chat:prosody", "chat:Bob Chen", "chat:xsf"],
            "Pinned chats come first, got \(rows.prefix(5))")
        // Then by last activity, newest first, as seeded.
        XCTAssertEqual(
            Array(rows.dropFirst(3).prefix(6)),
            [
                "chat:Alice Martin", "chat:Carol Diaz", "chat:ejabberd", "chat:Dave Okafor",
                "chat:Erin Novak", "chat:swift",
            ])
    }

    @MainActor
    func testUnreadFilterShowsOnlyUnread() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.chatRow("Alice Martin").waitForExistence(timeout: 20))
        XCTAssertTrue(app.waitForSeed())

        let unread = app.buttons["filter-unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5))
        unread.click()

        XCTAssertTrue(app.chatRow("Alice Martin").waitForNonExistence(timeout: 5))
        let rows = app.chatRows.allElementsBoundByIndex
        XCTAssertEqual(
            Set(rows.map(\.identifier)),
            [
                "chat:prosody", "chat:Carol Diaz", "chat:Frank Weber", "chat:Jonas Berg",
                "chat:ejabberd", "chat:operators", "chat:dino",
            ])
        for row in rows {
            XCTAssertTrue(
                row.stringValue.contains("unread"),
                "\(row.identifier) is listed without unread messages: \(row.stringValue)")
        }
    }

    /// The open chat stays listed when reading it takes it out of the Unread filter.
    @MainActor
    func testOpenChatStaysUnderTheUnreadFilter() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.buttons["filter-unread"].waitForExistence(timeout: 20))
        app.buttons["filter-unread"].click()
        XCTAssertTrue(app.openChat("Carol Diaz"))
        // Reading it clears its unread count; it stays in the list while it is open.
        let read = NSPredicate(format: "NOT (value CONTAINS 'unread')")
        let expectation = XCTNSPredicateExpectation(
            predicate: read, object: app.chatRow("Carol Diaz"))
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(app.chatRow("Carol Diaz").exists)
        XCTAssertTrue(app.wait(for: app.composer, placeholder: "Message Carol Diaz", timeout: 2))
    }

    @MainActor
    func testQuickSwitcherOpensChat() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.chatRow("Carol Diaz").waitForExistence(timeout: 20))

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["quick-switcher-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("crl dz")
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: app.composer, placeholder: "Message Carol Diaz", timeout: 5))
    }

    /// ⌘N asks for an address and opens a chat with it, without adding a contact.
    @MainActor
    func testCommandNStartsChat() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.chatRow("Carol Diaz").waitForExistence(timeout: 20))

        app.typeKey("n", modifierFlags: .command)
        let address = app.textFields["new-chat-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeText("zoe@example.com")
        app.buttons["new-chat-confirm"].click()

        XCTAssertTrue(address.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.chatRow("zoe").waitForExistence(timeout: 5))
        XCTAssertTrue(app.wait(for: app.composer, placeholder: "Message zoe", timeout: 5))
    }
}
