import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// The account's own reactions, read where the session stores them: under the bare JID in
/// direct chats, under the nick the room gave this join in rooms, and under our occupant id
/// in rooms that have them (I3).
@Suite struct OwnReactionTests {
    /// The room reflects our reaction with our occupant id: one reactor, not two, and a
    /// reaction from another device of ours counts as ours.
    @Test func inARoomWithOccupantIDsOursIsKeptOnce() async throws {
        let harness = try await RoomMessageTests.harness(
            trust: RoomTrust(stanzaIDs: true, occupantIDs: true),
            own: RoomOccupant(jid: try JID("\(RoomMessageTests.room)/alice"), occupantID: "occ-me"))
        try await harness.goOnline()
        try harness.deliver(
            RoomMessageTests.groupchat(
                from: "bob", id: "g1", body: "Hi",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='\(RoomMessageTests.room)' id='r-1'/>"
                    + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-bob'/>"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let id = try #require(try harness.messages().first?.id)

        try await harness.session.react(messageID: id, emojis: ["👍"])
        let reflection =
            "<message from='\(RoomMessageTests.room)/alice' to='\(RoomMessageTests.me)'"
            + " type='groupchat' id='x1'><reactions xmlns='urn:xmpp:reactions:0' id='r-1'>"
            + "<reaction>👍</reaction></reactions>"
            + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occ-me'/></message>"
        try harness.deliver(reflection)
        try await harness.barrier()
        #expect(try harness.database.reactions(messageID: id).map(\.reactorKey) == ["occ-me"])
        #expect(await harness.session.ownReactions(messageID: id) == ["👍"])

        // Another device of ours changes it: the picker sees the change.
        try harness.deliver(
            reflection.replacingOccurrences(of: "👍", with: "🎉")
                .replacingOccurrences(of: "id='x1'", with: "id='x2'"))
        try await harness.barrier()
        #expect(await harness.session.ownReactions(messageID: id) == ["🎉"])
        #expect(try harness.database.reactions(messageID: id).count == 1)
        await harness.stop()
    }

    @Test func inARoomTheNickTheRoomGaveUsCounts() async throws {
        let harness = try await RoomMessageTests.harness(
            own: RoomOccupant(jid: try JID("\(RoomMessageTests.room)/alice_2"), occupantID: nil))
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(RoomMessageTests.room)?.id)
        let id = try Self.incoming(harness, chatID: chatID)
        try harness.database.setReactions(
            messageID: id, reactorKey: "\(RoomMessageTests.room)/alice_2", emojis: ["👍"])
        // Someone else now has the nick stored for the chat.
        try harness.database.setReactions(
            messageID: id, reactorKey: "\(RoomMessageTests.room)/alice", emojis: ["🎉"])

        #expect(await harness.session.ownReactions(messageID: id) == ["👍"])
        await harness.stop()
    }

    @Test func inADirectChatTheBareJIDCounts() async throws {
        let harness = try await SessionHarness { database, accountID in
            _ = try database.ensureChat(
                accountID: accountID, jid: AccountSessionTests.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(AccountSessionTests.bob)?.id)
        let id = try Self.incoming(harness, chatID: chatID)
        try harness.database.setReactions(
            messageID: id, reactorKey: SessionServer.account, emojis: ["❤️", "👍"])
        try harness.database.setReactions(
            messageID: id, reactorKey: AccountSessionTests.bob, emojis: ["😂"])

        #expect(await harness.session.ownReactions(messageID: id) == ["❤️", "👍"])
        #expect(await harness.session.ownReactions(messageID: 9_999) == [])
        await harness.stop()
    }

    private static func incoming(_ harness: SessionHarness, chatID: Int64) throws -> Int64 {
        let outcome = try harness.database.upsertIncoming(
            IncomingMessage(
                accountID: harness.accountID, chatID: chatID, senderJID: "someone@example.test",
                body: "Hello", originID: UUID().uuidString, timestamp: Date()))
        guard case .inserted(let id) = outcome else {
            Issue.record("not stored")
            return -1
        }
        return id
    }
}
