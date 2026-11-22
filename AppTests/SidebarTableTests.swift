import AppKit
import Testing

@testable import Xippi
@testable import XippiStore

/// The chat list's table stays in step with its rows. Switching between All and Unread crashed
/// when AppKit asked for a row the list no longer had: the table applied the changes to a row
/// count it had not read yet, or a newer list arrived while one was being applied.
@MainActor @Suite struct SidebarTableTests {
    static func chat(_ id: Int64, unread: Int = 0) -> SidebarRow {
        let record = ChatRecord(
            id: id, accountID: 1, jid: "chat\(id)@example.org", kind: .direct,
            name: "Chat \(id)", pinned: false, muted: false, notify: .all, draft: nil,
            encryption: .none, nick: nil, password: nil, autojoin: false, lastActivity: nil,
            unreadCount: unread, mentionCount: 0, lastReadMessageID: nil, avatarHash: nil)
        return .chat(
            ChatListItem(
                id: id, chat: record, accountJID: "me@example.org", lastMessage: nil),
            stateLabel: nil, showsDraft: false)
    }

    /// The four chats of the crash, under All and under Unread.
    static let all: [SidebarRow] = [
        .header("Chats"), chat(1, unread: 24), chat(2), chat(3, unread: 37), chat(4),
    ]
    static let unread: [SidebarRow] = [.header("Chats"), chat(1, unread: 24), chat(3, unread: 37)]

    @MainActor struct Fixture {
        let controller: SidebarTableController
        let table: NSTableView
        let scrollView: NSScrollView

        /// Shows the rows, lays the table out as a window would, and checks every row.
        func show(_ rows: [SidebarRow]) {
            controller.show(rows, selection: nil)
            scrollView.layoutSubtreeIfNeeded()
            table.tile()
            #expect(table.numberOfRows == rows.count)
            for row in 0..<table.numberOfRows {
                _ = controller.tableView(table, heightOfRow: row)
                _ = controller.tableView(table, isGroupRow: row)
            }
        }
    }

    func fixture() throws -> Fixture {
        let model = try #require(DebugSnapshot.model, "the test host's model")
        let controller = SidebarTableController(model: model, sheets: ChatSheets())
        let scrollView = controller.makeScrollView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let table = try #require(scrollView.documentView as? NSTableView)
        return Fixture(controller: controller, table: table, scrollView: scrollView)
    }

    /// The crash: the list loads, and the filter changes before the table has read it.
    @Test func aFilterChangeRightAfterTheFirstLoadKeepsTheTableInStep() throws {
        let fixture = try fixture()
        fixture.controller.show(Self.all, selection: nil)
        fixture.show(Self.unread)
        fixture.show(Self.all)
    }

    @Test func switchingAllAndUnreadBackAndForthKeepsTheTableInStep() throws {
        let fixture = try fixture()
        for _ in 0..<5 {
            fixture.show(Self.all)
            fixture.show(Self.unread)
        }
        fixture.show([])
        fixture.show(Self.all)
    }

    /// The rows keep clear of the search and account bars through the content insets alone,
    /// which AppKit applies to the scroller's thumb too: scroller insets on top counted the
    /// bars twice, so the thumb started half way down and never reached the end.
    @Test func theBarsAreCountedOnceForTheScroller() throws {
        let fixture = try fixture()
        fixture.controller.setInsets(top: 80, bottom: 50)
        #expect(fixture.scrollView.contentInsets.top == 80)
        #expect(fixture.scrollView.contentInsets.bottom == 50)
        #expect(fixture.scrollView.scrollerInsets.top == 0)
        #expect(fixture.scrollView.scrollerInsets.bottom == 0)
    }

    /// A row past the end of the list gets an empty answer, never a crash.
    @Test func aRowPastTheEndAnswersEmpty() throws {
        let fixture = try fixture()
        fixture.show(Self.unread)
        let past = Self.unread.count + 5
        #expect(fixture.controller.tableView(fixture.table, isGroupRow: past) == false)
        #expect(fixture.controller.tableView(fixture.table, shouldSelectRow: past) == false)
        #expect(fixture.controller.tableView(fixture.table, viewFor: nil, row: past) == nil)
        #expect(fixture.controller.tableView(fixture.table, heightOfRow: past) > 0)
    }

    /// A chat's row is as tall with unread messages as without: it grew when its badge came
    /// and shrank when the chat was read.
    @Test func aRowKeepsItsHeightWithOrWithoutTheBadge() throws {
        let fixture = try fixture()
        fixture.show([Self.chat(1, unread: 5), Self.chat(2)])
        let withBadge = fixture.controller.tableView(fixture.table, heightOfRow: 0)
        let without = fixture.controller.tableView(fixture.table, heightOfRow: 1)
        #expect(withBadge == without)
    }
}
