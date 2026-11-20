import Foundation
import Testing

@testable import XippiStore

/// Ruling R72: someone blocked in a room or channel is ignored locally, per account, by the
/// strongest identity known: real JID, then occupant id (XEP-0421), then the MIX participant
/// id, else only the nickname in that room.
@Suite struct IgnoredParticipantTests {
    static let room = "lounge@conference.x"
    static let otherRoom = "other@conference.x"
    static let channel = "coven@mix.x"

    static func entry(
        _ kind: IgnoredParticipant.Kind, _ value: String, room: String? = room
    ) -> IgnoredParticipant {
        IgnoredParticipant(
            accountID: 1, room: kind == .realJID ? nil : room, kind: kind, value: value,
            label: "spam", createdAt: Date(timeIntervalSince1970: 0))
    }

    static func sender(
        room: String = room, kind: ChatKind = .room, jid: String? = nil, nick: String? = nil,
        occupantID: String? = nil, realJID: String? = nil
    ) -> IgnoreList.Sender {
        IgnoreList.Sender(
            room: room, kind: kind, senderJID: jid ?? "\(room)/\(nick ?? "spam")",
            senderNick: nick, occupantID: occupantID, realJID: realJID)
    }

    @Test func aRealJIDEntryCoversThatPersonInEveryRoom() {
        let list = IgnoreList([Self.entry(.realJID, "spammer@x")])
        #expect(list.covers(Self.sender(nick: "a", realJID: "spammer@x/laptop")))
        #expect(list.covers(Self.sender(room: Self.otherRoom, nick: "b", realJID: "spammer@x")))
        #expect(!list.covers(Self.sender(nick: "a", realJID: "friend@x")))
        #expect(!list.covers(Self.sender(nick: "a")))
    }

    /// The occupant id stays when the nick changes, and counts only in its own room.
    @Test func anOccupantIDEntryHoldsAcrossNicksInItsRoomOnly() {
        let list = IgnoreList([Self.entry(.occupantID, "occ-1")])
        #expect(list.covers(Self.sender(nick: "spam", occupantID: "occ-1")))
        #expect(list.covers(Self.sender(nick: "renamed", occupantID: "occ-1")))
        #expect(!list.covers(Self.sender(room: Self.otherRoom, nick: "spam", occupantID: "occ-1")))
        #expect(!list.covers(Self.sender(nick: "spam", occupantID: "occ-2")))
    }

    @Test func aParticipantIDEntryCoversTheChannelSendersAddress() {
        let list = IgnoreList([Self.entry(.participantID, "123456", room: Self.channel)])
        #expect(
            list.covers(
                Self.sender(
                    room: Self.channel, kind: .channel, jid: "\(Self.channel)/123456",
                    nick: "any name")))
        #expect(
            !list.covers(
                Self.sender(
                    room: Self.channel, kind: .channel, jid: "\(Self.channel)/654321",
                    nick: "any name")))
    }

    /// Only the nickname, only in that room: a new nick is someone else.
    @Test func aNickEntryCoversOnlyThatNickInThatRoom() {
        let list = IgnoreList([Self.entry(.nick, "spam")])
        #expect(list.covers(Self.sender(nick: "spam")))
        #expect(!list.covers(Self.sender(nick: "spam2")))
        #expect(!list.covers(Self.sender(room: Self.otherRoom, nick: "spam")))
    }

    /// Reactions name their reactor by occupant id or address: those of an ignored participant
    /// are hidden too.
    @Test func reactionsOfAnIgnoredParticipantAreCovered() {
        let list = IgnoreList([
            Self.entry(.occupantID, "occ-1"), Self.entry(.nick, "spam"),
            Self.entry(.participantID, "123456", room: Self.channel),
        ])
        #expect(list.coversReactor("occ-1", room: Self.room))
        #expect(list.coversReactor("\(Self.room)/spam", room: Self.room))
        #expect(list.coversReactor("\(Self.channel)/123456", room: Self.channel))
        #expect(!list.coversReactor("occ-1", room: Self.otherRoom))
        #expect(!list.coversReactor("\(Self.room)/friend", room: Self.room))
    }

    /// The transcript of a room hides an ignored participant's messages and their reactions on
    /// everyone else's; a 1:1 chat and the account's own messages are never hidden.
    @Test func theTranscriptHidesIgnoredMessagesAndReactions() {
        func item(_ id: Int64, nick: String, occupantID: String, outgoing: Bool = false)
            -> TranscriptItem
        {
            var message = MessageRecord.sample(accountID: 1, chatID: 1)
            message.id = id
            message.senderJID = "\(Self.room)/\(nick)"
            message.senderNick = nick
            message.occupantID = occupantID
            message.direction = outgoing ? .outgoing : .incoming
            return TranscriptItem(id: id, message: message, reactions: [], attachments: [])
        }
        var friend = item(1, nick: "friend", occupantID: "occ-2")
        friend.reactions = [
            ReactionRecord(messageID: 1, reactorKey: "occ-1", emojis: ["a"]),
            ReactionRecord(messageID: 1, reactorKey: "occ-3", emojis: ["b"]),
        ]
        let items = [
            friend, item(2, nick: "spam", occupantID: "occ-1"),
            item(3, nick: "me", occupantID: "occ-1", outgoing: true),
        ]
        let list = IgnoreList([Self.entry(.occupantID, "occ-1")])

        let shown = list.visible(items, room: Self.room, kind: .room)
        #expect(shown.map(\.id) == [1, 3])
        #expect(shown.first?.reactions.map(\.reactorKey) == ["occ-3"])
        #expect(list.visible(items, room: Self.room, kind: .direct) == items)
        #expect(IgnoreList([]).visible(items, room: Self.room, kind: .room) == items)
    }

    @Test func ignoringTwiceKeepsOneEntryAndUnignoringRemovesIt() throws {
        let f = try StoreFixture()
        var entry = Self.entry(.occupantID, "occ-1", room: StoreFixture.roomJID)
        entry.accountID = f.accountID
        try f.db.ignore(entry)
        try f.db.ignore(entry)
        #expect(try f.db.ignoredParticipants(accountID: f.accountID).count == 1)
        #expect(try f.db.ignoredParticipants(accountID: f.otherAccountID).isEmpty)
        #expect(
            try f.db.ignoreList(accountID: f.accountID).covers(
                IgnoreList.Sender(
                    room: StoreFixture.roomJID, kind: .room, senderJID: "\(StoreFixture.roomJID)/x",
                    senderNick: "x", occupantID: "occ-1", realJID: nil)))

        try f.db.unignore(
            accountID: f.accountID, room: StoreFixture.roomJID, kind: .occupantID, value: "occ-1")
        #expect(try f.db.ignoredParticipants(accountID: f.accountID).isEmpty)
    }

    /// Unblocking a real JID drops every entry that names it.
    @Test func unignoringARealJIDDropsItsEntry() throws {
        let f = try StoreFixture()
        var entry = Self.entry(.realJID, "spammer@x")
        entry.accountID = f.accountID
        try f.db.ignore(entry)
        try f.db.unignore(accountID: f.accountID, realJID: "spammer@x")
        #expect(try f.db.ignoredParticipants(accountID: f.accountID).isEmpty)
    }
}
