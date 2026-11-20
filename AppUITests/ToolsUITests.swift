import XCTest

/// The power tools against the test servers (`make up`): the XML console, service discovery
/// and ad-hoc commands, on an empty in-memory database with "Show advanced XMPP features"
/// on. The accounts connect for real; passwords stay in memory.
final class ToolsUITests: XCTestCase {
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

    /// The app logged in as `account` on Prosody, with the Tools menu on. A setting passed
    /// as a launch argument is a property list value: `<true/>` is a Bool, `YES` a string.
    @MainActor
    private func launch(as account: String = "alice@prosody.test") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestDatabase", "memory", "-ApplePersistenceIgnoreState", "YES",
            "-UITestCA", Self.testCA, "-eu.xippi.showAdvancedFeatures", "<true/>",
        ]
        app.launch()
        let address = app.textFields["add-account-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "add-account sheet")
        address.click()
        address.typeText(account)
        let secret = app.secureTextFields["add-account-password"]
        secret.click()
        secret.typeText("xippi-test")
        let server = app.textFields["add-account-server"]
        server.click()
        server.typeText("localhost")
        app.buttons["add-account-login"].click()
        let footer = app.descendants(matching: .any)["account-status"]
        XCTAssertTrue(footer.waitForValue("Online", timeout: 15), "footer: \(footer.stringValue)")
        return app
    }

    @MainActor
    private func openTool(_ title: String, in app: XCUIApplication) {
        let tools = app.menuBars.menuBarItems["Tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5), "Tools menu")
        tools.click()
        app.menuItems[title].click()
    }

    @MainActor
    func testToolsMenuFollowsTheSetting() {
        let app = XCUIApplication.seeded(messages: 10)
        app.launchArguments += ["-eu.xippi.showAdvancedFeatures", "<false/>"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.menuBars.menuBarItems["Tools"].exists)
    }

    @MainActor
    func testXMLConsoleShowsOwnPresence() {
        let app = launch()
        openTool("XML console", in: app)
        let console = app.descendants(matching: .any)["xml-console"]
        XCTAssertTrue(console.waitForExistence(timeout: 10))

        // A presence typed into the send box goes out as the user, after one question.
        let draft = app.textViews["console-draft"]
        draft.click()
        draft.typeText("<presence><status>console</status></presence>")
        app.buttons["console-send"].click()
        let confirm = app.buttons["console-send-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "first send asks")
        confirm.click()

        // Each row is one element: its XML is its value.
        let sent = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'console-out' AND value CONTAINS '<status>console'"))
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 10), "own presence sent")
        let echoed = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == 'console-in' AND value CONTAINS %@",
                "from='alice@prosody.test/"))
        XCTAssertTrue(echoed.firstMatch.waitForExistence(timeout: 10), "own presence back")
        XCTAssertFalse(app.staticTexts["console-send-problem"].exists)
    }

    /// Spec 9.2: the tools are in the account's menu too.
    @MainActor
    func testXMLConsoleOpensFromTheAccountMenu() {
        let app = launch()
        app.descendants(matching: .any)["account-status"].click()
        let tools = app.descendants(matching: .any)["account-tools:alice@prosody.test"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5), "Tools in the account row")
        tools.click()
        app.menuItems["XML console"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["xml-console"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testXMLConsoleRefusesWhatIsNotAStanza() {
        let app = launch()
        openTool("XML console", in: app)
        let draft = app.textViews["console-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("<message><body>broken</message>")
        app.buttons["console-send"].click()
        let problem = app.staticTexts["console-send-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertEqual(problem.stringValue, "Not well-formed XML")
        XCTAssertFalse(app.buttons["console-send-confirm"].exists)
    }

    @MainActor
    func testDiscoBrowsesServer() {
        let app = launch()
        openTool("Service discovery", in: app)
        let tree = app.descendants(matching: .any)["disco-tree"]
        XCTAssertTrue(tree.waitForExistence(timeout: 10))
        for item in ["conference.prosody.test", "upload.prosody.test"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["disco-item:\(item)#"].waitForExistence(
                    timeout: 10), item)
        }
        app.descendants(matching: .any)["disco-item:conference.prosody.test#"].click()
        let features = app.descendants(matching: .any)["disco-features"]
        XCTAssertTrue(features.waitForExistence(timeout: 10))
        XCTAssertTrue(app.label("http://jabber.org/protocol/muc", in: features).exists)
    }

    @MainActor
    func testAdHocListsCommands() {
        let app = launch(as: "admin@prosody.test")
        openTool("Ad-hoc commands", in: app)
        let list = app.descendants(matching: .any)["adhoc-commands"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let addUser = app.descendants(matching: .any)[
            "adhoc-command:http://jabber.org/protocol/admin#add-user"]
        XCTAssertTrue(addUser.waitForExistence(timeout: 10), "Prosody's admin commands")
        addUser.click()
        XCTAssertTrue(app.descendants(matching: .any)["data-form"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["adhoc-cancel"].exists)
        app.buttons["adhoc-cancel"].click()
        XCTAssertTrue(app.staticTexts["adhoc-status"].waitForValue("Cancelled", timeout: 10))
    }
}
