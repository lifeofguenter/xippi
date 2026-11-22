import XCTest

/// Rooms: joining one for real against the test servers (`make up`), and the members list's
/// moderation on the inspector's sample members (`-UITestInspectorSamples 1`, seeded data).
final class RoomUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A room made with the Create sheet, left, and joined again with the Join sheet (⇧⌘N):
    /// joined, with alice among the members. (Joining a room that does not exist would make a
    /// new one, which only Create keeps.)
    @MainActor
    func testJoinRoomShowsJoinedAndMembers() {
        let app = LiveApp.launch()
        LiveApp.logIn(app, address: "alice@prosody.test")
        let room = "ui-\(UUID().uuidString.prefix(8).lowercased())@conference.prosody.test"

        app.menuBarItems["File"].click()
        app.menuItems["Create room"].click()
        let address = app.textFields["create-room-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "create sheet")
        address.click()
        address.typeText(room)
        app.buttons["create-room-confirm"].click()
        XCTAssertTrue(address.waitForNonExistence(timeout: 20), "room created")

        app.typeKey("i", modifierFlags: [.command, .option])
        let leave = app.buttons["room-leave"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "inspector shows the room")
        leave.click()
        XCTAssertTrue(app.buttons["room-join"].waitForExistence(timeout: 10), "left")

        app.typeKey("n", modifierFlags: [.command, .shift])
        let joinAddress = app.textFields["join-room-address"]
        XCTAssertTrue(joinAddress.waitForExistence(timeout: 10), "join sheet")
        joinAddress.click()
        joinAddress.typeText(room)
        app.buttons["join-room-confirm"].click()
        XCTAssertTrue(joinAddress.waitForNonExistence(timeout: 20), "join sent")

        XCTAssertTrue(app.buttons["room-leave"].waitForExistence(timeout: 20), "joined")
        XCTAssertFalse(app.descendants(matching: .any)["room-state"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["member-alice"].waitForExistence(timeout: 10),
            "alice among the members")
    }

    /// Kick is red, asks first, and the question's default is Cancel: Return keeps dave.
    @MainActor
    func testKickRequiresConfirmation() {
        let app = LiveApp.launchWithSamples()
        XCTAssertTrue(app.openChat("prosody"))
        app.typeKey("i", modifierFlags: [.command, .option])
        let actions = app.descendants(matching: .any)["member-actions-dave"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "dave's actions")
        actions.click()
        app.menuItems["Kick"].click()

        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "asked before kicking")
        XCTAssertTrue(app.label("Kick dave?", in: dialog).exists)
        XCTAssertTrue(dialog.buttons["Kick"].exists)
        XCTAssertTrue(dialog.buttons["Cancel"].exists)
        // Return takes the default, which is Cancel: nothing happens.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["inspector-error"].exists, "nothing was sent")
        XCTAssertTrue(app.descendants(matching: .any)["member-dave"].exists)
    }
}

/// Launching the app for the room and encryption UI tests.
enum LiveApp {
    /// The test servers' CA from the repository, as PEM text: the sandboxed app cannot read
    /// the repository, so `-UITestCA` takes the certificate itself.
    static var testCA: String {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "dev/certs/test-ca.pem")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// An empty in-memory database whose accounts connect to the test servers.
    @MainActor static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestDatabase", "memory", "-ApplePersistenceIgnoreState", "YES", "-UITestCA",
            testCA, "-UITestServer", "localhost",
        ]
        app.launch()
        return app
    }

    /// Seeded data, the inspector showing sample members and devices.
    @MainActor static func launchWithSamples() -> XCUIApplication {
        let app = XCUIApplication.seeded(messages: 20)
        app.launchArguments += ["-UITestInspectorSamples", "1"]
        app.launch()
        XCTAssertTrue(app.waitForSeed())
        return app
    }

    /// Fills in the add-account sheet, which opens by itself without accounts, and waits until
    /// the account is online.
    @MainActor static func logIn(_ app: XCUIApplication, address: String) {
        let field = app.textFields["add-account-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "add-account sheet")
        field.click()
        field.typeText(address)
        let secret = app.secureTextFields["add-account-password"]
        secret.click()
        secret.typeText("xippi-test")
        app.buttons["add-account-login"].click()
        let footer = app.descendants(matching: .any)["account-status"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        XCTAssertTrue(footer.waitForValue("Online", timeout: 20), "footer: \(footer.stringValue)")
    }
}
