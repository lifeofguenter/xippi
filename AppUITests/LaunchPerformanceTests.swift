import XCTest

/// Launch with 50 chats and 1M stored messages on disk (spec 10: under 500 ms). Run with the
/// "Xippi Performance" scheme, which builds the Performance configuration; the default
/// scheme skips this class.
final class LaunchPerformanceTests: XCTestCase {
    /// In the app's container; the seed run writes it, the measured launches open it.
    private static let databaseFile = "launch-50-chats-1m.sqlite"
    private static let budgetMilliseconds = 500.0
    private static let launches = 5

    override func setUp() {
        continueAfterFailure = false
    }

    /// Seeds the database once, then launches 5 times. The app reports the time from its
    /// process's start to the first idle main thread after the first chat list; the median
    /// must stay under 500 ms. `XCTApplicationLaunchMetric` is recorded beside it for the trend.
    /// The accounts in the database are disabled, so nothing connects.
    @MainActor
    func testLaunchWith50ChatsAnd1MMessagesUnder500ms() throws {
        let seed = XCUIApplication()
        seed.launchArguments += [
            "-UITestDatabaseFile", Self.databaseFile, "-UITestSeed", "1000000",
            "-UITestChats", "50", "-ApplePersistenceIgnoreState", "YES",
        ]
        // The 400 MB database goes at the end whatever happens, a failed budget included.
        addTeardownBlock { @MainActor in
            let cleanup = XCUIApplication()
            cleanup.launchArguments += [
                "-UITestDatabaseFile", Self.databaseFile, "-UITestDatabaseRemove", "YES",
            ]
            cleanup.launch()
            cleanup.terminate()
        }
        seed.launch()
        XCTAssertTrue(seed.waitForSeed(timeout: 900), "Seeding 1,000,000 messages did not finish")
        seed.terminate()

        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestDatabaseFile", Self.databaseFile, "-ApplePersistenceIgnoreState", "YES",
        ]
        var samples: [Double] = []
        for _ in 0..<Self.launches {
            app.launch()
            let probe = app.staticTexts["launch-ms"]
            let reported = NSPredicate(format: "label != '' OR value != ''")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: reported, object: probe)],
                timeout: 10)
            if let milliseconds = Double(Self.text(of: probe)) { samples.append(milliseconds) }
            app.terminate()
        }
        XCTAssertEqual(samples.count, Self.launches, "The app did not report every launch")
        let median = try XCTUnwrap(Self.median(samples))
        XCTAssertLessThan(
            median, Self.budgetMilliseconds,
            "Median launch \(median) ms over \(samples.count) launches: \(samples)")

        let options = XCTMeasureOptions()
        options.iterationCount = Self.launches
        measure(
            metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options
        ) {
            app.launch()
            XCTAssertTrue(app.chatRow("prosody").waitForExistence(timeout: 10))
        }
        app.terminate()
    }

    @MainActor private static func text(of element: XCUIElement) -> String {
        let value = (element.value as? String) ?? ""
        return value.isEmpty ? element.label : value
    }

    private static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
