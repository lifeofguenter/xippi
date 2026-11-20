import XCTest

/// Opening and scrolling a chat with 100,000 messages. Run with the "Xippi Performance"
/// scheme, which builds Release; the default scheme skips this class.
final class TranscriptPerformanceTests: XCTestCase {
    private static let openBudgetMilliseconds = 100.0
    /// The first open after launch is an accepted deviation (ruling R75, measured 212 ms):
    /// this ceiling still catches a regression.
    private static let firstOpenCeilingMilliseconds = 250.0
    /// At most this share of scrolling frames may come late.
    private static let lateFrameBudget = 0.05
    private static let worstFrameMilliseconds = 50.0

    override func setUp() {
        continueAfterFailure = false
    }

    /// From selecting the chat to the first frame of its messages, as the app's `OpenChat`
    /// signpost interval. The median of the iterations must stay under 100 ms.
    @MainActor
    func testTranscriptOpens100kUnder100ms() throws {
        let app = XCUIApplication.seeded(messages: 100_000)
        app.launch()
        XCTAssertTrue(app.waitForSeed(), "Seeding 100,000 messages did not finish")
        XCTAssertTrue(app.openChat("prosody"))
        XCTAssertTrue(app.openChat("Bob Chen"))

        let probe = app.staticTexts["transcript-open-ms"]
        var samples: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 7
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        let metric = XCTOSSignpostMetric(
            subsystem: "eu.xippi.Xippi", category: "Transcript", name: "OpenChat")
        measure(metrics: [metric], options: options) {
            XCTAssertTrue(app.openChat("Bob Chen"))
            let before = Self.opens(in: probe)
            startMeasuring()
            app.chatRow("prosody").click()
            XCTAssertTrue(Self.waitForOpen(after: before, probe: probe))
            stopMeasuring()
            if let milliseconds = Self.milliseconds(in: probe) { samples.append(milliseconds) }
        }

        let median = try XCTUnwrap(Self.median(samples))
        XCTAssertLessThan(
            median, Self.openBudgetMilliseconds,
            "Median open time \(median) ms over \(samples.count) opens: \(samples)")
    }

    /// The first open after launch, the open every user makes first (I4): no other open warms
    /// the views before it. Five launches; under ruling R75 the median must stay under the
    /// 250 ms ceiling, not the 100 ms budget of later opens.
    @MainActor
    func testFirstOpenAfterLaunchUnder250ms() throws {
        var samples: [Double] = []
        for _ in 0..<5 {
            let app = XCUIApplication.seeded(messages: 100_000)
            app.launch()
            XCTAssertTrue(app.waitForSeed(), "Seeding 100,000 messages did not finish")
            let probe = app.staticTexts["transcript-open-ms"]
            let row = app.chatRow("prosody")
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.click()
            XCTAssertTrue(Self.waitForOpen(after: 0, probe: probe))
            if let milliseconds = Self.milliseconds(in: probe) { samples.append(milliseconds) }
            app.terminate()
        }
        let median = try XCTUnwrap(Self.median(samples))
        XCTAssertLessThan(
            median, Self.firstOpenCeilingMilliseconds,
            "Median first open \(median) ms over \(samples.count) launches: \(samples)")
    }

    /// Scrolling through the transcript's history and back. The app counts the frames drawn
    /// while it scrolls; at most 5% may come late (more than one and a half display intervals
    /// after the previous one) and none may take longer than 50 ms. The system's scroll and
    /// deceleration signposts are recorded as well (`scrollDecelerationMetric` is not available
    /// on macOS; `scrollingAndDecelerationMetric` is its replacement).
    @MainActor
    func testScrollingKeepsFrameTime() {
        let app = XCUIApplication.seeded(messages: 100_000)
        app.launch()
        XCTAssertTrue(app.waitForSeed(), "Seeding 100,000 messages did not finish")
        XCTAssertTrue(app.openChat("prosody"))
        let transcript = app.transcript
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let probe = app.staticTexts["scroll-frames"]

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<4 { transcript.scroll(byDeltaX: 0, deltaY: 1_500) }
            for _ in 0..<4 { transcript.scroll(byDeltaX: 0, deltaY: -1_500) }
        }

        // The app publishes its counts when a scroll ends.
        let counted = NSPredicate(
            format: "NOT (label BEGINSWITH '0 ') OR NOT (value BEGINSWITH '0 ')")
        _ = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: counted, object: probe)], timeout: 5)
        let parts = Self.probeText(probe).split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else {
            XCTFail("No frame counts from the app: \(Self.probeText(probe))")
            return
        }
        let (frames, late, worst) = (parts[0], parts[1], parts[2])
        XCTAssertGreaterThan(frames, 20, "Too few scrolling frames were drawn to judge")
        XCTAssertLessThanOrEqual(
            late / max(frames, 1), Self.lateFrameBudget,
            "\(Int(late)) of \(Int(frames)) scrolling frames came late")
        XCTAssertLessThanOrEqual(
            worst, Self.worstFrameMilliseconds, "The slowest scrolling frame took \(worst) ms")
    }

    // MARK: Reading the app's timing probe ("<opens> <milliseconds>")

    @MainActor private static func opens(in probe: XCUIElement) -> Int {
        Int(probeText(probe).split(separator: " ").first ?? "") ?? 0
    }

    @MainActor private static func milliseconds(in probe: XCUIElement) -> Double? {
        let parts = probeText(probe).split(separator: " ")
        return parts.count == 2 ? Double(parts[1]) : nil
    }

    @MainActor private static func probeText(_ probe: XCUIElement) -> String {
        let value = (probe.value as? String) ?? ""
        return value.isEmpty ? probe.label : value
    }

    @MainActor private static func waitForOpen(after count: Int, probe: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if opens(in: probe) > count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
