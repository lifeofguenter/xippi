import Foundation
import GRDB
import Testing

@testable import XippiStore

extension AccountRecord {
    static func sample(jid: String) -> AccountRecord {
        AccountRecord(
            id: nil, jid: jid, enabled: true, resource: "mac", clientID: "cid", hostOverride: nil,
            portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil,
            smResume: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

extension ChatRecord {
    static func sample(accountID: Int64, jid: String) -> ChatRecord {
        ChatRecord(
            id: nil, accountID: accountID, jid: jid, kind: .direct, name: nil, pinned: false,
            muted: false,
            notify: .all, draft: nil, encryption: .none, nick: nil, password: nil, autojoin: false,
            lastActivity: nil, unreadCount: 0, mentionCount: 0, lastReadMessageID: nil,
            avatarHash: nil)
    }
}

extension MessageRecord {
    static func sample(accountID: Int64, chatID: Int64, body: String? = "hello") -> MessageRecord {
        MessageRecord(
            id: nil, accountID: accountID, chatID: chatID, direction: .incoming,
            senderJID: "b@example.org",
            senderNick: nil, occupantID: nil, body: body, archiveID: nil, originID: nil,
            stanzaMessageID: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001), state: .sent, errorText: nil,
            encryption: .none, senderDeviceFingerprint: nil, replyToMessageID: nil,
            replyToSenderLabel: nil,
            replyQuote: nil, editedAt: nil, retracted: false, moderatedBy: nil,
            moderationReason: nil, kind: .text)
    }
}

extension AttachmentRecord {
    static func sample(messageID: Int64) -> AttachmentRecord {
        AttachmentRecord(
            id: nil, messageID: messageID, remoteURL: "https://example.org/f.png",
            aesgcmKey: Data([1, 2]),
            localPath: nil, mimeType: "image/png", byteSize: 10, fileName: "f.png", width: 1,
            height: 2,
            durationSeconds: nil, state: .remote)
    }
}

@Suite struct RecordTests {
    func seeded() throws -> (AppDatabase, Int64, Int64) {
        let db = try AppDatabase.inMemory()
        let ids: (Int64, Int64) = try db.writer.write { d in
            var account = AccountRecord.sample(jid: "a@example.org")
            try account.insert(d)
            var chat = ChatRecord.sample(accountID: try #require(account.id), jid: "b@example.org")
            try chat.insert(d)
            return (try #require(account.id), try #require(chat.id))
        }
        return (db, ids.0, ids.1)
    }

    @Test func accountRoundTripsJSONFields() throws {
        let db = try AppDatabase.inMemory()
        var account = AccountRecord.sample(jid: "a@example.org")
        account.pinnedCertSHA256 = ["aa", "bb"]
        account.smResume = Data("{\"id\":\"x\"}".utf8)
        try db.writer.write { try account.insert($0) }
        let fetched = try #require(try db.reader.read { try AccountRecord.fetchOne($0) })
        #expect(fetched.pinnedCertSHA256 == ["aa", "bb"])
        #expect(fetched.smResume == account.smResume)
        #expect(fetched.id != nil)
    }

    @Test func enumsStoredAsStrings() throws {
        let (db, accountID, chatID) = try seeded()
        try db.writer.write { d in
            var m = MessageRecord.sample(accountID: accountID, chatID: chatID)
            m.kind = .callLog
            m.state = .displayed
            try m.insert(d)
        }
        let row = try #require(
            try db.reader.read {
                try Row.fetchOne($0, sql: "SELECT kind, state, direction FROM message")
            })
        #expect(row["kind"] as String == "callLog")
        #expect(row["state"] as String == "displayed")
        #expect(row["direction"] as String == "incoming")
    }

    @Test func archiveIDUniquePerChatWhenPresent() throws {
        let (db, accountID, chatID) = try seeded()
        try db.writer.write { d in
            for _ in 0..<2 {
                var m = MessageRecord.sample(accountID: accountID, chatID: chatID)
                try m.insert(d)  // archiveID nil: allowed twice
            }
            var a = MessageRecord.sample(accountID: accountID, chatID: chatID)
            a.archiveID = "A1"
            try a.insert(d)
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { d in
                var b = MessageRecord.sample(accountID: accountID, chatID: chatID)
                b.archiveID = "A1"
                try b.insert(d)
            }
        }
    }

    @Test func reactionUniquePerReactor() throws {
        let (db, accountID, chatID) = try seeded()
        try db.writer.write { d in
            var m = MessageRecord.sample(accountID: accountID, chatID: chatID)
            try m.insert(d)
            let id = try #require(m.id)
            var r1 = ReactionRecord(messageID: id, reactorKey: "r", emojis: ["a"])
            try r1.insert(d)
            #expect(throws: DatabaseError.self) {
                var r2 = ReactionRecord(messageID: id, reactorKey: "r", emojis: ["b"])
                try r2.insert(d)
            }
        }
    }

    @Test func fullTextSearchFoldsDiacriticsAndTracksEdits() throws {
        let (db, accountID, chatID) = try seeded()
        try db.writer.write { d in
            var m = MessageRecord.sample(
                accountID: accountID, chatID: chatID, body: "Caf\u{e9} am Morgen")
            try m.insert(d)
        }
        func hits(_ q: String) throws -> Int {
            try db.reader.read {
                try Int.fetchOne(
                    $0, sql: "SELECT count(*) FROM messageFTS WHERE messageFTS MATCH ?",
                    arguments: [q]) ?? 0
            }
        }
        #expect(try hits("cafe") == 1)
        try db.writer.write { try $0.execute(sql: "UPDATE message SET body = 'Tee'") }
        #expect(try hits("cafe") == 0)
        #expect(try hits("tee") == 1)
        try db.writer.write { try $0.execute(sql: "DELETE FROM message") }
        #expect(try hits("tee") == 0)
    }

    @Test func otherTablesRoundTrip() throws {
        let (db, accountID, _) = try seeded()
        try db.writer.write { d in
            var r34888 = RosterItemRecord(
                id: nil, accountID: accountID, jid: "c@example.org", name: "C",
                subscription: "both",
                ask: nil, approved: false, groups: ["Friends"])
            try r34888.insert(d)
            var r74315 = MAMRangeRecord(
                id: nil, accountID: accountID, archiveJID: "b@example.org", startArchiveID: "1",
                endArchiveID: "2", startTime: Date(timeIntervalSince1970: 1),
                endTime: Date(timeIntervalSince1970: 2))
            try r74315.insert(d)
            var r50569 = CapsRecord(verification: "v", features: ["f"], identities: Data([1]))
            try r50569.insert(d)
            var r85392 = AvatarRecord(hash: "h", fileName: "h.png", byteSize: 3)
            try r85392.insert(d)
            var r14435 = ProfileRecord(
                accountID: accountID, jid: "c@example.org", fullName: "C", nickname: nil,
                data: Data([2]))
            try r14435.insert(d)
            var r21429 = BookmarkRecord(
                accountID: accountID, roomJID: "r@example.org", name: "R", autojoin: true,
                nick: "me", password: nil)
            try r21429.insert(d)
            var r33495 = OMEMOAccountRecord(
                accountID: accountID, version: .v2, deviceID: 5, identityPrivate: Data([1]),
                identityPublic: Data([2]), registrationID: nil, signedPreKeyID: 1, nextPreKeyID: 2)
            try r33495.insert(d)
            var r55656 = OMEMODeviceRecord(
                accountID: accountID, jid: "c@example.org", version: .v03, deviceID: 7, label: nil,
                active: true, lastSeen: nil, identityKey: nil, trust: .undecided)
            try r55656.insert(d)
            var r18001 = OMEMOSessionRecord(
                accountID: accountID, jid: "c@example.org", version: .v03, deviceID: 7,
                state: Data([3]))
            try r18001.insert(d)
            var r88585 = OMEMOPreKeyRecord(
                accountID: accountID, version: .v03, keyID: 1, privateKey: Data([1]),
                publicKey: Data([2]))
            try r88585.insert(d)
            var r71696 = OMEMOSignedPreKeyRecord(
                accountID: accountID, version: .v03, keyID: 1, privateKey: Data([1]),
                publicKey: Data([2]), signature: Data([3]), createdAt: Date())
            try r71696.insert(d)
            let roster = try #require(try RosterItemRecord.fetchOne(d))
            #expect(roster.groups == ["Friends"])
            #expect(try CapsRecord.fetchOne(d)?.features == ["f"])
            #expect(try OMEMODeviceRecord.fetchOne(d)?.trust == .undecided)
        }
    }
}
