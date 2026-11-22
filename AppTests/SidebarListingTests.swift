import AppKit
import Foundation
import Testing

@testable import Xippi
@testable import XippiStore

/// Which chats the sidebar lists, and the close button on a room's row.
@MainActor @Suite struct SidebarListingTests {
    static func item(
        _ id: Int64, kind: ChatKind = .direct, closed: Bool = false, hasMessage: Bool = true,
        unread: Int = 0
    ) -> ChatListItem {
        let chat = ChatRecord(
            id: id, accountID: 1, jid: "chat\(id)@example.org/nick", kind: kind, name: "Chat \(id)",
            pinned: false, muted: false, notify: .all, draft: nil, encryption: .none, nick: nil,
            password: nil, autojoin: false, lastActivity: nil, unreadCount: unread,
            mentionCount: 0, lastReadMessageID: nil, avatarHash: nil, closed: closed)
        let preview =
            hasMessage
            ? MessagePreview(
                messageID: id, direction: .incoming, senderJID: nil, senderNick: nil, body: "hi",
                kind: .text, timestamp: Date(), retracted: false) : nil
        return ChatListItem(id: id, chat: chat, accountJID: "me@example.org", lastMessage: preview)
    }

    static func listed(_ items: [ChatListItem], selection: Int64? = nil) -> [Int64] {
        SidebarFilter.listed(items, filter: .all, selection: selection).map(\.id)
    }

    /// A closed chat leaves the list; while it is the open chat it stays.
    @Test func aClosedChatIsNotListedUnlessOpen() {
        let items = [Self.item(1), Self.item(2, kind: .room, closed: true)]
        #expect(Self.listed(items) == [1])
        #expect(Self.listed(items, selection: 2) == [1, 2])
    }

    /// A room's private chat shows once it has a message, not when it is merely made.
    @Test func aPrivateChatShowsOnceItHasAMessage() {
        let empty = Self.item(3, kind: .roomPrivate, hasMessage: false)
        let talking = Self.item(4, kind: .roomPrivate)
        #expect(Self.listed([empty, talking]) == [4])
        #expect(Self.listed([empty, talking], selection: 3) == [3, 4])
        // An empty direct chat is still listed: only private chats wait for a message.
        #expect(Self.listed([Self.item(5, hasMessage: false)]) == [5])
    }

    /// The filter still applies to what is listed.
    @Test func theFilterStillApplies() {
        let items = [Self.item(1, unread: 2), Self.item(2)]
        #expect(SidebarFilter.listed(items, filter: .unread, selection: nil).map(\.id) == [1])
    }

    /// The open chat keeps to the filter like any other: a room that is open while People is
    /// chosen is not listed there. Only the chat opened under the filter stays where the
    /// filter would now leave it out, as a chat read since it was opened from Unread.
    @Test func theOpenChatKeepsToTheFilter() {
        let items = [Self.item(1), Self.item(2, kind: .room)]
        func listed(_ filter: SidebarFilter, kept: Int64? = nil) -> [Int64] {
            SidebarFilter.listed(items, filter: filter, selection: 2, kept: kept).map(\.id)
        }
        #expect(listed(.people) == [1])
        #expect(listed(.groups) == [2])
        #expect(listed(.unread).isEmpty)
        #expect(listed(.all) == [1, 2])
        #expect(listed(.unread, kept: 2) == [2])
    }

    /// A chat is kept under the filter it was opened under; choosing another filter lets that
    /// filter decide, until a chat is opened under it.
    @Test func anotherFilterDecidesForTheOpenChat() throws {
        let model = try #require(DebugSnapshot.model)
        let before = (filter: model.sidebarFilter, selection: model.selection)
        defer {
            model.sidebarFilter = before.filter
            model.selection = before.selection
        }
        model.sidebarFilter = .unread
        model.selection = 987_654
        #expect(model.keptInList == 987_654)
        model.sidebarFilter = .unread
        #expect(model.keptInList == 987_654)
        model.sidebarFilter = .people
        #expect(model.keptInList == nil)
        model.sidebarFilter = .unread
        #expect(model.keptInList == nil)
        model.selection = 987_655
        #expect(model.keptInList == 987_655)
    }

    /// The close button shows only on a room's row that says it is not joined, sits at the
    /// end of that line inside the row, and closes the chat.
    @Test func theCloseButtonIsOnANotJoinedRoomsRow() throws {
        let cell = ChatRowCell()
        cell.frame = NSRect(x: 0, y: 0, width: 280, height: 74)
        var closed = false
        cell.onClose = { closed = true }
        cell.configure(Self.item(1), stateLabel: nil, showsDraft: false, avatar: nil)
        #expect(cell.closeButton.isHidden)
        cell.configure(
            Self.item(2, kind: .room), stateLabel: "Not in room", showsDraft: false, avatar: nil)
        cell.layoutSubtreeIfNeeded()
        #expect(!cell.closeButton.isHidden)
        #expect(cell.bounds.contains(cell.closeButton.frame))
        #expect(cell.closeButton.frame.maxX <= cell.bounds.maxX - SidebarMetrics.trailing)
        cell.closeButton.performClick(nil)
        #expect(closed)
    }

    /// The sidebar's scroller shows only while the list scrolls, as the system's lists do.
    @Test func theSidebarsScrollerHidesWhenIdle() throws {
        let model = try #require(DebugSnapshot.model)
        let scrollView = SidebarTableController(model: model, sheets: ChatSheets()).makeScrollView()
        #expect(scrollView.autohidesScrollers)
    }
}
