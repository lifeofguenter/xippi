import AppKit
import Testing

@testable import Xippi

/// The chat background as it is drawn: how strong the light confetti is, and that it fills
/// the sidebar from the top of the window to the bottom. Measured, not judged by eye.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct BackgroundLookTests {
    /// WCAG contrast between two sRGB colours (1 for none).
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let c = c.usingColorSpace(.sRGB) ?? c
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
                + 0.0722 * channel(c.blueComponent)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The colour of `name` in the given appearance.
    static func colour(_ name: String, _ appearance: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.clear
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(named: name)?.usingColorSpace(.sRGB) ?? .clear
        }
        return resolved
    }

    /// The light tile drawn at 2x: its strongest shape against its base colour. At full
    /// strength it reached about 1.5:1 and competed with the messages over it.
    @Test func theLightConfettiStaysQuiet() throws {
        let image = try #require(NSImage(named: "ChatConfetti"))
        let base = Self.colour("ChatConfettiBase", .aqua)
        var strongest = 1.0
        var visible = false
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 240, height: 240))
            NSGraphicsContext.restoreGraphicsState()
            for y in stride(from: 0, to: 240, by: 1) {
                for x in stride(from: 0, to: 240, by: 1) {
                    guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                    let ratio = Self.contrast(pixel, base)
                    strongest = max(strongest, ratio)
                    if ratio > 1.05 { visible = true }
                }
            }
        }
        #expect(strongest <= 1.3, "strongest shape \(strongest):1")
        #expect(visible, "the pattern still shows")
    }

    /// The main window as it is drawn, in `appearance` when one is given.
    static func captureMainWindow(_ appearance: NSAppearance.Name? = nil) async throws -> CGImage {
        var window: NSWindow?
        for _ in 0..<50 where window == nil {
            window = NSApp.windows.filter { $0.isVisible && $0.title == Copy.appName }
                .max { $0.frame.width < $1.frame.width }
            if window == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let main = try #require(window, "the main window")
        // The test host has no account: its add-account overlay dims the window.
        DebugSnapshot.model?.onboarding = nil
        let previous = main.appearance
        defer { main.appearance = previous }
        if let appearance { main.appearance = NSAppearance(named: appearance) }
        main.orderFront(nil)
        try await Task.sleep(for: .milliseconds(800))
        return try await SettingsLookTests.capture(main)
    }

    /// How far apart the colours in a rectangle are: the largest spread of any channel.
    static func spread(_ image: CGImage, x: Range<Int>, y: Range<Int>) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var low = [255, 255, 255]
        var high = [0, 0, 0]
        for row in y {
            for column in x {
                guard let colour = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                    .map { Int(($0 * 255).rounded()) }
                for index in 0..<3 {
                    low[index] = min(low[index], channels[index])
                    high[index] = max(high[index], channels[index])
                }
            }
        }
        return (0..<3).map { high[$0] - low[$0] }.max() ?? 0
    }

    /// The sidebar shows the chat's background from the top of the window to the bottom: the
    /// same colour under the title bar, behind the search, the list and the accounts (the
    /// bars drew their own grey over it), and not the window's plain background. Colours are
    /// compared with each other: the test host's window is never the active one, which tints
    /// a sidebar slightly.
    @Test func theBackgroundFillsTheSidebar() async throws {
        let image = try await Self.captureMainWindow()
        func near(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool {
            zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        }
        // Down the sidebar's left edge: the title bar, the search, the list, the accounts.
        let top = [0.04, 0.09].map {
            SettingsLookTests.colour(image, x: 20, y: Int(Double(image.height) * $0))
        }
        let middle = [0.3, 0.5, 0.7].map {
            SettingsLookTests.colour(image, x: 20, y: Int(Double(image.height) * $0))
        }
        let bottom = [0.93, 0.96].map {
            SettingsLookTests.colour(image, x: 20, y: Int(Double(image.height) * $0))
        }
        let list = try #require(middle.first { m in middle.filter { near($0, m, 3) }.count >= 2 })
        #expect(top.contains { near($0, list, 3) }, "title bar \(top) against the list \(list)")
        #expect(
            bottom.contains { near($0, list, 3) }, "accounts \(bottom) against the list \(list)")
        // The empty chat area beside it is the window's plain background.
        let plain = SettingsLookTests.colour(image, x: image.width * 3 / 4, y: image.height / 2)
        #expect(!near(list, plain, 4), "the sidebar \(list) is the plain background \(plain)")
    }

    /// Behind the sidebar the background is blurred into a wash, as in Messages: drawn sharp,
    /// its pattern ran behind the chat list and made it hard to read. Measured in dark, where
    /// the pattern is strongest, on a stretch of the empty list.
    @Test func theSidebarBackgroundIsBlurred() async throws {
        let image = try await Self.captureMainWindow(.darkAqua)
        let spread = Self.spread(
            image, x: 8..<100,
            y: Int(Double(image.height) * 0.25)..<Int(Double(image.height) * 0.45))
        #expect(spread <= 3, "colours behind the list differ by up to \(spread)")
    }

    /// The toolbar draws no band of its own: the panel below it runs to the top of the window.
    /// Its background lay lighter across the chat and the inspector, and Messages has none.
    /// Measured just right of the sidebar, clear of the title in the middle of the bar: a
    /// fixed share of the window's width met the title in a wide window.
    @Test func noBandRunsUnderTheToolbar() async throws {
        let image = try await Self.captureMainWindow(.darkAqua)
        let window = try #require(
            NSApp.windows.filter { $0.isVisible && $0.title == Copy.appName }
                .max { $0.frame.width < $1.frame.width })
        func splitViews(_ view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
        }
        let split = try #require(window.contentView.map(splitViews)?.first)
        let sidebar = try #require(split.arrangedSubviews.first)
        let scale = CGFloat(image.width) / window.frame.width
        let x = Int((sidebar.frame.maxX + 40) * scale)
        let underToolbar = SettingsLookTests.colour(image, x: x, y: 20)
        let below = SettingsLookTests.colour(image, x: x, y: Int(Double(image.height) * 0.25))
        #expect(
            zip(underToolbar, below).allSatisfy { abs($0 - $1) <= 2 },
            "under the toolbar \(underToolbar), below it \(below)")
    }
}
