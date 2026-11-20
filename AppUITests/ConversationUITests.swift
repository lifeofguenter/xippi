import AppKit
import XCTest

/// Files, reactions and the voice button through `StoreOnlyCommands`, on seeded data.
final class ConversationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A file in the test's temporary folder, put on the pasteboard as a file.
    private func pasteboardFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try Data("Xippi UI test\n".utf8).write(to: url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        return url
    }

    @MainActor
    private func transcriptItem(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.transcript.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A pasted file waits above the text, and Return sends it with the text.
    @MainActor
    func testDropFileUploads() throws {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let file = try pasteboardFile(named: "ui-test-upload.txt")
        defer { try? FileManager.default.removeItem(at: file) }

        app.composer.click()
        app.composer.typeKey("v", modifierFlags: .command)
        let pending = app.descendants(matching: .any)["pending-files"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertTrue(app.label("ui-test-upload.txt", in: pending).exists)
        XCTAssertTrue(app.composer.waitForValue(""), "The file does not go into the text")

        app.composer.typeText("Here it is\r")
        XCTAssertTrue(app.message("Here it is").waitForExistence(timeout: 5))
        XCTAssertTrue(
            transcriptItem(containing: "ui-test-upload.txt", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
    }

    /// A file pasted by mistake is taken back before it goes.
    @MainActor
    func testPendingFileCanBeRemoved() throws {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let file = try pasteboardFile(named: "ui-test-mistake.txt")
        defer { try? FileManager.default.removeItem(at: file) }

        app.composer.click()
        app.composer.typeKey("v", modifierFlags: .command)
        let pending = app.descendants(matching: .any)["pending-files"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        app.buttons["Remove ui-test-mistake.txt"].click()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 5))
        XCTAssertFalse(transcriptItem(containing: "ui-test-mistake.txt", in: app).exists)
    }

    /// React from the context menu: the chip shows the count; choosing it again takes it back.
    @MainActor
    func testReactionAppears() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let message = app.message("I'll check `prosodyctl`")
        XCTAssertTrue(message.waitForExistence(timeout: 5))

        message.rightClick()
        app.menuItems["React"].click()
        let palette = app.descendants(matching: .any)["reaction-palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.buttons["👍"].click()
        let chip = app.message(saying: "👍 1")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))

        message.rightClick()
        app.menuItems["React"].click()
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.buttons["👍"].click()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
    }

    /// The microphone takes the send button's place while there is nothing to send.
    @MainActor
    func testMicrophoneWhileEmpty() {
        let app = XCUIApplication.seeded()
        app.launch()
        XCTAssertTrue(app.openChat("Bob Chen"))
        let record = app.descendants(matching: .any)["record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))

        app.composer.click()
        app.composer.typeText("x")
        XCTAssertTrue(app.buttons["send"].waitForExistence(timeout: 5))
        XCTAssertTrue(record.waitForNonExistence(timeout: 5))
        app.composer.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(record.waitForExistence(timeout: 5))
    }
}
