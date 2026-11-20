import Foundation
import GRDB
import Testing

@testable import XippiStore

/// An in-memory database with two accounts, a direct chat with bob and a room on the
/// first account, and the same room on the second account.
struct StoreFixture {
    static let ownJID = "me@x"
    static let bobJID = "bob@x"
    static let roomJID = "room@conference.x"
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    let db: AppDatabase
    let accountID: Int64
    let otherAccountID: Int64
    let bobChatID: Int64
    let roomChatID: Int64
    let otherRoomChatID: Int64

    init() throws {
        let db = try AppDatabase.inMemory()
        var account = AccountRecord.sample(jid: Self.ownJID)
        var other = AccountRecord.sample(jid: "other@y")
        try db.writer.write { d in
            try account.insert(d)
            try other.insert(d)
        }
        let accountID = try #require(account.id)
        let otherAccountID = try #require(other.id)
        self.db = db
        self.accountID = accountID
        self.otherAccountID = otherAccountID
        bobChatID = try #require(
            try db.ensureChat(accountID: accountID, jid: Self.bobJID, kind: .direct).id)
        roomChatID = try #require(
            try db.ensureChat(accountID: accountID, jid: Self.roomJID, kind: .room).id)
        otherRoomChatID = try #require(
            try db.ensureChat(accountID: otherAccountID, jid: Self.roomJID, kind: .room).id)
    }

    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    /// A 1:1 message from bob's phone.
    func fromBob(
        _ body: String?, at seconds: TimeInterval = 0, originID: String? = nil,
        stanzaID: String? = nil,
        archiveID: String? = nil, resource: String = "phone"
    ) -> IncomingMessage {
        IncomingMessage(
            accountID: accountID, chatID: bobChatID, direction: .incoming,
            senderJID: "\(Self.bobJID)/\(resource)", body: body, archiveID: archiveID,
            originID: originID,
            stanzaMessageID: stanzaID, timestamp: Self.at(seconds), receivedAt: Self.at(seconds))
    }

    /// A groupchat message from an occupant of the room on the given account's chat.
    func inRoom(
        _ body: String?, nick: String, occupantID: String?, realJID: String? = nil,
        chatID: Int64? = nil, accountID: Int64? = nil, at seconds: TimeInterval = 0,
        originID: String? = nil, stanzaID: String? = nil, archiveID: String? = nil,
        direction: MessageDirection = .incoming
    ) -> IncomingMessage {
        IncomingMessage(
            accountID: accountID ?? self.accountID, chatID: chatID ?? roomChatID,
            direction: direction, senderJID: "\(Self.roomJID)/\(nick)", senderNick: nick,
            occupantID: occupantID, senderRealJID: realJID, body: body, archiveID: archiveID,
            originID: originID, stanzaMessageID: stanzaID, timestamp: Self.at(seconds),
            receivedAt: Self.at(seconds))
    }

    func messages(chatID: Int64? = nil) throws -> [MessageRecord] {
        try db.reader.read { d in
            var request = MessageRecord.order(Column("timestamp"), Column("id"))
            if let chatID { request = request.filter(Column("chatID") == chatID) }
            return try request.fetchAll(d)
        }
    }

    func message(_ id: Int64) throws -> MessageRecord {
        try #require(try db.message(id: id))
    }

    func chat(_ id: Int64) throws -> ChatRecord {
        try #require(try db.chat(id: id))
    }
}

extension UpsertOutcome {
    /// The row the outcome refers to; fails the test for `.ignored`.
    func id(sourceLocation: SourceLocation = #_sourceLocation) throws -> Int64 {
        try #require(messageID, sourceLocation: sourceLocation)
    }
}
