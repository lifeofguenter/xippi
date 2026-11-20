import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// A history catch-up that counts how often it was asked.
actor CountingCatchUp: ArchiveCatchUp {
    private(set) var started: [JID] = []
    /// The rooms whose archive was asked for, one entry per join.
    private(set) var rooms: [JID] = []

    func sessionStarted(ownJID: JID) async {
        started.append(ownJID)
    }

    func roomJoined(_ room: RoomArchive) async {
        rooms.append(room.room)
    }
}

/// Credentials that keep a changed password, like the keychain.
final class StoringCredentials: CredentialProvider, PasswordStoring {
    let stored = Locked<[String]>([])

    func password(for jid: JID) async -> String? { "secret" }
    func fastToken(for jid: JID) async -> FASTToken? { nil }
    func store(_ token: FASTToken?, for jid: JID) async {}
    func setPassword(_ password: String, for jid: JID) throws {
        stored.withLock { $0.append(password) }
    }
}

/// The review's findings on `AccountSession`, one test each.
@Suite struct SessionFixRoundTests {
    static let bob = "bob@example.test"
    static let bobPhone = "bob@example.test/phone"
    static let me = SessionServer.fullJID
    static let room = "room@conference.example.test"

    static func rosterItem(_ jid: String, _ subscription: String) -> String {
        "<item jid='\(jid)' subscription='\(subscription)'/>"
    }

    static func bounce(id: String, from: String?, text: String) -> String {
        let sender = from.map { " from='\($0)'" } ?? ""
        return "<message\(sender) to='\(me)' type='error' id='\(id)'><body>x</body>"
            + "<error type='cancel'><service-unavailable"
            + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/><text"
            + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>\(text)</text></error></message>"
    }

    static func sentMessage(
        _ database: AppDatabase, accountID: Int64, chat jid: String, kind: ChatKind,
        originID: String
    ) throws {
        let chat = try database.ensureChat(accountID: accountID, jid: jid, kind: kind)
        _ = try database.insertOutgoing(
            OutgoingMessage(
                accountID: accountID, chatID: try #require(chat.id), originID: originID,
                senderJID: SessionServer.account, body: "Original", timestamp: Date()))
        try database.markSent(accountID: accountID, originID: originID)
    }

    // MARK: I1

    @Test func aBounceCountsOnlyFromThePeerOrOurServer() async throws {
        let harness = try await SessionHarness { database, accountID in
            try Self.sentMessage(
                database, accountID: accountID, chat: Self.bob, kind: .direct, originID: "to-bob")
            try Self.sentMessage(
                database, accountID: accountID, chat: Self.room, kind: .room, originID: "to-room")
            try Self.sentMessage(
                database, accountID: accountID, chat: "carol@example.test", kind: .direct,
                originID: "to-carol")
        }
        try await harness.goOnline()

        try harness.deliver(Self.bounce(id: "to-bob", from: "mallory@evil.test", text: "Lies"))
        try harness.deliver(Self.bounce(id: "to-room", from: "\(Self.room)/mallory", text: "Lies"))
        try harness.deliver(Self.bounce(id: "to-bob", from: Self.room, text: "Lies"))
        try await harness.barrier()
        #expect(try harness.message(originID: "to-bob")?.state == .sent)
        #expect(try harness.message(originID: "to-room")?.state == .sent)

        try harness.deliver(Self.bounce(id: "to-bob", from: Self.bobPhone, text: "Gone"))
        try harness.deliver(Self.bounce(id: "to-room", from: Self.room, text: "Kicked"))
        try harness.deliver(Self.bounce(id: "to-carol", from: "example.test", text: "No route"))
        try await waitUntil("failed") {
            try harness.message(originID: "to-carol")?.state == .failed
        }
        #expect(try harness.message(originID: "to-bob")?.errorText == "Gone")
        #expect(try harness.message(originID: "to-room")?.errorText == "Kicked")
        #expect(try harness.message(originID: "to-carol")?.errorText == "No route")
        await harness.stop()
    }

    // MARK: I2

    @Test func aMessageComposedDuringSetupGoesOutOnceAfterTheOlderOnes() async throws {
        let heldRoster = Locked<Element?>(nil)
        let harness = try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: try #require(chat.id), originID: "older",
                    senderJID: SessionServer.account, body: "Older",
                    timestamp: Date(timeIntervalSinceNow: -60)))
        }
        harness.server.setResponder { iq in
            guard iq.child("query", namespace: "jabber:iq:roster") != nil, iq.type == "get"
            else { return nil }
            heldRoster.set(iq)
            return []
        }
        try await harness.session.start()
        try await waitUntil("roster asked") { heldRoster.value != nil }
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        let newID = try await harness.session.send(text: "Newer", chatID: chatID)
        let newOrigin = try #require(try harness.database.message(id: newID)?.originID)
        let rosterID = try #require(heldRoster.value?.id)
        try harness.deliver(
            "<iq type='result' id='\(rosterID)'><query xmlns='jabber:iq:roster' ver='v1'/></iq>")
        try await waitUntil("set up") { await harness.session.progress.started == 1 }
        try await waitUntil("both out") { !harness.server.messages(id: newOrigin).isEmpty }
        try await harness.barrier()

        #expect(harness.server.messages(id: newOrigin).count == 1)
        #expect(harness.server.messages(id: "older").count == 1)
        let ids = harness.server.stanzas.filter { $0.name == "message" }.compactMap(\.id)
        #expect(ids.firstIndex(of: "older") ?? .max < ids.firstIndex(of: newOrigin) ?? -1)
        await harness.stop()
    }

    // MARK: N1 (fix round 2)

    /// A harness whose session waits in setup (the roster answer is held) with one pending
    /// message, "older", to bob; `release()` lets the setup finish.
    struct HeldSetup {
        let harness: SessionHarness
        let heldRoster: Locked<Element?>

        init(options: SessionServer.Options = SessionServer.Options()) async throws {
            let heldRoster = Locked<Element?>(nil)
            self.heldRoster = heldRoster
            harness = try await SessionHarness(options: options) { database, accountID in
                let chat = try database.ensureChat(
                    accountID: accountID, jid: SessionFixRoundTests.bob, kind: .direct)
                _ = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: accountID, chatID: try #require(chat.id), originID: "older",
                        senderJID: SessionServer.account, body: "Older",
                        timestamp: Date(timeIntervalSinceNow: -60)))
            }
            harness.server.setResponder { iq in
                guard iq.child("query", namespace: "jabber:iq:roster") != nil, iq.type == "get"
                else { return nil }
                heldRoster.set(iq)
                return []
            }
            try await harness.session.start()
            try await waitUntil("roster asked") { heldRoster.value != nil }
        }

        var olderID: Int64 {
            get throws { try #require(try harness.message(originID: "older")?.id) }
        }

        func release() async throws {
            let rosterID = try #require(heldRoster.value?.id)
            try harness.deliver(
                "<iq type='result' id='\(rosterID)'><query xmlns='jabber:iq:roster' ver='v1'/></iq>"
            )
            try await waitUntil("set up") { await harness.session.progress.started == 1 }
            try await harness.barrier()
        }
    }

    static func messages(_ server: SessionServer) -> [Element] {
        server.stanzas.filter { $0.name == "message" }
    }

    @Test func aMessageRetractedDuringSetupIsNeverSent() async throws {
        let setup = try await HeldSetup()

        try await setup.harness.session.retract(messageID: try setup.olderID)
        try await setup.release()

        #expect(Self.messages(setup.harness.server).isEmpty, "neither the text nor a retraction")
        #expect(try setup.harness.message(originID: "older")?.retracted == true)
        await setup.harness.stop()
    }

    @Test func aMessageCorrectedDuringSetupGoesOutOnceWithTheNewText() async throws {
        let setup = try await HeldSetup()

        try await setup.harness.session.correct(messageID: try setup.olderID, newText: "Fixed")
        try await setup.release()
        // The chat waits for its encryption default (R63): the row goes once it is known.
        try await waitUntil("sent") { !Self.messages(setup.harness.server).isEmpty }
        try await setup.harness.barrier()

        let sent = Self.messages(setup.harness.server)
        #expect(sent.count == 1)
        #expect(sent.first?.id == "older")
        #expect(sent.first?.child("body")?.text == "Fixed")
        #expect(
            sent.first?.child("replace", namespace: "urn:xmpp:message-correct:0") == nil,
            "the peer never saw the original")
        await setup.harness.stop()
    }

    @Test func aMessageCorrectedAfterItWentOutGetsACorrection() async throws {
        let harness = try await SessionHarness(options: .init(answersAckRequests: true)) {
            database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try await harness.session.send(text: "Teh text", chatID: chatID)
        try await waitUntil("sent") { try harness.database.message(id: id)?.state == .sent }
        let originID = try #require(try harness.database.message(id: id)?.originID)

        try await harness.session.correct(messageID: id, newText: "The text")
        try await harness.barrier()

        let corrections = Self.messages(harness.server).filter {
            $0.child("replace", namespace: "urn:xmpp:message-correct:0")?[attribute: "id"]
                == originID
        }
        #expect(corrections.count == 1)
        #expect(corrections.first?.child("body")?.text == "The text")
        #expect(try harness.database.message(id: id)?.body == "The text")
        await harness.stop()
    }

    // MARK: I3

    @Test func noReceiptForAMessageThatWasNotStored() async throws {
        let harness = try await SessionHarness(
            options: .init(roster: .items([Self.rosterItem(Self.bob, "both")], version: "v1")))
        try await harness.goOnline()
        // The account's rows are gone: every write for it fails.
        try harness.database.removeAccount(id: harness.accountID)

        try harness.deliver(
            "<message from='\(Self.bobPhone)' to='\(Self.me)' type='chat' id='lost'>"
                + "<body>Lost</body><request xmlns='urn:xmpp:receipts'/>"
                + "<markable xmlns='urn:xmpp:chat-markers:0'/></message>")
        try await harness.barrier()

        #expect(
            !harness.server.stanzas.contains {
                $0.child("received", namespace: "urn:xmpp:receipts") != nil
                    || $0.child("received", namespace: "urn:xmpp:chat-markers:0") != nil
            })
        await harness.stop()
    }

    // MARK: S3

    @Test func receivedMarkerForMarkableMessagesFromContacts() async throws {
        let harness = try await SessionHarness(
            options: .init(
                roster: .items(
                    [
                        Self.rosterItem(Self.bob, "both"),
                        Self.rosterItem("carol@example.test", "to"),
                    ],
                    version: "v1")))
        try await harness.goOnline()

        try harness.deliver(
            "<message from='\(Self.bobPhone)' to='\(Self.me)' type='chat' id='mk1'>"
                + "<body>Hi</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>")
        try harness.deliver(
            "<message from='carol@example.test/x' to='\(Self.me)' type='chat' id='mk2'>"
                + "<body>Hi</body><markable xmlns='urn:xmpp:chat-markers:0'/></message>")
        try harness.deliver(
            "<message from='\(Self.bobPhone)' to='\(Self.me)' type='chat' id='mk3'>"
                + "<body>Not markable</body></message>")
        try await harness.barrier()

        let markers = harness.server.stanzas.compactMap { stanza -> (String?, String?)? in
            guard let marker = stanza.child("received", namespace: "urn:xmpp:chat-markers:0")
            else { return nil }
            return (stanza[attribute: "to"], marker[attribute: "id"])
        }
        #expect(markers.map(\.1) == ["mk1"])
        #expect(markers.first?.0 == Self.bobPhone)
        await harness.stop()
    }

    // MARK: S4

    @Test func archiveCatchUpRunsOnFreshSessionsOnly() async throws {
        let harness = try await SessionHarness()
        let catchUp = CountingCatchUp()
        await harness.session.setArchiveCatchUp(catchUp)
        try await harness.goOnline()
        try await waitUntil("caught up") { await catchUp.started.count == 1 }
        #expect(await catchUp.started == [try JID(Self.me)])

        try await harness.drop()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }
        try await harness.barrier()
        #expect(await catchUp.started.count == 1)

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("caught up again") { await catchUp.started.count == 2 }
        await harness.stop()
    }

    // MARK: I6

    @Test func anUnusablePasswordIsRefusedBeforeSending() async throws {
        let credentials = StoringCredentials()
        let harness = try await SessionHarness(credentials: credentials)
        try await harness.goOnline()

        await #expect(throws: SessionError.unusablePassword) {
            try await harness.session.changePassword("pw\u{1F511}")
        }
        await #expect(throws: SessionError.unusablePassword) {
            try await harness.session.changePassword("\u{AD}")
        }
        try await harness.barrier()

        #expect(
            !harness.server.stanzas.contains {
                $0.child("query", namespace: "jabber:iq:register") != nil
            })
        #expect(credentials.stored.value.isEmpty)
        await harness.stop()
    }

    @Test func aPasswordIsChangedOnlyWhereItCanBeKept() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()

        await #expect(throws: SessionError.unavailable) {
            try await harness.session.changePassword("new secret")
        }
        try await harness.barrier()
        #expect(
            !harness.server.stanzas.contains {
                $0.child("query", namespace: "jabber:iq:register") != nil
            })

        let credentials = StoringCredentials()
        let storing = try await SessionHarness(credentials: credentials)
        storing.server.setResponder { iq in
            guard iq.child("query", namespace: "jabber:iq:register") != nil else { return nil }
            return ["<iq type='result' id='\(iq.id ?? "")'/>"]
        }
        try await storing.goOnline()
        try await storing.session.changePassword("new secret")
        #expect(credentials.stored.value == ["new secret"])
        await harness.stop()
        await storing.stop()
    }

    // MARK: Stop is final (M5)

    @Test func aStoppedSessionStaysStopped() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        await harness.stop()
        let transports = harness.transports.count

        await #expect(throws: SessionError.stopped) { try await harness.session.start() }

        #expect(harness.transports.count == transports)
        #expect(await harness.session.connectionState == .offline)
    }
}
