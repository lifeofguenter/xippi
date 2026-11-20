import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Who wrote what in a room's history (R13, R41): a nick never says it was us. A message is
/// ours by a trusted occupant id; otherwise it is only linked to one of our own rows when it is
/// that row's exact copy, and a link never edits anything.
@Suite struct CatchUpOwnershipTests {
    static let room = CatchUpFixture.room
    static let base = CatchUpFixture.base

    /// One of our room messages as the session stores it on sending: pending, no archive id,
    /// under the nick the room gave us.
    @discardableResult
    static func ourRow(
        _ f: CatchUpFixture, chatID: Int64, originID: String, nick: String, body: String?,
        link: String? = nil, localPath: String? = nil
    ) throws -> Int64 {
        try f.database.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: chatID, originID: originID,
                senderJID: "\(CatchUpFixture.account)/res", senderNick: nick, body: body,
                timestamp: base, kind: link == nil ? .text : .file,
                attachments: link.map {
                    [AttachmentDraft(remoteURL: $0, localPath: localPath, state: .local)]
                } ?? []))
    }

    static func roomChat(_ f: CatchUpFixture) throws -> Int64 {
        try #require(try f.database.ensureChat(accountID: f.accountID, jid: room, kind: .room).id)
    }

    /// Joins as `nick` and waits until the room's archive is through.
    static func join(
        _ f: CatchUpFixture, chatID: Int64, as nick: String, occupantID: String? = nil,
        occupantIDs: Bool = false, last: String
    ) async throws {
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(room),
                ownOccupant: RoomOccupant(jid: try JID("\(room)/\(nick)"), occupantID: occupantID),
                trust: RoomTrust(stanzaIDs: true, occupantIDs: occupantIDs, nonAnonymous: false),
                nick: nick))
        try await waitUntil("room caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: room) == last
        }
    }

    static func entry(
        _ id: String, nick: String, _ body: String, originID: String? = nil,
        occupantID: String? = nil, extra: [Element] = [], after seconds: TimeInterval = 30
    ) -> FakeArchive.Entry {
        FakeArchive.Entry(
            id: id,
            message: FakeArchive.groupchat(
                room: room, nick: nick, body, occupantID: occupantID, originID: originID,
                extra: extra),
            stamp: base.addingTimeInterval(seconds))
    }

    static func replace(_ id: String) -> Element {
        Element("replace", namespace: ChatMessage.correctionNamespace, attributes: ["id": id])
    }

    static func retract(_ id: String) -> Element {
        Element("retract", namespace: ChatMessage.retractionNamespace, attributes: ["id": id])
    }

    // MARK: C1: a nick is no proof

    /// Someone held our nick while we were away and wrote under it, naming our messages.
    @Test func aNickNeverMakesArchivedMessagesOurs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatchUpOwnership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MediaLibrary(directory: directory)
        let (path, _) = try library.store(Data("our photo".utf8))
        let f = try CatchUpFixture(library: library)
        let chatID = try Self.roomChat(f)
        let text = try Self.ourRow(
            f, chatID: chatID, originID: "mine", nick: "alice", body: "hello")
        let file = try Self.ourRow(
            f, chatID: chatID, originID: "file1", nick: "alice", body: nil,
            link: "https://up.example.test/f.png", localPath: path.path)
        f.archive.set(
            Self.room,
            [
                Self.entry(
                    "r1", nick: "alice", "rewritten", originID: "x1", extra: [Self.replace("mine")]),
                Self.entry(
                    "r2", nick: "alice", "gone", originID: "x2", extra: [Self.retract("mine")]),
                Self.entry(
                    "r3", nick: "alice", "gone", originID: "x3", extra: [Self.retract("file1")]),
                Self.entry("r4", nick: "alice", "I am alice", originID: "x4"),
            ])

        try await Self.join(f, chatID: chatID, as: "alice", last: "r4")

        let ours = try #require(try f.database.message(id: text))
        #expect(ours.body == "hello")
        #expect(!ours.retracted)
        #expect(ours.editedAt == nil)
        let fileRow = try #require(try f.database.message(id: file))
        #expect(!fileRow.retracted)
        #expect(try f.database.attachments(messageID: file).count == 1)
        #expect(FileManager.default.fileExists(atPath: path.path))
        let theirs = try f.rows(Self.room).filter { $0.id != text && $0.id != file }
        #expect(theirs.map(\.body) == ["rewritten", "I am alice"])
        #expect(theirs.allSatisfy { $0.direction == .incoming })
    }

    /// In a room with occupant ids, only the id makes a message ours: one under our nick
    /// without it is someone else's.
    @Test func inARoomWithOccupantIDsOnlyTheIDMakesAMessageOurs() async throws {
        let f = try CatchUpFixture()
        let chatID = try Self.roomChat(f)
        f.archive.set(
            Self.room,
            [
                Self.entry("r1", nick: "alice", "no id"),
                Self.entry("r2", nick: "alice", "other id", occupantID: "occ-other"),
                Self.entry("r3", nick: "renamed", "our id", occupantID: "occ-me"),
            ])

        try await Self.join(
            f, chatID: chatID, as: "alice", occupantID: "occ-me", occupantIDs: true, last: "r3")

        #expect(try f.rows(Self.room).map(\.direction) == [.incoming, .incoming, .outgoing])
    }

    // MARK: R41: linking our own copies

    /// The room gave us "alice_" (nick conflict) when we sent; today we are "alice" again. The
    /// archive's copy of our message is linked to our row: one row, sent, with the archive id.
    @Test func ourCopyUnderTheNickTheRoomGaveUsIsLinked() async throws {
        let f = try CatchUpFixture()
        let chatID = try Self.roomChat(f)
        let text = try Self.ourRow(f, chatID: chatID, originID: "o1", nick: "alice_", body: "hi")
        let link = "https://up.example.test/get/f.png"
        let file = try Self.ourRow(
            f, chatID: chatID, originID: "o2", nick: "alice_", body: nil, link: link)
        var oob = Element("x", namespace: OOB.namespace)
        oob.append(Element("url", namespace: OOB.namespace, children: [.text(link)]))
        f.archive.set(
            Self.room,
            [
                Self.entry("r1", nick: "alice_", "hi", originID: "o1"),
                Self.entry("r2", nick: "alice_", link, originID: "o2", extra: [oob]),
            ])

        try await Self.join(f, chatID: chatID, as: "alice", last: "r2")

        let rows = try f.rows(Self.room)
        #expect(rows.count == 2)
        #expect(try f.database.message(id: text)?.archiveID == "r1")
        #expect(try f.database.message(id: text)?.state == .sent)
        #expect(try f.database.message(id: file)?.archiveID == "r2")
        #expect(rows.allSatisfy { $0.direction == .outgoing })
    }

    enum Mismatch: String, CaseIterable, Sendable {
        case otherNick, otherBody, carriesCorrection, carriesRetraction, tooLate, alreadyArchived
    }

    /// A copy that fails any one condition of the link is someone else's message: it never
    /// becomes ours and never changes our row.
    @Test(arguments: Mismatch.allCases)
    func aCopyFailingOneConditionIsSomeoneElses(_ mismatch: Mismatch) async throws {
        let f = try CatchUpFixture()
        let chatID = try Self.roomChat(f)
        let ours = try Self.ourRow(f, chatID: chatID, originID: "o1", nick: "alice", body: "hi")
        if mismatch == .alreadyArchived {
            try f.database.upsertIncoming(
                IncomingMessage(
                    accountID: f.accountID, chatID: chatID, direction: .outgoing,
                    senderJID: "\(Self.room)/alice", senderNick: "alice", body: "hi",
                    archiveID: "r0", originID: "o1", stanzaMessageID: "o1", timestamp: Self.base))
        }
        let entry: FakeArchive.Entry
        switch mismatch {
        case .otherNick:
            entry = Self.entry("r1", nick: "mallory", "hi", originID: "o1")
        case .otherBody:
            entry = Self.entry("r1", nick: "alice", "hi there", originID: "o1")
        case .carriesCorrection:
            entry = Self.entry(
                "r1", nick: "alice", "hi", originID: "o1", extra: [Self.replace("o1")])
        case .carriesRetraction:
            entry = Self.entry(
                "r1", nick: "alice", "hi", originID: "o1", extra: [Self.retract("o1")])
        case .tooLate:
            entry = Self.entry("r1", nick: "alice", "hi", originID: "o1", after: 3600)
        case .alreadyArchived:
            entry = Self.entry("r1", nick: "alice", "hi", originID: "o1")
        }
        f.archive.set(Self.room, [entry])

        try await Self.join(f, chatID: chatID, as: "alice", last: "r1")

        let row = try #require(try f.database.message(id: ours))
        #expect(row.body == "hi")
        #expect(!row.retracted)
        #expect(row.archiveID == (mismatch == .alreadyArchived ? "r0" : nil))
        #expect(row.state == (mismatch == .alreadyArchived ? .sent : .pending))
        let others = try f.rows(Self.room).filter { $0.id != ours }
        #expect(others.allSatisfy { $0.direction == .incoming })
    }

    // MARK: I1

    /// A join's catch-up runs on when the account's catch-up starts after it.
    @Test func aJoinsCatchUpSurvivesTheAccountsStart() async throws {
        let f = try CatchUpFixture()
        let chatID = try Self.roomChat(f)
        f.archive.set(CatchUpFixture.account, CatchUpFixture.conversation(5))
        f.archive.set(Self.room, [Self.entry("r1", nick: "bob", "hello")])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(Self.room), ownOccupant: nil, trust: RoomTrust(),
                nick: "alice"))
        await f.catchUp.sessionStarted(ownJID: try JID("\(CatchUpFixture.account)/res"))

        try await waitUntil("both caught up") {
            try f.rows(Self.room).count == 1 && f.rows().count == 5
        }
    }
}

// MARK: - Fix round 2

extension CatchUpOwnershipTests {
    /// N7: the window runs from when our message went out, not from when it was written.
    @Test func theCopyWindowRunsFromTheSendTime() async throws {
        let f = try CatchUpFixture()
        let chatID = try Self.roomChat(f)
        let ours = try Self.ourRow(f, chatID: chatID, originID: "o1", nick: "alice", body: "hi")
        // Written while not joined, sent an hour later.
        try f.database.markAcknowledged(
            accountID: f.accountID, originID: "o1", at: Self.base.addingTimeInterval(3600))
        f.archive.set(
            Self.room, [Self.entry("r1", nick: "alice", "hi", originID: "o1", after: 3630)])

        try await Self.join(f, chatID: chatID, as: "alice", last: "r1")

        #expect(try f.database.message(id: ours)?.archiveID == "r1")
        #expect(try f.rows(Self.room).count == 1)
    }

    /// N2: in a MIX channel the channel stamps who wrote a message: our participant id in
    /// `from`, or our bare JID in `<mix><jid>`. A nick proves nothing.
    @Test func inAChannelOurParticipantIDOrJIDMakesAMessageOurs() async throws {
        let f = try CatchUpFixture()
        let channel = "chan@mix.example.test"
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: channel, kind: .channel).id)
        func mixMessage(_ participant: String, _ body: String, nick: String?, jid: String?)
            -> Element
        {
            var message = Element(
                "message", namespace: "jabber:client",
                attributes: [
                    "from": "\(channel)/\(participant)", "type": "groupchat", "id": .stanzaID(),
                ])
            message.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
            var mix = Element("mix", namespace: MIX.coreNamespace)
            if let nick {
                mix.append(Element("nick", namespace: MIX.coreNamespace, children: [.text(nick)]))
            }
            if let jid {
                mix.append(Element("jid", namespace: MIX.coreNamespace, children: [.text(jid)]))
            }
            message.append(mix)
            return message
        }
        f.archive.set(
            channel,
            [
                FakeArchive.Entry(
                    id: "m1", message: mixMessage("pid-me", "by id", nick: "alice", jid: nil),
                    stamp: Self.base),
                FakeArchive.Entry(
                    id: "m2",
                    message: mixMessage(
                        "pid-old", "by jid", nick: "old", jid: CatchUpFixture.account),
                    stamp: Self.base.addingTimeInterval(1)),
                FakeArchive.Entry(
                    id: "m3",
                    message: mixMessage("pid-bob", "bob", nick: "bob", jid: CatchUpFixture.bob),
                    stamp: Self.base.addingTimeInterval(2)),
                FakeArchive.Entry(
                    id: "m4", message: mixMessage("pid-x", "our nick", nick: "alice", jid: nil),
                    stamp: Self.base.addingTimeInterval(3)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(channel),
                ownOccupant: RoomOccupant(jid: try JID("\(channel)/pid-me"), occupantID: nil),
                trust: RoomTrust(), nick: "alice"))
        try await waitUntil("channel caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: channel) == "m4"
        }

        let rows = try f.rows(channel)
        #expect(rows.map(\.body) == ["by id", "by jid", "bob", "our nick"])
        #expect(rows.map(\.direction) == [.outgoing, .outgoing, .incoming, .incoming])
    }
}

extension CatchUpOwnershipTests {
    /// N11: the channel's stamp (`<mix>`) counts only as one element in the channel's own
    /// archive. A copy whose `from` is the bare channel (XEP-0369 Example 28) is kept, with
    /// the stamp's nick, and is ours only by the stamp's JID; one with a participant id is
    /// ours by that id first.
    @Test func channelHistoryTrustsOneStampAndKeepsBareSenders() async throws {
        let f = try CatchUpFixture()
        let channel = "chan@mix.example.test"
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: channel, kind: .channel).id)
        func message(_ from: String, _ body: String, stamps: [(nick: String?, jid: String?)])
            -> Element
        {
            var message = Element(
                "message", namespace: "jabber:client",
                attributes: ["from": from, "type": "groupchat", "id": .stanzaID()])
            message.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
            for stamp in stamps {
                var mix = Element("mix", namespace: MIX.coreNamespace)
                if let nick = stamp.nick {
                    mix.append(
                        Element("nick", namespace: MIX.coreNamespace, children: [.text(nick)]))
                }
                if let jid = stamp.jid {
                    mix.append(Element("jid", namespace: MIX.coreNamespace, children: [.text(jid)]))
                }
                message.append(mix)
            }
            return message
        }
        let me = CatchUpFixture.account
        f.archive.set(
            channel,
            [
                FakeArchive.Entry(
                    id: "b1",
                    message: message(channel, "bare bob", stamps: [("bob", CatchUpFixture.bob)]),
                    stamp: Self.base),
                FakeArchive.Entry(
                    id: "b2", message: message(channel, "bare us", stamps: [("alice", me)]),
                    stamp: Self.base.addingTimeInterval(1)),
                FakeArchive.Entry(
                    id: "b3",
                    message: message(
                        "\(channel)/pid-x", "two stamps",
                        stamps: [("alice", me), ("x", "x@example.test")]),
                    stamp: Self.base.addingTimeInterval(2)),
                FakeArchive.Entry(
                    id: "b4",
                    message: message(
                        "\(channel)/pid-me", "our id", stamps: [("alice", CatchUpFixture.bob)]),
                    stamp: Self.base.addingTimeInterval(3)),
                FakeArchive.Entry(
                    id: "b5",
                    message: message("\(channel)/pid-y", "carol", stamps: [("carol", nil)]),
                    stamp: Self.base.addingTimeInterval(4)),
            ])

        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(channel),
                ownOccupant: RoomOccupant(jid: try JID("\(channel)/pid-me"), occupantID: nil),
                trust: RoomTrust(), nick: "alice"))
        try await waitUntil("channel caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: channel) == "b5"
        }

        let rows = try f.rows(channel)
        #expect(rows.map(\.body) == ["bare bob", "bare us", "two stamps", "our id", "carol"])
        #expect(
            rows.map(\.direction) == [.incoming, .outgoing, .incoming, .outgoing, .incoming])
        #expect(rows.first?.senderNick == "bob")
        #expect(rows.last?.senderNick == "carol")
    }
}
