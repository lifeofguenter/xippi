import AppKit
import CoreImage
import Security
import Testing
import UserNotifications

@testable import Xippi

/// Rules of the main and Settings windows that broke in use.
@MainActor @Suite struct WindowRulesTests {
    /// One window size on every tab: a size per tab moved the window's edges at every switch.
    @Test func everySettingsTabHasTheSameSize() {
        let sizes = Set(SettingsTab.allCases.map { "\($0.size)" })
        #expect(sizes.count == 1)
    }

    /// Messages that scroll under a resting pointer are entered but not always exited: the
    /// newest one hovered ends the one before, so one react button shows at most.
    @Test func oneMessageAtATimeIsHovered() {
        let first = MessageCellView(frame: .zero)
        let second = MessageCellView(frame: .zero)
        first.becomeHovered()
        #expect(first.isHovered)
        second.becomeHovered()
        #expect(!first.isHovered)
        #expect(second.isHovered)
    }

    /// The chat's title bar is clear over the messages, with its band only while the pointer
    /// is on the bar: the top of the chat, followed by position, under the bar's own views too.
    /// There the messages' cursors stay off, or they took turns with the bar's pointer.
    @Test func thePointerOnTheTitleBarBringsItsBand() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: false)
        let view = TitleBarHoverView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.barHeight = 52
        window.contentView = view
        var seen: [Bool] = []
        view.onChange = { seen.append($0) }
        /// The pointer `fromTop` points below the window's top edge.
        func moved(_ fromTop: CGFloat) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: NSPoint(x: 200, y: 300 - fromTop),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        view.mouseEntered(with: try moved(200))
        view.mouseMoved(with: try moved(20))
        view.mouseMoved(with: try moved(40))
        view.mouseMoved(with: try moved(120))
        view.mouseMoved(with: try moved(10))
        #expect(!window.areCursorRectsEnabled)
        view.mouseExited(with: try moved(10))
        #expect(seen == [true, false, true, false])
        // The messages' cursors are off only while the pointer is on the bar.
        #expect(window.areCursorRectsEnabled)
        view.mouseMoved(with: try moved(20))
        #expect(!window.areCursorRectsEnabled)
        // Leaving the window on the bar turns them on again.
        window.contentView = NSView()
        #expect(window.areCursorRectsEnabled)
        // It follows the pointer and never takes a click from the bar or the messages.
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        #expect(view.hitTest(NSPoint(x: 200, y: 20)) == nil)
    }

    /// The title bar names the chat and, under the name, who is typing, else the private
    /// chat's room and the account it runs on.
    @Test func theTitleSaysWhoIsTypingElseWhereTheChatIs() {
        let typing = "bob is typing…"
        let room = "Private message through Team"
        let account = "as me · me@example.org"
        #expect(ChatTitle.subtitle(typing: typing, privateLabel: room, identity: account) == typing)
        #expect(
            ChatTitle.subtitle(typing: nil, privateLabel: room, identity: account)
                == "\(room) · \(account)")
        #expect(ChatTitle.subtitle(typing: nil, privateLabel: nil, identity: account) == account)
        #expect(ChatTitle.subtitle(typing: nil, privateLabel: nil, identity: nil) == nil)
    }

    /// The pointer on the bar blurs the messages under it, lightly enough that they still
    /// show: a blur in the scroll view, as tall as the bar. A material over the transcript drew
    /// a flat band that hid them. Off, the blur leaves the view tree, where it still drew.
    @Test func theBarBlursTheMessagesUnderItWhileThePointerIsThere() async throws {
        let model = try #require(DebugSnapshot.model)
        let transcript = TranscriptController(
            database: model.database, commands: model.commands, timing: model.openTiming)
        let scrollView = try #require(transcript.makeScrollView() as? TranscriptScrollView)
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        transcript.setInsets(top: 52, bottom: 80)
        let band = scrollView.titleBarBand
        #expect(band.superview == nil)

        transcript.showTitleBarBand(true)
        #expect(band.superview === scrollView)
        let top: CGFloat = scrollView.isFlipped ? 0 : 300 - 52
        #expect(band.frame == NSRect(x: 0, y: top, width: 400, height: 52))
        let filters = try #require(band.layer?.backgroundFilters as? [CIFilter])
        func filter(_ name: String) -> CIFilter? {
            filters.first { $0.attributes[kCIAttributeFilterName] as? String == name }
        }
        let radius = try #require(
            filter("CIGaussianBlur")?.value(forKey: kCIInputRadiusKey) as? NSNumber)
        #expect(CGFloat(radius.doubleValue) == TitleBarBlurView.blurRadius)
        // The blurred messages lie where the messages are, at their size.
        let clamp = try #require(
            filter("CIAffineClamp")?.value(forKey: kCIInputTransformKey) as? NSAffineTransform)
        let scale = clamp.transform(NSSize(width: 10, height: 10))
        let shift = clamp.transform(NSPoint.zero)
        #expect(scale == NSSize(width: 10, height: 10))
        #expect(shift == .zero)
        #expect(TitleBarBlurView.blurRadius <= 10)
        #expect(band.layer?.masksToBounds == true)
        #expect(band.hitTest(NSPoint(x: 200, y: 20)) == nil)

        transcript.showTitleBarBand(false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(band.superview == nil)
    }

    /// The chat's pill in the title bar: the picture's curve runs beside the pill's round end,
    /// the words keep clear of the other end, and the name and the line under it clear of the
    /// top and the bottom. Both sat 4 points from the glass's ends, then the two lines touched
    /// its top and bottom.
    @Test func theChatPillLeavesRoomAroundItsContent() {
        let sizes = ControlHeight.Transcript.self
        #expect(sizes.titleAvatar + 2 * sizes.titleAvatarInset == sizes.titlePill)
        #expect(sizes.titleAvatarInset >= 8)
        #expect(sizes.titleTextInset >= sizes.titlePill / 3)
        let layout = NSLayoutManager()
        let lines =
            layout.defaultLineHeight(for: Typography.body(weight: .semibold))
            + layout.defaultLineHeight(for: Typography.body())
        #expect(sizes.titleTextVerticalInset >= 4)
        #expect(lines + 2 * sizes.titleTextVerticalInset <= sizes.titlePill)
    }

    /// Notifications turned off in System Settings showed nothing, and nothing in the app said
    /// so: the Notifications tab says it, with the way to the app's page in System Settings.
    @Test func theNotificationsTabSaysWhenNotificationsAreOff() {
        #expect(NotificationSettings.showsOffNotice(.denied))
        for status in [UNAuthorizationStatus.authorized, .provisional, .notDetermined] {
            #expect(!NotificationSettings.showsOffNotice(status))
        }
        #expect(!NotificationSettings.showsOffNotice(nil))
        let url = NotificationSettings.systemSettingsURL.absoluteString
        #expect(
            url.hasPrefix("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
        #expect(url.hasSuffix("?id=eu.xippi.Xippi"))
    }

    /// About says what the app is licensed under, where its source is, links the site's
    /// privacy and terms pages, and carries the notices the shipped libraries' licenses require
    /// in the app, with the owner's copyright. Nothing about what the App Store price pays for.
    /// A window of its own, wider than the standard panel (285 points), which wrapped the
    /// notices into a narrow column.
    @Test func aboutCarriesTheLicenceTheSourceAndTheNotices() async throws {
        #expect(Copy.aboutLicence.contains("GNU General Public License, version 3"))
        let texts = AccountFormsTests.strings(in: AboutView())
        #expect(texts.contains(Copy.aboutLicence))
        #expect(!texts.contains { $0.contains("App Store") || $0.contains("price") }, "\(texts)")
        #expect(
            Set(AboutPanel.links.map(\.url.absoluteString)) == [
                "https://www.gnu.org/licenses/gpl-3.0.html",
                "https://github.com/lifeofguenter/xippi", "https://xippi.eu",
                "https://xippi.eu/privacy", "https://xippi.eu/terms",
            ])
        let notices = Acknowledgements.libraries.map(\.notice).joined(separator: "\n")
        #expect(notices.contains("Copyright (C) 2015-2025 Gwendal Roué"))
        #expect(notices.contains("The above copyright notice and this permission notice shall be"))
        #expect(notices.contains("Copyright (c) 2011, The WebRTC project authors."))
        #expect(notices.contains("Redistributions in binary form must reproduce"))
        #expect(AboutPanel.copyright == "Copyright © 2026 Günter Grodotzki")
        AboutPanel.show()
        defer { NSApp.windows.first { $0.identifier == AboutPanel.identifier }?.close() }
        try await Task.sleep(for: .milliseconds(300))
        let window = try #require(
            NSApp.windows.first { $0.identifier == AboutPanel.identifier && $0.isVisible })
        #expect(window.frame.width >= 480, "\(window.frame)")
        #expect(window.frame.height >= 400, "\(window.frame)")
    }

    /// The signed app may use the data protection keychain, where passwords are kept: without
    /// a keychain access group every save failed ("Password not saved"). An unsigned build (CI)
    /// has no entitlements to check.
    @Test(.enabled(if: Self.entitlement("com.apple.application-identifier") != nil))
    func theSignedAppHasItsKeychainGroup() throws {
        let groups = try #require(Self.entitlement("keychain-access-groups") as? [String])
        let app = try #require(Self.entitlement("com.apple.application-identifier") as? String)
        #expect(groups.contains(app))
        #expect(app.hasSuffix(".eu.xippi.Xippi"))
    }

    nonisolated static func entitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }
}
