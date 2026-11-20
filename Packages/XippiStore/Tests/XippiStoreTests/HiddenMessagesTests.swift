import Foundation
import GRDB
import Testing

@testable import XippiStore

/// Messages stored before a participant was ignored (R72, re-review N1) leave every place that
/// lists them: the chat list preview, search, shared media and the unread and mention counts.
/// A real JID reaches messages that carry only an occupant id through the pairings the rooms
/// showed (re-review C1).
@Suite struct HiddenMessagesTests {
    static let room = StoreFixture.roomJID

    static func ignore(
        _ f: StoreFixture, _ kind: IgnoredParticipant.Kind, _ value: String,
        room: String? = room
    ) throws {
        try f.db.ignore(
            IgnoredParticipant(
                accountID: f.accountID, room: room, kind: kind, value: value, label: "spam",
                createdAt: StoreFixture.at(0)))
    }

    static func preview(_ f: StoreFixture, chatID: Int64) throws -> String? {
        try f.db.reader.read { db in try AppDatabase.fetchChatList(db) }
            .first { $0.id == chatID }?.lastMessage?.body
    }

    @Test func theChatListPreviewSkipsIgnoredMessages() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(
            f.inRoom("hello all", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-1", at: 2))
        #expect(try Self.preview(f, chatID: f.roomChatID) == "buy now")

        try Self.ignore(f, .occupantID, "occ-1")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello all")

        try f.db.unignore(
            accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-1")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "buy now")
    }

    @Test func searchSkipsIgnoredMessages() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(
            f.inRoom("buy cheap", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-1", at: 2))
        try Self.ignore(f, .nick, "spam")
        #expect(try f.db.search("buy").map(\.body) == ["buy cheap"])
    }

    @Test func unreadAndMentionCountsDropForIgnoredMessages() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        var mention = f.inRoom("me: buy now", nick: "spam", occupantID: "occ-1", at: 2)
        mention.mentionsMe = true
        _ = try f.db.upsertIncoming(mention)
        _ = try f.db.upsertIncoming(f.inRoom("buy again", nick: "spam", occupantID: "occ-1", at: 3))
        #expect(try f.chat(f.roomChatID).unreadCount == 3)
        #expect(try f.chat(f.roomChatID).mentionCount == 1)

        try Self.ignore(f, .occupantID, "occ-1")
        #expect(try f.chat(f.roomChatID).unreadCount == 1)
        #expect(try f.chat(f.roomChatID).mentionCount == 0)

        try f.db.unignore(
            accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-1")
        #expect(try f.chat(f.roomChatID).unreadCount == 3)
        #expect(try f.chat(f.roomChatID).mentionCount == 1)
    }

    /// Someone ignored by real JID, whose messages carry only the occupant id the room stamped:
    /// the pairing the room showed earlier (presence, member list) links the two.
    @Test func aRealJIDReachesMessagesThroughTheRoomsPairings() throws {
        let f = try StoreFixture()
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x/laptop")], at: StoreFixture.at(0))
        #expect(
            try f.db.pairedRealJID(
                accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-9")
                == "spam@x")
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-9", at: 2))

        try Self.ignore(f, .realJID, "spam@x", room: nil)
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")

        // A pairing learned after the block reaches the messages it names too.
        _ = try f.db.upsertIncoming(f.inRoom("more", nick: "spam2", occupantID: "occ-7", at: 3))
        #expect(try Self.preview(f, chatID: f.roomChatID) == "more")
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-7", realJID: "spam@x")], at: StoreFixture.at(4))
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")
    }

    /// The transcript knows which rows are hidden, and leaves them out.
    @Test func transcriptItemsLeaveHiddenRowsOut() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-9", at: 2))
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x")], at: StoreFixture.at(0))
        try Self.ignore(f, .realJID, "spam@x", room: nil)

        let items = try f.db.transcriptItems(for: try f.messages(chatID: f.roomChatID))
        #expect(items.map(\.hidden) == [false, true])
        let list = try f.db.ignoreList(accountID: f.accountID)
        #expect(list.visible(items, room: Self.room, kind: .room).map(\.message.body) == ["hello"])
    }

    /// m-13: a message whose check ran before a Block and whose store runs after it is
    /// stored hidden, not counted, and not the room's newest.
    @Test func aMessageStoredAfterABlockIsStoredHidden() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        try Self.ignore(f, .occupantID, "occ-1")
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x")], at: StoreFixture.at(0))
        try Self.ignore(f, .realJID, "spam@x", room: nil)

        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-1", at: 2))
        _ = try f.db.upsertIncoming(f.inRoom("buy too", nick: "spam2", occupantID: "occ-9", at: 3))

        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")
        #expect(try f.chat(f.roomChatID).unreadCount == 1)
        #expect(try f.chat(f.roomChatID).lastActivity == StoreFixture.at(1))
        let items = try f.db.transcriptItems(for: try f.messages(chatID: f.roomChatID))
        #expect(items.map(\.hidden) == [false, true, true])
    }

    /// m-16: two entries cover one row; removing one keeps it hidden, removing both shows it.
    @Test func aRowCoveredTwiceStaysHiddenUntilBothGo() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-1", at: 2))
        try Self.ignore(f, .occupantID, "occ-1")
        try Self.ignore(f, .nick, "spam")

        try f.db.unignore(
            accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-1")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")
        try f.db.unignore(accountID: f.accountID, room: Self.room, kind: .nick, value: "spam")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "buy now")
    }

    /// m-16: a row hidden only through a pairing stays hidden while its real JID is ignored,
    /// and comes back when that JID goes.
    @Test func aRowHiddenThroughAPairingFollowsItsRealJID() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-9", at: 2))
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x")], at: StoreFixture.at(0))
        try Self.ignore(f, .realJID, "spam@x", room: nil)
        try Self.ignore(f, .occupantID, "occ-other")

        // Another entry going re-checks the hidden rows: the pairing still holds this one.
        try f.db.unignore(
            accountID: f.accountID, room: Self.room, kind: .occupantID, value: "occ-other")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")
        try f.db.unignore(accountID: f.accountID, realJID: "spam@x")
        #expect(try Self.preview(f, chatID: f.roomChatID) == "buy now")
    }

    /// m-16: a pairing that moves off an ignored real JID shows its rows again.
    @Test func aPairingMovingOffAnIgnoredJIDShowsItsRows() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.inRoom("hello", nick: "friend", occupantID: "occ-2", at: 1))
        _ = try f.db.upsertIncoming(f.inRoom("buy now", nick: "spam", occupantID: "occ-9", at: 2))
        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "spam@x")], at: StoreFixture.at(0))
        try Self.ignore(f, .realJID, "spam@x", room: nil)
        #expect(try Self.preview(f, chatID: f.roomChatID) == "hello")

        try f.db.rememberOccupants(
            accountID: f.accountID, room: Self.room, kind: .occupantID,
            pairs: [(value: "occ-9", realJID: "someone@x")], at: StoreFixture.at(5))
        #expect(try Self.preview(f, chatID: f.roomChatID) == "buy now")
    }

    /// Another account's messages in the same room are not touched.
    @Test func otherAccountsKeepTheirMessages() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(
            f.inRoom(
                "buy now", nick: "spam", occupantID: "occ-1", chatID: f.otherRoomChatID,
                accountID: f.otherAccountID, at: 1))
        try Self.ignore(f, .occupantID, "occ-1")
        #expect(try Self.preview(f, chatID: f.otherRoomChatID) == "buy now")
    }
}
