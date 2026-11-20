import XCTest

/// Launching the app on seeded test data and finding its parts.
extension XCUIApplication {
    /// An in-memory database with 3 accounts, 40 chats and `messages` messages in "prosody".
    static func seeded(messages: Int = 300) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestSeed", String(messages),
            // Every launch starts from the same window state.
            "-ApplePersistenceIgnoreState", "YES",
        ]
        return app
    }

    var sidebar: XCUIElement { descendants(matching: .any)["sidebar"] }
    var transcript: XCUIElement { tables["transcript"] }
    var composer: XCUIElement { textViews["composer"] }

    /// The sidebar rows on screen, top to bottom.
    var chatRows: XCUIElementQuery {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat:'"))
    }

    func chatRow(_ name: String) -> XCUIElement {
        descendants(matching: .any)["chat:\(name)"]
    }

    /// Waits until the seeded messages are stored.
    func waitForSeed(timeout: TimeInterval = 120) -> Bool {
        let state = staticTexts["seed-state"]
        let ready = NSPredicate(format: "label == 'ready' OR value == 'ready'")
        let expectation = XCTNSPredicateExpectation(predicate: ready, object: state)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens a chat from the sidebar and waits for its composer.
    @discardableResult
    func openChat(_ name: String, timeout: TimeInterval = 10) -> Bool {
        let row = chatRow(name)
        guard row.waitForExistence(timeout: timeout) else { return false }
        row.click()
        return wait(for: composer, placeholder: "Message \(name)", timeout: timeout)
    }

    func wait(for element: XCUIElement, placeholder: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "placeholderValue == %@", placeholder)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A label showing exactly `text`, inside `parent` or anywhere.
    func label(_ text: String, in parent: XCUIElement? = nil) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        return (parent ?? self).staticTexts.matching(predicate).firstMatch
    }

    /// The transcript's messages. Each is one element whose label reads the sender, time,
    /// quote, text and status; the parts inside are not read again (VoiceOver, I9).
    var messages: XCUIElementQuery {
        transcript.descendants(matching: .any).matching(identifier: "message")
    }

    /// The message whose text is `text`: a part of its label of its own.
    func message(_ text: String) -> XCUIElement {
        messages.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label ENDSWITH %@", ", \(text), ", ", \(text)")
        ).firstMatch
    }

    /// A message whose label says `text` anywhere: a status ("Sending"), a reaction, a quote.
    func message(saying text: String) -> XCUIElement {
        messages.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

extension XCUIElement {
    var stringValue: String { (value as? String) ?? "" }

    /// Waits until the element's value is `expected`.
    func waitForValue(_ expected: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
