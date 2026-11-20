import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct OutgoingMessageTests {
    func draft(
        _ f: StoreFixture, _ originID: String, at seconds: TimeInterval, chatID: Int64? = nil,
        accountID: Int64? = nil
    ) -> OutgoingMessage {
        OutgoingMessage(
            accountID: accountID ?? f.accountID, chatID: chatID ?? f.bobChatID, originID: originID,
            senderJID: "me@x/mac", body: "text \(originID)", timestamp: StoreFixture.at(seconds))
    }

    @Test func pendingResendsAreListed() throws {
        let f = try StoreFixture()
        let second = try f.db.insertOutgoing(draft(f, "o2", at: 20))
        let first = try f.db.insertOutgoing(draft(f, "o1", at: 10))
        let acked = try f.db.insertOutgoing(draft(f, "o3", at: 30))
        _ = try f.db.insertOutgoing(
            draft(f, "o4", at: 5, chatID: f.otherRoomChatID, accountID: f.otherAccountID))
        #expect(try f.db.markSent(accountID: f.accountID, originID: "o3") == 1)

        let pending = try f.db.pendingOutgoing(accountID: f.accountID)
        #expect(pending.map(\.id) == [first, second])
        #expect(pending.allSatisfy { $0.state == .pending && $0.direction == .outgoing })
        #expect(try f.message(acked).state == .sent)
        #expect(try f.db.pendingOutgoing(accountID: f.otherAccountID).map(\.originID) == ["o4"])
    }

    @Test func insertOutgoingStoresDraftAndIsIdempotent() throws {
        let f = try StoreFixture()
        var message = draft(f, "o1", at: 0)
        message.replyToMessageID = 7
        message.replyQuote = "quoted"
        message.attachments = [
            AttachmentDraft(localPath: "/tmp/a.png", mimeType: "image/png", state: .uploading)
        ]
        let id = try f.db.insertOutgoing(message)
        #expect(try f.db.insertOutgoing(message) == id)

        let row = try f.message(id)
        #expect(row.direction == .outgoing)
        #expect(row.state == .pending)
        #expect(row.originID == "o1")
        #expect(row.stanzaMessageID == "o1")
        #expect(row.replyToMessageID == 7)
        #expect(row.replyQuote == "quoted")
        #expect(try f.db.attachments(messageID: id).map(\.state) == [.uploading])
        #expect(try f.messages().count == 1)
        #expect(try f.chat(f.bobChatID).lastActivity == StoreFixture.at(0))
    }

    @Test func stateMovesForwardOnly() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(draft(f, "o1", at: 0))

        #expect(try f.db.markSent(accountID: f.accountID, originID: "o1") == 1)
        #expect(try f.message(id).state == .sent)
        // A receipt from someone who is not the chat's contact changes nothing.
        #expect(
            try f.db.markDelivered(accountID: f.accountID, stanzaMessageID: "o1", by: "eve@x/pc")
                == 0)
        #expect(
            try f.db.markDelivered(accountID: f.accountID, stanzaMessageID: "o1", by: "bob@x/phone")
                == 1)
        #expect(try f.message(id).state == .delivered)
        #expect(try f.db.markSent(accountID: f.accountID, originID: "o1") == 0)
        #expect(
            try f.db.markFailed(accountID: f.accountID, originID: "o1", error: "late error") == 0)
        #expect(try f.db.markDisplayed(upTo: id) == 1)
        #expect(try f.message(id).state == .displayed)
        #expect(
            try f.db.markDelivered(accountID: f.accountID, stanzaMessageID: "o1", by: "bob@x/phone")
                == 0)
        #expect(try f.message(id).state == .displayed)
    }

    @Test func markFailedRecordsTheError() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(draft(f, "o1", at: 0))
        #expect(
            try f.db.markFailed(
                accountID: f.accountID, originID: "o1", error: "Recipient unavailable") == 1)
        let row = try f.message(id)
        #expect(row.state == .failed)
        #expect(row.errorText == "Recipient unavailable")
        #expect(try f.db.pendingOutgoing(accountID: f.accountID).isEmpty)
        // Another account's identical origin-id is not touched.
        #expect(try f.db.markFailed(accountID: f.otherAccountID, originID: "o1", error: "x") == 0)
    }

    @Test func displayedMarkerCoversEarlierMessages() throws {
        let f = try StoreFixture()
        let a = try f.db.insertOutgoing(draft(f, "a", at: 0))
        let b = try f.db.insertOutgoing(draft(f, "b", at: 1))
        let c = try f.db.insertOutgoing(draft(f, "c", at: 2))
        let failed = try f.db.insertOutgoing(draft(f, "d", at: 0.5))
        try f.db.markFailed(accountID: f.accountID, originID: "d", error: "x")
        let roomMessage = try f.db.insertOutgoing(draft(f, "e", at: 0, chatID: f.roomChatID))
        try f.db.markSent(accountID: f.accountID, originID: "a")
        try f.db.markSent(accountID: f.accountID, originID: "b")

        #expect(try f.db.markDisplayed(upTo: b) == 2)
        #expect(try f.message(a).state == .displayed)
        #expect(try f.message(b).state == .displayed)
        #expect(try f.message(c).state == .pending)
        #expect(try f.message(failed).state == .failed)
        #expect(try f.message(roomMessage).state == .pending)
    }

    @Test func displayedMarkerByReferenceLooksAtOurMessagesOnly() throws {
        let f = try StoreFixture()
        let ours = try f.db.insertOutgoing(draft(f, "same-id", at: 0))
        try f.db.markSent(accountID: f.accountID, originID: "same-id")
        // bob's own message happens to carry the same id, and is newer.
        _ = try f.db.upsertIncoming(f.fromBob("hi", at: 5, originID: "same-id"))
        #expect(try f.db.markDisplayed(chatID: f.bobChatID, reference: "same-id") == 1)
        #expect(try f.message(ours).state == .displayed)
        #expect(try f.db.markDisplayed(chatID: f.bobChatID, reference: "unknown") == 0)
    }

    @Test func deliveryReceiptsOnlyInDirectChats() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(draft(f, "r1", at: 0, chatID: f.roomChatID))
        try f.db.markSent(accountID: f.accountID, originID: "r1")
        #expect(
            try f.db.markDelivered(
                accountID: f.accountID, stanzaMessageID: "r1", by: "\(StoreFixture.roomJID)/carol")
                == 0)
        #expect(try f.message(id).state == .sent)
    }

    @Test func outgoingForAnotherAccountsChatIsRejected() throws {
        let f = try StoreFixture()
        #expect(throws: StoreError.chatAccountMismatch(chatID: f.bobChatID)) {
            try f.db.insertOutgoing(draft(f, "o1", at: 0, accountID: f.otherAccountID))
        }
    }
}
