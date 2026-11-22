import AppKit
import Foundation
import Testing

@testable import Xippi
@testable import XippiStore

/// The inspector's width, the chat backgrounds and the transcript's scroll view.
@MainActor @Suite struct InspectorRulesTests {
    /// The inspector can be dragged wider or narrower, never below a width its text fits in,
    /// never to nothing, never wider than the bound.
    @Test func theInspectorWidthStaysWithinItsBounds() {
        #expect(InspectorWidth.range.lowerBound >= 280)
        #expect(InspectorWidth.range.contains(InspectorWidth.ideal))
        #expect(InspectorWidth.clamped(0) == InspectorWidth.range.lowerBound)
        #expect(InspectorWidth.clamped(10_000) == InspectorWidth.range.upperBound)
        #expect(InspectorWidth.clamped(.nan) == InspectorWidth.ideal)
        // Dragging the edge left makes it wider, right makes it narrower.
        #expect(InspectorWidth.dragged(from: 340, by: -40) == 380)
        #expect(InspectorWidth.dragged(from: 340, by: 40) == 300)
        #expect(InspectorWidth.dragged(from: 340, by: 400) == InspectorWidth.range.lowerBound)
    }

    /// A chat that never chose a background shows confetti; a choice is the chat's own and
    /// reaches the open chat's settings.
    @Test func confettiIsTheDefaultAndAChoiceIsKept() {
        #expect(ChatBackdrop.resolved(nil) == .confetti)
        #expect(ChatBackdrop.resolved(.plain) == .plain)
        let chat = ChatRecord(
            id: 7, accountID: 1, jid: "bob@example.org", kind: .direct, name: nil, pinned: false,
            muted: false, notify: .all, draft: nil, encryption: .none, nick: nil, password: nil,
            autojoin: false, lastActivity: nil, unreadCount: 0, mentionCount: 0,
            lastReadMessageID: nil, avatarHash: nil, background: .plain)
        #expect(OpenChatSettings(chat, id: 7).background == .plain)
        #expect(ChatBackground.allCases.map(\.title).allSatisfy { !$0.isEmpty })
    }

    /// The transcript draws no background of its own, so the chat's background shows through.
    /// Its scroller keeps clear of the toolbar and the composer through the content insets
    /// alone: scroller insets on top counted them twice, so the thumb started far below the
    /// toolbar and stopped half way down.
    @Test func theTranscriptShowsTheChatsBackground() throws {
        let model = try #require(DebugSnapshot.model)
        let transcript = TranscriptController(
            database: model.database, commands: model.commands, timing: model.openTiming)
        let scrollView = transcript.makeScrollView()
        #expect(!scrollView.drawsBackground)
        let insets = TranscriptController.scrollerInsets(
            NSEdgeInsets(top: 52, left: 0, bottom: 80, right: 0))
        #expect(insets.top == 0)
        #expect(insets.bottom == 0)
    }

    /// A room shows its Encryption heading only with something under it: before the room's
    /// setup is known and with OMEMO off, nothing (an empty heading showed).
    @Test func aRoomsEncryptionSectionIsNeverEmpty() {
        #expect(!RoomInspector.showsEncryption(allowsOMEMO: false, known: false, encrypted: false))
        #expect(RoomInspector.showsEncryption(allowsOMEMO: false, known: false, encrypted: true))
        #expect(RoomInspector.showsEncryption(allowsOMEMO: false, known: true, encrypted: false))
        #expect(RoomInspector.showsEncryption(allowsOMEMO: true, known: true, encrypted: false))
    }

    /// The inspector's tabs, in Messages' order, and Info first.
    @Test func theInspectorOpensOnInfo() throws {
        #expect(InspectorTab.allCases == [.info, .background, .media])
        #expect(InspectorTab.allCases.allSatisfy { !$0.title.isEmpty })
    }

    /// The inspector is about the open chat: with none open (one just closed) it is not shown,
    /// where it showed "No chat selected" a word per line beside an empty chat area.
    @Test func theInspectorShowsOnlyWithAChatOpen() {
        #expect(ChatDetailView.showsInspector(visible: true, hasChat: true))
        #expect(!ChatDetailView.showsInspector(visible: true, hasChat: false))
        #expect(!ChatDetailView.showsInspector(visible: false, hasChat: true))
    }

    /// A room's messages show each sender's picture by their nick; a direct chat's the chat's;
    /// our own none. Rooms showed none at all.
    @Test func aRoomsMessagesShowTheSendersPicture() {
        let occupants = ["carol": "c1"]
        #expect(
            TranscriptController.avatarHash(
                outgoing: false, isRoom: true, chatHash: "room", senderNick: "carol",
                occupants: occupants) == "c1")
        #expect(
            TranscriptController.avatarHash(
                outgoing: false, isRoom: true, chatHash: "room", senderNick: "dave",
                occupants: occupants) == nil)
        #expect(
            TranscriptController.avatarHash(
                outgoing: false, isRoom: false, chatHash: "bob", senderNick: nil,
                occupants: occupants) == "bob")
        #expect(
            TranscriptController.avatarHash(
                outgoing: true, isRoom: true, chatHash: "room", senderNick: "carol",
                occupants: occupants) == nil)
    }

    /// The sidebar cannot be hidden: a drag past its narrowest width and the View menu's Hide
    /// Sidebar folded the chat list away (into a strip, before that was taken out).
    @Test func theSidebarCannotBeHidden() async throws {
        let content = NSViewController()
        content.view = NSView()
        let detail = NSViewController()
        detail.view = NSView()
        let sidebar = NSSplitViewItem(sidebarWithViewController: content)
        let controller = NSSplitViewController()
        controller.addSplitViewItem(sidebar)
        controller.addSplitViewItem(NSSplitViewItem(viewController: detail))
        let pin = SidebarPinView()
        pin.hold(controller)
        #expect(!sidebar.canCollapse)
        // SwiftUI makes it collapsible again as it updates the split view: put back at once.
        sidebar.canCollapse = true
        #expect(!sidebar.canCollapse)
        sidebar.isCollapsed = true
        #expect(!sidebar.isCollapsed)
        #expect(SidebarWidth.minimum >= 250)
        // No menu item shows or hides it, not even a hidden one for a shortcut: SwiftUI kept a
        // Toggle Sidebar on Control-Command-S that found nothing to toggle.
        let menu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        func toggles() -> [String] {
            items(menu).filter {
                $0.title.localizedCaseInsensitiveContains("sidebar")
                    || $0.action == #selector(NSSplitViewController.toggleSidebar(_:))
            }.map { "\($0.title) in \($0.menu?.title ?? "?")" }
        }
        #expect(items(menu).contains { $0.title == Copy.goToChat })
        #expect(toggles().isEmpty)
        // SwiftUI builds the menus again when a command changes, as Show Inspector does.
        let model = try #require(DebugSnapshot.model)
        for _ in 0..<2 {
            model.inspectorVisible.toggle()
            try await Task.sleep(for: .milliseconds(400))
            #expect(toggles().isEmpty)
        }
    }
}
