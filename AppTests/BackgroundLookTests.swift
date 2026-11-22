import AppKit
import Testing
import XippiStore

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

    /// Not in a virtual machine. CI's runner is one: there the window's title bar captures
    /// black (`[0, 0, 0]` above a list of `[33, 31, 36]`), and RenderBox, which draws its
    /// glass, finds no shaders for the virtual graphics card ("unable to find air64_v27
    /// slice"). Tests that measure the title bar run on a real Mac only.
    nonisolated static let drawsTheTitleBar: Bool = {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) != 0 || present == 0
    }()

    /// The main window as it is drawn, in `appearance` when one is given, once it has stopped
    /// changing. `shown` picks it by its title, which an open chat changes. The appearance is
    /// chosen as in Settings: set on the window itself, behind SwiftUI, it turned only the
    /// sidebar dark on a light Mac (CI's) and left the chat side blank white.
    static func captureMainWindow(
        _ appearance: NSAppearance.Name? = nil,
        where shown: (NSWindow) -> Bool = { $0.title == Copy.appName }
    ) async throws -> CGImage {
        var window: NSWindow?
        for _ in 0..<50 where window == nil {
            window = NSApp.windows.filter { $0.isVisible && shown($0) }
                .max { $0.frame.width < $1.frame.width }
            if window == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let main = try #require(window, "the main window")
        // The test host has no account: its add-account overlay dims the window.
        DebugSnapshot.model?.onboarding = nil
        let settings = try #require(DebugSnapshot.settings)
        let previous = settings.appearance
        defer { settings.appearance = previous }
        if let appearance { settings.appearance = appearance == .darkAqua ? .dark : .light }
        main.orderFront(nil)
        return try await settled(main)
    }

    /// The window once two captures 300 ms apart match, attached to the test, so a failure on
    /// CI shows what it measured. Gives up after 8 seconds with the last capture.
    static func settled(_ window: NSWindow) async throws -> CGImage {
        try await Task.sleep(for: .milliseconds(800))
        var last = try await SettingsLookTests.capture(window)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let next = try await SettingsLookTests.capture(window)
            let changed = changedPoints(last, next)
            last = next
            if changed <= 40 { break }
        }
        // Kept with the test's results, to see what a failure on CI measured.
        Attachment.record(last, named: "\(window.title).png")
        return last
    }

    /// How many points of a grid over two captures of one window differ visibly. A blinking
    /// caret changes a few.
    static func changedPoints(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == 32,
            b.bitsPerPixel == 32, a.bytesPerRow == b.bytesPerRow,
            let first = a.dataProvider?.data, let second = b.dataProvider?.data,
            let x = CFDataGetBytePtr(first), let y = CFDataGetBytePtr(second)
        else { return .max }
        var changed = 0
        for row in stride(from: 0, to: a.height, by: 6) {
            for column in stride(from: 0, to: a.width, by: 6) {
                let offset = row * a.bytesPerRow + column * 4
                if (0..<3).contains(where: { abs(Int(x[offset + $0]) - Int(y[offset + $0])) > 6 }) {
                    changed += 1
                }
            }
        }
        return changed
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

    /// Light or Dark chosen in Settings reaches the whole window, the chat side as well as the
    /// sidebar. Asked for the look the Mac is not in, since choosing the one it is in changes
    /// nothing. Measured on the empty list and on the chat side, clear of their placeholders.
    @Test func theChosenLookReachesTheWholeWindow() async throws {
        // Dark on a light Mac, light on a dark one.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let image = try await Self.captureMainWindow(dark ? .darkAqua : .aqua)
        let points = [
            (20, Int(Double(image.height) * 0.3)),
            (image.width * 7 / 8, Int(Double(image.height) * 0.3)),
        ]
        for (x, y) in points {
            let colour = SettingsLookTests.colour(image, x: x, y: y)
            let fits = dark ? (colour.max() ?? 255) < 100 : (colour.min() ?? 0) > 180
            #expect(fits, "\(colour) at \(x), \(y) in \(dark ? "dark" : "light")")
        }
    }

    /// The sidebar shows the chat's background from the top of the window to the bottom: the
    /// same colour under the title bar, behind the search, the list and the accounts (the
    /// bars drew their own grey over it), and not the window's plain background. Colours are
    /// compared with each other: the test host's window is never the active one, which tints
    /// a sidebar slightly.
    @Test(.enabled(if: Self.drawsTheTitleBar, "a virtual machine draws the title bar black"))
    func theBackgroundFillsTheSidebar() async throws {
        let image = try await Self.captureMainWindow()
        func near(_ a: [Int], _ b: [Int], _ tolerance: Int) -> Bool {
            zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
        }
        let window = try #require(
            NSApp.windows.filter { $0.isVisible && $0.title == Copy.appName }
                .max { $0.frame.width < $1.frame.width })
        let scale = CGFloat(image.width) / window.frame.width
        // Down the sidebar's left edge: the title bar, the list, the accounts. The title bar
        // is measured in points from the top, above and below the window's buttons: a share
        // of the height met a button or the search field in a smaller window (CI's, which
        // has none saved).
        let top = [8.0, 44.0].map {
            SettingsLookTests.colour(image, x: 20, y: Int($0 * scale))
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
    @Test(.enabled(if: Self.drawsTheTitleBar, "a virtual machine draws the title bar black"))
    func noBandRunsUnderTheToolbar() async throws {
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

    /// The sidebar has no "..." menu beside the accounts: it held only Settings, which the app
    /// menu has. Where its round button sat, at the footer's right end, the footer is plain.
    @Test func theSidebarHasNoMoreMenu() async throws {
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
        let right = Int((sidebar.frame.maxX - 8) * scale)
        let left = Int((sidebar.frame.maxX - 48) * scale)
        let spread = Self.spread(
            image, x: left..<right,
            y: (image.height - Int(52 * scale))..<(image.height - Int(8 * scale)))
        #expect(spread <= 12, "colours at the footer's right end differ by up to \(spread)")
    }

    /// The chat's picture sits in the middle of the title's glass: as far from its top as from
    /// its bottom. The toolbar lays the glass out where a 36-point item's would start, so the
    /// 44-point pill hung below its content: 4 points of glass over the picture, 12 under it.
    @Test(.enabled(if: Self.drawsTheTitleBar, "a virtual machine draws the title bar black"))
    func theTitlesPictureSitsInTheMiddleOfItsGlass() async throws {
        let name = "pill-\(UUID().uuidString.prefix(6))"
        let (model, item) = try ChatMenuTests.room("\(name)@muc.example.org")
        model.selection = item.id
        defer { model.selection = nil }
        // The open chat names the window.
        let image = try await Self.captureMainWindow(.darkAqua) { $0.title.hasPrefix(name) }
        let window = try #require(
            NSApp.windows.first { $0.isVisible && $0.title.hasPrefix(name) })
        let sizes = ControlHeight.Transcript.self
        func platters(_ view: NSView) -> [NSView] {
            let own = String(describing: type(of: view)) == "NSToolbarPlatterView" ? [view] : []
            return own + view.subviews.flatMap(platters)
        }
        let glass = try #require(
            window.contentView?.superview.map(platters)?.first {
                abs($0.frame.height - sizes.titlePill) < 1
            }, "the title's glass")
        let frame = glass.convert(glass.bounds, to: nil)
        let scale = CGFloat(image.width) / window.frame.width
        let top = Int((window.frame.height - frame.maxY) * scale)
        let bottom = Int((window.frame.height - frame.minY) * scale)
        // Down the picture's left part, clear of its letter.
        let x = Int((frame.minX + sizes.titleAvatarInset + sizes.titleAvatar * 0.22) * scale)
        let rows = (top..<bottom).filter { y in
            let colour = SettingsLookTests.colour(image, x: x, y: y)
            return (colour.max() ?? 0) - (colour.min() ?? 0) > 50
        }
        let first = try #require(rows.first, "the picture in the glass")
        let last = try #require(rows.last)
        let above = CGFloat(first - top) / scale
        let below = CGFloat(bottom - 1 - last) / scale
        #expect(abs(above - below) <= 1.5, "\(above) points above the picture, \(below) below")
    }
}
