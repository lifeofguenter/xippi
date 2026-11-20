import Foundation
import GRDB
import Testing

@testable import XippiStore

/// The repositories the session writes through: roster, bookmarks, avatars and the chat
/// columns they change, and bounces scoped to their sender's chat.
@Suite struct SessionRepositoryTests {
    static func item(_ jid: String, _ subscription: String = "both", accountID: Int64 = 0)
        -> RosterItemRecord
    {
        RosterItemRecord(
            accountID: accountID, jid: jid, name: nil, subscription: subscription, ask: nil,
            approved: false, groups: ["Friends"])
    }

    // MARK: Roster

    @Test func rosterIsReplacedWithItsVersion() throws {
        let f = try StoreFixture()
        try f.db.replaceRoster(
            accountID: f.accountID, with: [Self.item("bob@x"), Self.item("carol@x", "to")],
            version: "v1")
        try f.db.replaceRoster(
            accountID: f.otherAccountID, with: [Self.item("dave@y")], version: "o1")

        try f.db.replaceRoster(
            accountID: f.accountID, with: [Self.item("carol@x"), Self.item("carol@x", "from")],
            version: "v2")

        let items = try f.db.rosterItems(accountID: f.accountID)
        #expect(items.map(\.jid) == ["carol@x"])
        #expect(items.first?.subscription == "from", "the last of a JID wins")
        #expect(items.first?.groups == ["Friends"])
        #expect(items.first?.accountID == f.accountID)
        #expect(try f.db.account(id: f.accountID)?.rosterVersion == "v2")
        #expect(try f.db.rosterItems(accountID: f.otherAccountID).map(\.jid) == ["dave@y"])
        #expect(try f.db.account(id: f.otherAccountID)?.rosterVersion == "o1")
    }

    @Test func rosterPushChangesOneItemAndTheVersion() throws {
        let f = try StoreFixture()
        try f.db.replaceRoster(accountID: f.accountID, with: [Self.item("bob@x")], version: "v1")

        try f.db.applyRosterPush(
            accountID: f.accountID, jid: "carol@x", item: Self.item("carol@x", "none"),
            version: "v2")
        try f.db.applyRosterPush(
            accountID: f.accountID, jid: "bob@x", item: Self.item("bob@x", "to"), version: nil)
        #expect(try f.db.account(id: f.accountID)?.rosterVersion == "v2", "no version, no change")
        #expect(
            try f.db.rosterItems(accountID: f.accountID).map { "\($0.jid) \($0.subscription)" }
                == ["bob@x to", "carol@x none"])

        try f.db.applyRosterPush(accountID: f.accountID, jid: "bob@x", item: nil, version: "v3")
        #expect(try f.db.rosterItems(accountID: f.accountID).map(\.jid) == ["carol@x"])
        #expect(try f.db.account(id: f.accountID)?.rosterVersion == "v3")
    }

    // MARK: Bookmarks and room settings

    static func bookmark(_ room: String, autojoin: Bool, accountID: Int64) -> BookmarkRecord {
        BookmarkRecord(
            accountID: accountID, roomJID: room, name: "Room", autojoin: autojoin, nick: "me",
            password: nil)
    }

    @Test func bookmarksAreReplacedStoredAndDeleted() throws {
        let f = try StoreFixture()
        try f.db.replaceBookmarks(
            accountID: f.accountID,
            with: [Self.bookmark("a@c.x", autojoin: true, accountID: f.accountID)])
        try f.db.replaceBookmarks(
            accountID: f.otherAccountID,
            with: [Self.bookmark("z@c.y", autojoin: false, accountID: f.otherAccountID)])

        try f.db.storeBookmark(Self.bookmark("a@c.x", autojoin: false, accountID: f.accountID))
        try f.db.storeBookmark(Self.bookmark("b@c.x", autojoin: true, accountID: f.accountID))
        #expect(try f.db.bookmarks(accountID: f.accountID).map(\.roomJID) == ["a@c.x", "b@c.x"])
        #expect(try f.db.bookmarks(accountID: f.accountID).first?.autojoin == false)

        try f.db.deleteBookmark(accountID: f.accountID, roomJID: "a@c.x")
        try f.db.replaceBookmarks(accountID: f.accountID, with: [])
        #expect(try f.db.bookmarks(accountID: f.accountID).isEmpty)
        #expect(try f.db.bookmarks(accountID: f.otherAccountID).map(\.roomJID) == ["z@c.y"])
    }

    /// v5 (Task 12): a change made here waits for the server as a pending row, and a room left
    /// here waits as a removed row until the server retracted its bookmark.
    @Test func pendingAndRemovedBookmarksAreKept() throws {
        let f = try StoreFixture()
        var pending = Self.bookmark("a@c.x", autojoin: true, accountID: f.accountID)
        pending.pending = true
        var removed = Self.bookmark("b@c.x", autojoin: false, accountID: f.accountID)
        removed.pending = true
        removed.removed = true
        try f.db.replaceBookmarks(
            accountID: f.accountID,
            with: [
                pending, removed, Self.bookmark("c@c.x", autojoin: true, accountID: f.accountID),
            ])

        #expect(
            try f.db.bookmarks(accountID: f.accountID).map(\.roomJID) == ["a@c.x", "c@c.x"],
            "a removed row is no bookmark")
        let rows = try f.db.bookmarkRows(accountID: f.accountID)
        #expect(rows.map(\.roomJID) == ["a@c.x", "b@c.x", "c@c.x"])
        #expect(rows.map(\.pending) == [true, true, false])
        #expect(rows.map(\.removed) == [false, true, false])
    }

    @Test func roomSettingsChangeOnlyTheirColumns() throws {
        let f = try StoreFixture()
        var stale = try f.chat(f.roomChatID)
        stale.draft = "typing"
        stale.pinned = true
        try f.db.updateChat(stale)

        try f.db.applyBookmarkToRoom(
            chatID: f.roomChatID, name: "Bookmarked", nick: "me", password: "pw", autojoin: true)
        try f.db.applyBookmarkToRoom(
            chatID: f.bobChatID, name: "Not a room", nick: "x", password: nil, autojoin: true)
        var room = try f.chat(f.roomChatID)
        #expect(room.name == "Bookmarked")
        #expect(room.nick == "me")
        #expect(room.password == "pw")
        #expect(room.autojoin)
        #expect(room.draft == "typing")
        #expect(room.pinned)
        #expect(try f.chat(f.bobChatID).autojoin == false, "a direct chat is no room")

        room.name = "Mine"
        try f.db.updateChat(room)
        try f.db.applyBookmarkToRoom(
            chatID: f.roomChatID, name: "Other", nick: "me", password: nil, autojoin: true)
        #expect(
            try f.chat(f.roomChatID).name == "Mine", "the bookmark name only fills an empty one")

        try f.db.setRoomAutojoin(accountID: f.accountID, jid: StoreFixture.roomJID, false)
        #expect(try f.chat(f.roomChatID).autojoin == false)
        #expect(try f.chat(f.otherRoomChatID).autojoin == false)

        try f.db.setRoomJoinSettings(
            chatID: f.roomChatID, nick: "me2", password: nil, autojoin: true)
        room = try f.chat(f.roomChatID)
        #expect(room.nick == "me2")
        #expect(room.password == nil)
        #expect(room.autojoin)
        #expect(room.draft == "typing")
    }

    // MARK: Avatars

    @Test func avatarsAreStoredShownAndCleanedUp() throws {
        let f = try StoreFixture()
        try f.db.storeAvatar(AvatarRecord(hash: "aa", fileName: "aa.png", byteSize: 10))
        try f.db.storeAvatar(AvatarRecord(hash: "bb", fileName: "bb.png", byteSize: 20))
        try f.db.storeAvatar(AvatarRecord(hash: "cc", fileName: "cc.png", byteSize: 30))
        try f.db.storeAvatar(AvatarRecord(hash: "aa", fileName: "aa.png", byteSize: 10))
        #expect(try f.db.avatarBytes() == 60)
        #expect(try f.db.avatar(hash: "bb")?.fileName == "bb.png")

        try f.db.setChatAvatar(accountID: f.accountID, jid: StoreFixture.bobJID, hash: "aa")
        try f.db.setChatAvatar(accountID: f.accountID, jid: "nobody@x", hash: "bb")
        #expect(try f.chat(f.bobChatID).avatarHash == "aa")

        let removed = try f.db.removeUnusedAvatars(keeping: ["cc"])

        #expect(removed.map(\.hash) == ["bb"])
        #expect(try f.db.avatar(hash: "bb") == nil)
        #expect(try f.db.avatarBytes() == 40)
        try f.db.setChatAvatar(accountID: f.accountID, jid: StoreFixture.bobJID, hash: nil)
        #expect(try f.chat(f.bobChatID).avatarHash == nil)
        #expect(try f.db.removeUnusedAvatars(keeping: []).map(\.hash) == ["aa", "cc"])
    }

    // MARK: Bounces

    @Test func aBounceCountsOnlyFromTheChatItNames() throws {
        let f = try StoreFixture()
        let toBob = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "o-bob",
                senderJID: StoreFixture.ownJID, body: "hi", timestamp: StoreFixture.at(1)))
        let toRoom = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "o-room",
                senderJID: StoreFixture.ownJID, body: "hi all", timestamp: StoreFixture.at(2)))
        try f.db.markSent(accountID: f.accountID, originID: "o-room")

        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o-bob", by: "mallory@evil", error: "no") == 0)
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o-room", by: "\(StoreFixture.roomJID)/mallory",
                error: "no") == 0, "an occupant names the room, not bob's chat")
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o-bob", by: StoreFixture.roomJID, error: "no")
                == 0)
        #expect(try f.db.message(id: toBob)?.state == .pending)

        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o-bob", by: "bob@x/phone", error: "Gone") == 1)
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o-room", by: StoreFixture.roomJID,
                error: "Kicked") == 1)
        #expect(try f.db.message(id: toBob)?.errorText == "Gone")
        #expect(try f.db.message(id: toRoom)?.state == .failed)
    }
}
