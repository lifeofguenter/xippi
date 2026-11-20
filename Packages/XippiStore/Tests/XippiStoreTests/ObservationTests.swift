import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite(.timeLimit(.minutes(1))) struct ObservationTests {
    @Test func chatListObservationEmitsOnInsert() async throws {
        let f = try StoreFixture()
        var updates = f.db.chatListObservation().values(in: f.db.reader).makeAsyncIterator()

        let initial = try #require(try await updates.next())
        #expect(
            initial.map(\.id).sorted() == [f.bobChatID, f.roomChatID, f.otherRoomChatID].sorted())
        #expect(initial.allSatisfy { $0.lastMessage == nil })

        var mention = f.fromBob("are you there?", at: 50, originID: "o1")
        mention.mentionsMe = true
        let id = try f.db.upsertIncoming(mention).id()

        let next = try #require(try await updates.next())
        let bob = try #require(next.first)
        #expect(bob.id == f.bobChatID)
        #expect(bob.accountJID == StoreFixture.ownJID)
        #expect(bob.chat.unreadCount == 1)
        #expect(bob.chat.mentionCount == 1)
        #expect(bob.lastMessage?.messageID == id)
        #expect(bob.lastMessage?.body == "are you there?")
        #expect(bob.lastMessage?.senderJID == "bob@x/phone")
        #expect(bob.lastMessage?.timestamp == StoreFixture.at(50))
    }

    @Test func chatListOrdersPinnedThenActivity() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.fromBob("old", at: 1, originID: "o1"))
        _ = try f.db.upsertIncoming(
            f.inRoom("new", nick: "carol", occupantID: "c", at: 2, originID: "o2"))
        var room = try f.chat(f.otherRoomChatID)
        room.pinned = true
        try f.db.updateChat(room)

        let items = try f.db.reader.read { try AppDatabase.fetchChatList($0) }
        #expect(items.map(\.id) == [f.otherRoomChatID, f.roomChatID, f.bobChatID])
        #expect(items.first?.accountJID == "other@y")
    }

    @Test func transcriptObservationCarriesReactionsAndAttachments() async throws {
        let f = try StoreFixture()
        var file = f.fromBob(nil, at: 1, originID: "m1", stanzaID: "m1")
        file.kind = .file
        file.attachments = [AttachmentDraft(remoteURL: "https://x/a.jpg", mimeType: "image/jpeg")]
        let fileID = try f.db.upsertIncoming(file).id()
        let textID = try f.db.upsertIncoming(f.fromBob("two", at: 2, originID: "m2")).id()
        _ = try f.db.upsertIncoming(f.fromBob("three", at: 3, originID: "m3"))

        var updates = f.db.transcriptObservation(chatID: f.bobChatID, limit: 2).values(
            in: f.db.reader
        )
        .makeAsyncIterator()
        let initial = try #require(try await updates.next())
        #expect(initial.map(\.message.body) == ["two", "three"])

        var reaction = f.fromBob(nil, at: 4, originID: "r1")
        reaction.reactions = ReactionUpdate(targetID: "m2", emojis: ["👍"])
        #expect(try f.db.upsertIncoming(reaction) == .merged(textID))

        let next = try #require(try await updates.next())
        #expect(next.first?.message.id == textID)
        #expect(next.first?.reactions.map(\.emojis) == [["👍"]])

        let decorated = try f.db.transcriptItems(
            for: try f.db.page(chatID: f.bobChatID, before: nil, limit: 3))
        #expect(decorated.first?.message.id == fileID)
        #expect(decorated.first?.attachments.map(\.remoteURL) == ["https://x/a.jpg"])
    }
}
