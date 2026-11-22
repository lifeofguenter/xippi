import AppKit
import ScreenCaptureKit
import Testing

@testable import Xippi

/// How the Settings window looks, measured on the window itself: a check of colours, since
/// three rounds of fixes to its title bar were judged by eye and missed a band each time.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SettingsLookTests {
    /// The window as it shows, from the app's own windows (no screen recording permission).
    static func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let shown = try #require(
            content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: shown)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width)
        configuration.height = Int(filter.contentRect.height)
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
    }

    /// The colour at a point, as 8-bit RGB.
    static func colour(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let rep = NSBitmapImageRep(cgImage: image)
        let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        return [colour?.redComponent, colour?.greenComponent, colour?.blueComponent]
            .map { Int((($0 ?? 0) * 255).rounded()) }
    }

    /// The title bar, the tab row and the content are one colour on every tab, as in
    /// Messages: no lighter band behind the title over a form or the account list.
    @Test(arguments: [SettingsTab.accounts, .general])
    func theWindowIsOneColourFromTitleToContent(tab: SettingsTab) async throws {
        SettingsNavigation.shared.tab = tab
        // As the app menu's Settings… item opens it.
        let item = try #require(
            NSApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "," })
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        var window: NSWindow?
        for _ in 0..<50 where window == nil {
            try await Task.sleep(for: .milliseconds(100))
            window = NSApp.windows.first { $0.isVisible && $0.title == tab.title }
        }
        let settings = try #require(window, "the Settings window on \(tab.title)")
        defer { settings.close() }
        try await Task.sleep(for: .milliseconds(600))
        let image = try await Self.capture(settings)
        let width = image.width
        // Left of the tabs, over the list or form beside them, and well down in the content.
        let content = Self.colour(image, x: width / 2, y: image.height - 20)
        for point in [(20, 60), (width / 6, 60), (width - 20, 60), (width / 6, 86)] {
            let shown = Self.colour(image, x: point.0, y: point.1)
            let difference = zip(shown, content).map { abs($0 - $1) }.max() ?? 0
            #expect(difference <= 2, "title bar \(shown) against content \(content) at \(point)")
        }
    }

    /// A test launch keeps preferences of its own. It shared the standard ones with the
    /// installed app, so an appearance chosen in a test run was the user's at next launch.
    @Test func aTestLaunchLeavesTheUsersPreferencesAlone() throws {
        let settings = try #require(DebugSnapshot.settings)
        let key = "eu.xippi.appearance"
        let before = UserDefaults.standard.string(forKey: key)
        let was = settings.appearance
        defer { settings.appearance = was }
        settings.appearance = before == "dark" ? .light : .dark
        #expect(UserDefaults.standard.string(forKey: key) == before)
    }
}
