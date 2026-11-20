import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// OMEMO in an `AccountSession` (alice@example.test on the scripted server, whose PubSub and
/// room administration answers come from a `FakePEP`), with the other side an `OMEMOParty`.
@Suite(.timeLimit(.minutes(1))) struct OMEMOPipelineTests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"
    static let room = "room@conference.example.test"

    /// A session on the shared PEP service, online, with its OMEMO devices published.
    static func online(
        pep: FakePEP, harness existing: SessionHarness? = nil,
        seed: @escaping (AppDatabase, Int64) throws -> Void = { _, _ in }
    ) async throws -> SessionHarness {
        let harness: SessionHarness
        if let existing {
            harness = existing
        } else {
            harness = try await SessionHarness(seed: seed)
        }
        let account = try JID(alice)
        harness.server.setResponder { iq in
            pep.answer(iq, from: account).map { [$0.xml()] }
        }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        return harness
    }

    /// A direct chat with bob, set to OMEMO.
    static func omemoChat(with jid: String) -> (AppDatabase, Int64) throws -> Void {
        { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: jid, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
    }

    /// `stanza` as the server delivers it to alice's session.
    static func delivered(_ stanza: Element, from: String, to: String = me) -> String {
        var element = stanza
        element[attribute: "from"] = from
        element[attribute: "to"] = to
        return element.xml()
    }

    /// The message with this id that the session sent, once the server has it.
    static func sent(_ id: String, by harness: SessionHarness) async throws -> Element {
        try await waitUntil("\(id) sent") { !harness.server.messages(id: id).isEmpty }
        return try #require(harness.server.messages(id: id).first)
    }

    static func sentCarbon(_ inner: String) -> String {
        "<message from='\(alice)' to='\(me)'><sent xmlns='urn:xmpp:carbons:2'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'>\(inner)</forwarded></sent></message>"
    }

    static func chatID(_ harness: SessionHarness, _ jid: String) throws -> Int64 {
        try #require(try harness.chat(jid)?.id)
    }

    // MARK: Device lists

    @Test func deviceListsInCarbonsOrForwardsAreNeverTheAccounts() async throws {
        let pep = FakePEP()
        let harness = try await Self.online(pep: pep)
        let engine = harness.session.omemo.engine
        let own = try await engine.ensureOwnDevice(version: .v2)
        let account = try JID(Self.alice)
        let event =
            "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
            + "<items node='urn:xmpp:omemo:2:devices'><item id='current'>"
            + "<devices xmlns='urn:xmpp:omemo:2'><device id='6666'/></devices>"
            + "</item></items></event>"

        // Inside a sent carbon, a received carbon, and a message forwarded by someone else.
        try harness.deliver(
            Self.sentCarbon(
                "<message from='\(Self.alice)/other' to='\(Self.bob)' type='chat'>\(event)</message>"
            ))
        try harness.deliver(
            "<message from='\(Self.alice)' to='\(Self.me)'><received xmlns='urn:xmpp:carbons:2'>"
                + "<forwarded xmlns='urn:xmpp:forward:0'><message from='\(Self.alice)'"
                + " to='\(Self.alice)'>\(event)</message></forwarded></received></message>")
        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat'>"
                + "<forwarded xmlns='urn:xmpp:forward:0'><message from='\(Self.alice)'>"
                + "\(event)</message></forwarded></message>")
        // From a resource of the account, not the account.
        try harness.deliver("<message from='\(Self.me)' to='\(Self.me)'>\(event)</message>")
        try await harness.barrier()

        #expect(try await engine.devices(of: account, version: .v2).isEmpty)
        #expect(pep.deviceIDs(of: account, version: .v2) == [own])

        // The PEP notification from the account's bare JID is the account's list.
        try harness.deliver("<message from='\(Self.alice)' to='\(Self.me)'>\(event)</message>")
        try await harness.barrier()
        #expect(try await engine.devices(of: account, version: .v2).map(\.deviceID) == [6666])
        try await waitUntil("listed again with this device") {
            pep.deviceIDs(of: account, version: .v2) == [6666, own]
        }
        await harness.stop()
    }

    // MARK: Direct messages

    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func directMessagesAreEncryptedAndDecrypted(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(with: Self.bob))
        await harness.session.omemo.setForcedVersion(version)
        await bob.manager.setForcedVersion(version)
        let chatID = try Self.chatID(harness, Self.bob)
        let account = try JID(Self.alice)

        let id = try await harness.session.send(text: "secret to bob", chatID: chatID)
        let row = try #require(try harness.database.message(id: id))
        #expect(row.encryption == .omemo)
        let stanza = try await Self.sent(try #require(row.originID), by: harness)
        #expect(!stanza.xml().contains("secret to bob"))
        #expect(ChatMessage(element: stanza)?.encrypted?.namespace == version.rawValue)
        #expect(try await bob.open(stanza, from: account).body == "secret to bob")

        let reply = try await bob.send("secret to alice", to: .direct(account), id: "r1")
        try harness.deliver(Self.delivered(reply, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "r1") != nil }
        let stored = try #require(try harness.message(originID: "r1"))
        #expect(stored.body == "secret to alice")
        #expect(stored.direction == .incoming)
        #expect(stored.encryption == .omemo)
        #expect(stored.kind == .text)
        let bobKey = try #require(
            try await harness.session.omemo.engine.devices(of: bob.jid, version: version).first?
                .identityKey)
        #expect(
            stored.senderDeviceFingerprint
                == harness.session.omemo.engine.fingerprint(of: bobKey, version: version))
        await harness.stop()
    }

    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func ourMessageFromAnotherDeviceIsReadFromItsCarbon(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep)
        // The account's other device starts after this one, so it finds it listed.
        let other = try OMEMOParty(Self.alice, pep: pep)
        await other.start()
        await other.manager.setForcedVersion(version)

        let sent = try await other.send("from my phone", to: .direct(bob.jid), id: "c1")
        try harness.deliver(
            Self.sentCarbon(Self.delivered(sent, from: "\(Self.alice)/phone", to: Self.bob)))
        try await waitUntil("stored") { try harness.message(originID: "c1") != nil }
        let stored = try #require(try harness.message(originID: "c1"))
        #expect(stored.body == "from my phone")
        #expect(stored.direction == .outgoing)
        #expect(stored.encryption == .omemo)
        #expect(try harness.chat(Self.bob) != nil)
        await harness.stop()
    }

    @Test func aMessageNeverGoesOutInTheClear() async throws {
        let pep = FakePEP()
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(with: Self.bob))
        let chatID = try Self.chatID(harness, Self.bob)
        let bob = try JID(Self.bob)

        await #expect(throws: SessionError.encryption(.noDevices(bob))) {
            try await harness.session.send(text: "secret", chatID: chatID)
        }

        let row = try #require(try harness.messages().first)
        #expect(row.state == .failed)
        #expect(row.errorText == "No OMEMO devices: bob@example.test")
        #expect(!harness.server.stanzas.contains { $0.xml().contains("secret") })

        // Pending from before, it fails at the next session without going out either.
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "p1",
                senderJID: Self.me, body: "queued secret", timestamp: Date(),
                encryption: .omemo))
        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("failed") { try harness.message(originID: "p1")?.state == .failed }
        #expect(!harness.server.stanzas.contains { $0.xml().contains("queued secret") })
        await harness.stop()
    }

    @Test func aCopyAlreadyStoredIsNotDecryptedAgain() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            try database.upsertIncoming(
                IncomingMessage(
                    accountID: accountID, chatID: try #require(chat.id),
                    senderJID: "\(Self.bob)/phone", body: "stored before", originID: "dup",
                    timestamp: Date()))
        }
        let preKeys = try harness.database.omemoPreKeys(accountID: harness.accountID, version: .v2)

        let account = try JID(Self.alice)
        let first = try await bob.send("decrypted once", to: .direct(account), id: "dup")
        try harness.deliver(Self.delivered(first, from: "\(Self.bob)/phone"))
        try await harness.barrier()

        // The copy was not decrypted: no session, and the key exchange's pre key is still here.
        #expect(try harness.messages().map(\.body) == ["stored before"])
        #expect(
            try harness.database.omemoSessions(
                accountID: harness.accountID, jid: Self.bob, version: .v2
            ).isEmpty)
        #expect(
            try harness.database.omemoPreKeys(accountID: harness.accountID, version: .v2).count
                == preKeys.count)

        // A new message is.
        let second = try await bob.send("new", to: .direct(account), id: "new")
        try harness.deliver(Self.delivered(second, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "new")?.body == "new" }
        await harness.stop()
    }

    @Test func aMessageThisDeviceCannotReadIsANotice() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // Bob shares presence, so a message that is here gets a receipt.
        let harness = try await Self.online(
            pep: pep,
            harness: SessionHarness(
                options: .init(
                    roster: .items(
                        ["<item jid='\(Self.bob)' subscription='both'/>"], version: "v1"))))
        let account = try JID(Self.alice)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: .v2)

        // For another device only.
        var stanza = try await bob.send("not for you", to: .direct(account), id: "n1")
        let text = stanza.xml().replacingOccurrences(of: "rid='\(own)'", with: "rid='12345'")
        stanza = try #require(SessionServer.elements(text).first)
        try harness.deliver(Self.delivered(stanza, from: "\(Self.bob)/phone"))
        // Its payload altered.
        let corrupted = try await bob.send("altered", to: .direct(account), id: "n2")
        var altered = corrupted
        var encrypted = try #require(
            altered.child("encrypted", namespace: OMEMO.OMEMOVersion.v2.rawValue))
        let payload = try #require(encrypted.child("payload", namespace: encrypted.namespace))
        var bytes = try #require(Data(base64Encoded: payload.text))
        bytes[0] ^= 1
        encrypted.children = encrypted.children.map { node in
            guard case .element(let child) = node, child.name == "payload" else { return node }
            return .element(
                Element(
                    "payload", namespace: child.namespace,
                    children: [.text(bytes.base64EncodedString())]))
        }
        altered.children = altered.children.map { node in
            guard case .element(let child) = node, child.name == "encrypted" else { return node }
            return .element(encrypted)
        }
        try harness.deliver(Self.delivered(altered, from: "\(Self.bob)/phone"))
        // The intact one after it still reads.
        let readable = try await bob.send("readable", to: .direct(account), id: "n3")
        try harness.deliver(Self.delivered(readable, from: "\(Self.bob)/phone"))
        try await waitUntil("all stored") { try harness.messages().count == 3 }

        let rows = try harness.messages()
        #expect(rows.map(\.body) == [Self.notForThisDevice, Self.cannotDecrypt, "readable"])
        #expect(rows.prefix(2).allSatisfy { $0.kind == .system && $0.encryption == .omemo })
        #expect(rows.last?.kind == .text)
        // Only the message that can be read is reported as received.
        try await waitUntil("receipt sent") { Self.receipts(harness) == ["n3"] }
        try await harness.barrier()
        #expect(Self.receipts(harness) == ["n3"])
        await harness.stop()
    }

    static func receipts(_ harness: SessionHarness) -> [String] {
        harness.server.stanzas.compactMap {
            $0.child("received", namespace: "urn:xmpp:receipts")?[attribute: "id"]
        }
    }

    static let notForThisDevice = AccountSession.notForThisDeviceText
    static let cannotDecrypt = AccountSession.cannotDecryptText

    @Test func plaintextLinksBesideAnEncryptedBodyAreDropped() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep)
        let account = try JID(Self.alice)

        var stanza = try await bob.send("just text", to: .direct(account), id: "l1")
        stanza.append(OOB.element(url: try #require(URL(string: "https://evil.example/x.png"))))
        try harness.deliver(Self.delivered(stanza, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "l1") != nil }
        let stored = try #require(try harness.message(originID: "l1"))
        #expect(stored.body == "just text")
        #expect(stored.kind == .text)
        let storedID = try #require(stored.id)
        #expect(try harness.database.attachments(messageID: storedID).isEmpty)
        await harness.stop()
    }

    @Test func anEnvelopeFarFromTheStanzasTimeIsRefused() async throws {
        let pep = FakePEP()
        let date = ManualDate()
        let bob = try OMEMOParty(Self.bob, pep: pep, now: { date.now })
        await bob.start()
        let harness = try await Self.online(pep: pep)
        let account = try JID(Self.alice)
        await bob.manager.setForcedVersion(.v2)

        // Bob's clock is two days ahead of the stanza's time.
        let skew = Date().timeIntervalSince(date.now) + 2 * 86_400
        date.advance(by: skew)
        let stanza = try await bob.send("from the future", to: .direct(account), id: "t1")
        try harness.deliver(Self.delivered(stanza, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "t1") != nil }
        #expect(try harness.message(originID: "t1")?.body == Self.cannotDecrypt)
        await harness.stop()
    }

    // MARK: Files

    @Test func anEncryptedFileCarriesItsLinkOnlyInside() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let link = "aesgcm://upload.example.test/f/photo.jpg#" + String(repeating: "ab", count: 44)
        let harness = try await Self.online(pep: pep) { database, accountID in
            try Self.omemoChat(with: Self.bob)(database, accountID)
            let chat = try #require(try database.chat(accountID: accountID, jid: Self.bob))
            // Uploaded before the session started, waiting to go out.
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: try #require(chat.id), originID: "f1",
                    senderJID: Self.me, body: nil, timestamp: Date(), encryption: .omemo,
                    kind: .file,
                    attachments: [
                        AttachmentDraft(
                            remoteURL: link, fileName: "photo.jpg", state: .local)
                    ]))
        }
        let stanza = try await Self.sent("f1", by: harness)
        #expect(!stanza.xml().contains("upload.example.test"))
        #expect(stanza.child("x", namespace: ChatMessage.oobNamespace) == nil)
        #expect(try await bob.open(stanza, from: try JID(Self.alice)).body == link)
        await harness.stop()
    }

    // MARK: Corrections

    /// The correction is encrypted; OMEMO 2 carries its `<replace/>` inside the envelope only
    /// (R77), legacy OMEMO in the clear.
    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func correctionsInAnOMEMOChatAreEncrypted(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(with: Self.bob))
        await harness.session.omemo.setForcedVersion(version)
        let chatID = try Self.chatID(harness, Self.bob)
        let account = try JID(Self.alice)

        let id = try await harness.session.send(text: "first", chatID: chatID)
        let original = try #require(try harness.database.message(id: id)?.originID)
        _ = try await bob.open(try await Self.sent(original, by: harness), from: account)

        try await harness.session.correct(messageID: id, newText: "second")
        func isCorrection(_ stanza: Element) -> Bool {
            stanza.name == "message" && stanza.id != original
                && stanza.child("encrypted", namespace: version.rawValue) != nil
        }
        try await waitUntil("correction sent") {
            harness.server.stanzas.contains(where: isCorrection)
        }
        let correction = try #require(harness.server.stanzas.last(where: isCorrection))
        #expect(!correction.xml().contains("second"))
        let clear = correction.child("replace", namespace: ChatMessage.correctionNamespace)
        let opened = try await bob.open(correction, from: account)
        #expect(opened.body == "second")
        switch version {
        case .v2:
            #expect(clear == nil)
            guard case .message(let message) = opened.content else {
                Issue.record("not a message")
                return
            }
            #expect(
                message.elements.first { $0.name == "replace" }?[attribute: "id"] == original)
        case .v03:
            #expect(clear?[attribute: "id"] == original)
        }
        // The row takes the new text: an encrypted correction of an encrypted message.
        #expect(try harness.database.message(id: id)?.body == "second")
        await harness.stop()
    }

    // MARK: Rooms

    static func roomHarness(pep: FakePEP, trust: RoomTrust, realJIDs: [JID: JID]) async throws
        -> SessionHarness
    {
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        let room = try JID(Self.room)
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(
                state: .joined, own: RoomOccupant(jid: try room.withResource("alice")),
                realJIDs: realJIDs))
        await harness.session.setRoomTrust(trust, for: room)
        return try await Self.online(pep: pep, harness: harness)
    }

    @Test func roomMessagesInBothDirections() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let room = try JID(Self.room)
        let account = try JID(Self.alice)
        pep.setMembers([account, bob.jid], affiliation: .member, of: room)
        let harness = try await Self.roomHarness(
            pep: pep, trust: RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: true),
            realJIDs: [try room.withResource("bob"): bob.jid])
        let chatID = try Self.chatID(harness, Self.room)
        await harness.session.resendPending(chatID: chatID)

        // From bob, by his real JID.
        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let fromBob = try await bob.send("hi room", to: .room(omemoRoom, chatID: 1), id: "g1")
        try harness.deliver(Self.delivered(fromBob, from: "\(Self.room)/bob"))
        try await waitUntil("stored") { try harness.message(originID: "g1") != nil }
        #expect(try harness.message(originID: "g1")?.body == "hi room")
        #expect(try harness.message(originID: "g1")?.encryption == .omemo)

        // From us: bob reads it, and the room's reflection marks it sent, with the room's id.
        let id = try await harness.session.send(text: "hi bob", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let ours = try await Self.sent(originID, by: harness)
        #expect(!ours.xml().contains("hi bob"))
        #expect(try await bob.open(ours, from: account, recipient: .room(room)).body == "hi bob")
        var reflection = ours
        reflection.append(
            Element(
                "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                attributes: ["by": Self.room, "id": "room-1"]))
        try harness.deliver(Self.delivered(reflection, from: "\(Self.room)/alice"))
        try await waitUntil("sent") { try harness.database.message(id: id)?.state == .sent }
        #expect(try harness.database.message(id: id)?.archiveID == "room-1")
        #expect(try harness.messages().count == 2)
        await harness.stop()
    }

    @Test func roomsThatHideAddressesTakeNoEncryptedMessage() async throws {
        let pep = FakePEP()
        let harness = try await Self.roomHarness(
            pep: pep, trust: RoomTrust(nonAnonymous: false, membersOnly: true), realJIDs: [:])
        let chatID = try Self.chatID(harness, Self.room)
        await harness.session.resendPending(chatID: chatID)

        await #expect(throws: SessionError.encryption(.roomNotSuitable)) {
            try await harness.session.send(text: "secret", chatID: chatID)
        }
        #expect(!harness.server.stanzas.contains { $0.xml().contains("secret") })
        await harness.stop()
    }
}
