import Foundation
import OMEMO
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A room lifecycle whose real JIDs a test can change: who wrote a room message becomes known
/// only later.
actor ChangingRoomLifecycle: RoomLifecycle {
    let own: RoomOccupant
    private var realJIDs: [JID: JID] = [:]

    init(own: RoomOccupant) {
        self.own = own
    }

    func learn(_ occupant: JID, is realJID: JID) {
        realJIDs[occupant] = realJID
    }

    func sessionStarted(ownJID: JID) async {}
    func sessionResumed() async {}
    func sessionEnded(resumable: Bool) async {}
    func handle(presence: Element) async -> Bool { false }
    func handle(message: Element) async -> Bool { false }
    func join(chatID: Int64) async {}
    func leave(chatID: Int64) async {}
    func changeNick(chatID: Int64, to nick: String) async {}
    func state(of chatID: Int64) async -> RoomState { .joined }
    func ownOccupant(in chatID: Int64) async -> RoomOccupant? { own }
    func realJID(of occupant: JID) async -> JID? { realJIDs[occupant] }
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? { nil }
    func reloadWanted() async {}
    func rosterItemRemoved(_ jid: JID) async {}
}

/// Fix round 2: no stall from anyone's messages, resends against the trust of the moment, the
/// chat's setting at send time, reactions (R47), the version rule, notices that a later copy
/// can still turn into the message, and where answers to room messages go.
@Suite(.timeLimit(.minutes(1))) struct OMEMOFixRoundTests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"
    static let stranger = "stranger@evil.test"
    static let room = "room@conference.example.test"

    /// The device ids an `<encrypted/>` element has a key for, whatever the version.
    static func keyedDevices(_ stanza: Element) -> Set<UInt32> {
        guard let encrypted = ChatMessage(element: stanza)?.encrypted,
            let header = encrypted.child("header", namespace: encrypted.namespace)
        else { return [] }
        let ns = encrypted.namespace
        let keys =
            header.children("key", namespace: ns)
            + header.children("keys", namespace: ns).flatMap { $0.children("key", namespace: ns) }
        return Set(keys.compactMap { $0[attribute: "rid"].flatMap(UInt32.init) })
    }

    /// `stanza` with one byte of its `<payload>` changed.
    static func corrupted(_ stanza: Element) throws -> Element {
        var copy = stanza
        copy.children = try stanza.children.map { node in
            guard case .element(var encrypted) = node, encrypted.name == "encrypted" else {
                return node
            }
            encrypted.children = try encrypted.children.map { inner in
                guard case .element(let payload) = inner, payload.name == "payload" else {
                    return inner
                }
                var bytes = try #require(Data(base64Encoded: payload.text))
                bytes[bytes.count / 2] ^= 1
                return .element(
                    Element(
                        "payload", namespace: payload.namespace,
                        children: [.text(bytes.base64EncodedString())]))
            }
            return .element(encrypted)
        }
        return copy
    }

    /// `stanza` with the last byte (in the MAC) of every `<key>` changed: the key no longer
    /// authenticates on the session.
    static func corruptedKeys(_ stanza: Element) throws -> Element {
        func corrupt(_ element: Element) throws -> Element {
            var copy = element
            if element.name == "key" {
                var bytes = try #require(Data(base64Encoded: element.text))
                bytes[bytes.count - 1] ^= 1
                copy.children = [.text(bytes.base64EncodedString())]
                return copy
            }
            copy.children = try element.children.map { node in
                guard case .element(let child) = node else { return node }
                return .element(try corrupt(child))
            }
            return copy
        }
        return try corrupt(stanza)
    }

    /// `stanza` with the key of the device `from` given to device `to` instead.
    static func rekeyed(_ stanza: Element, from: UInt32, to: UInt32) throws -> Element {
        let text = stanza.xml().replacingOccurrences(of: "rid='\(from)'", with: "rid='\(to)'")
        return try #require(SessionServer.elements(text).first)
    }

    /// A session on `pep`, online, with the responder asked first for IQs it wants to answer
    /// (or leave unanswered with `[]`).
    static func online(
        pep: FakePEP, options: SessionServer.Options = SessionServer.Options(),
        seed: @escaping (AppDatabase, Int64) throws -> Void = { _, _ in },
        before: (@Sendable (Element) -> [String]?)? = nil
    ) async throws -> SessionHarness {
        let harness = try await SessionHarness(options: options, seed: seed)
        let account = try JID(alice)
        harness.server.setResponder { iq in
            if let answer = before?(iq) { return answer }
            return pep.answer(iq, from: account).map { [$0.xml()] }
        }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        return harness
    }

    static func omemoChat(_ jid: String) -> (AppDatabase, Int64) throws -> Void {
        { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: jid, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
    }

    static func deliver(_ stanza: Element, from: String, to harness: SessionHarness) throws {
        try harness.deliver(OMEMOPipelineTests.delivered(stanza, from: from))
    }

    /// OMEMO requests (device lists and bundles) sent to `jid`.
    static func iqs(to jid: String, _ harness: SessionHarness) -> Int {
        harness.server.stanzas.filter { iq in
            guard iq.name == "iq", iq.to?.bare.description == jid,
                let node = iq.child("pubsub", namespace: PubSub.namespace)?
                    .child("items", namespace: PubSub.namespace)?[attribute: "node"]
            else { return false }
            return node.hasPrefix("eu.siacs.conversations.axolotl")
                || node.hasPrefix("urn:xmpp:omemo:2")
        }.count
    }

    /// Bob writes to the session's account, and the session answers once: from then on Bob's
    /// messages are plain ratchet messages, without a key exchange.
    static func establish(_ bob: OMEMOParty, with harness: SessionHarness) async throws {
        let account = try JID(alice)
        let first = try await bob.send("hello", to: .direct(account), id: "hello")
        try deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "hello") != nil }
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try await harness.session.send(text: "hi bob", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let reply = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(reply, from: account).body == "hi bob")
    }

    // MARK: C2: nobody stalls the session

    @Test func aStrangerCannotStallTheSession() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        // The stranger's server is a gate that never opens: it answers nothing, and the
        // connection's and the session's test clocks never move, so nothing held there times
        // out.
        let harness = try await Self.online(
            pep: pep, seed: Self.omemoChat(Self.bob),
            before: { iq in iq.to?.bare.description == Self.stranger ? [] : nil })
        await harness.session.omemo.setForcedVersion(.v03)
        try await Self.establish(bob, with: harness)
        let account = try JID(Self.alice)

        // Five legacy messages from a device the account has no session with, from someone
        // who is neither a contact nor had a chat before.
        for index in 1...5 {
            let message = try await bob.send(
                "from afar \(index)", to: .direct(account), id: "s\(index)")
            try Self.deliver(message, from: "\(Self.stranger)/x", to: harness)
        }
        let after = try await bob.send("still read", to: .direct(account), id: "after")
        try Self.deliver(after, from: "\(Self.bob)/phone", to: harness)

        // A session waiting on the gate could never store bob's message, however long this
        // waits: the bound only says how long a failing run takes, not how fast a passing one is.
        try await waitUntil("bob's message stored", timeout: .seconds(30)) {
            try harness.message(originID: "after")?.body == "still read"
        }
        // No repair for a stranger (R48), so nothing is asked of their server at all.
        #expect(Self.iqs(to: Self.stranger, harness) == 0)
        await harness.stop()
    }

    @Test func aContactsRepairRunsOffTheEventLoopOnceAnHour() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        // Once closed, bob's server is a gate that never opens again: it answers nothing, and
        // the connection's and the session's test clocks never move, so nothing held there
        // times out.
        let bobsServerHangs = Locked(false)
        let harness = try await Self.online(
            pep: pep, seed: Self.omemoChat(Self.bob),
            before: { iq in
                bobsServerHangs.value && iq.to?.bare.description == Self.bob ? [] : nil
            })
        await harness.session.omemo.setForcedVersion(.v03)
        try await Self.establish(bob, with: harness)
        let account = try JID(Self.alice)
        bobsServerHangs.set(true)
        let before = Self.iqs(to: Self.bob, harness)

        // Two broken messages ask for a repair; two more within the hour ask for nothing.
        for index in 1...4 {
            let message = try await bob.send(
                "broken \(index)", to: .direct(account), id: "b\(index)")
            try Self.deliver(
                try Self.corruptedKeys(message), from: "\(Self.bob)/phone", to: harness)
        }
        let after = try await bob.send("still read", to: .direct(account), id: "after")
        try Self.deliver(after, from: "\(Self.bob)/phone", to: harness)

        // A session waiting on the gate could never store bob's message, however long this
        // waits: the bound only says how long a failing run takes, not how fast a passing one is.
        try await waitUntil("bob's message stored", timeout: .seconds(30)) {
            try harness.message(originID: "after")?.body == "still read"
        }
        // The repair started in the background, reading bob's list once; it hangs there.
        try await waitUntil("list asked for") { Self.iqs(to: Self.bob, harness) == before + 1 }
        try await harness.barrier()
        #expect(Self.iqs(to: Self.bob, harness) == before + 1)
        await harness.stop()
    }

    @Test func aContactsNewDeviceIsReadWithoutWaitingForItsList() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // Once closed, bob's server is a gate that never opens again: it answers nothing, and
        // the connection's and the session's test clocks never move, so nothing held there
        // times out.
        let bobsServerHangs = Locked(false)
        let harness = try await Self.online(
            pep: pep, seed: Self.omemoChat(Self.bob),
            before: { iq in
                bobsServerHangs.value && iq.to?.bare.description == Self.bob ? [] : nil
            })
        // The account writes first, so bob's phone is known from his list and not read again.
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try await harness.session.send(text: "hi bob", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let hello = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(hello, from: account).body == "hi bob")

        // Bob starts a tablet the account has not heard of; its list is read again.
        let tablet = try OMEMOParty(Self.bob, pep: pep)
        await tablet.start()
        bobsServerHangs.set(true)
        let before = Self.iqs(to: Self.bob, harness)
        let first = try await tablet.send("from the tablet", to: .direct(account), id: "t1")
        try Self.deliver(first, from: "\(Self.bob)/tablet", to: harness)
        let after = try await bob.send("still read", to: .direct(account), id: "after")
        try Self.deliver(after, from: "\(Self.bob)/phone", to: harness)

        // A session waiting on the gate could store neither; the bound only says how long a
        // failing run takes.
        try await waitUntil("both stored", timeout: .seconds(30)) {
            try harness.message(originID: "t1")?.body == "from the tablet"
                && harness.message(originID: "after")?.body == "still read"
        }
        try await waitUntil("list asked for") { Self.iqs(to: Self.bob, harness) > before }
        await harness.stop()
    }

    /// A sender cannot multiply repairs by naming new device ids: one per bare JID an hour.
    @Test func repairsAreAskedOncePerJIDWhateverTheDeviceIDs() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        for party in [alice, bob] { await party.manager.setForcedVersion(.v03) }
        // A working session, so bob's later messages are plain ratchet messages.
        let first = try await bob.send("hello", to: .direct(alice.jid))
        #expect(try await alice.open(first, from: bob.jid).body == "hello")
        let answer = try await alice.send("hi", to: .direct(bob.jid))
        #expect(try await bob.open(answer, from: alice.jid).body == "hi")
        let bobID = try await bob.deviceID(.v03)
        let before = alice.sender.sent.count

        for sid in [101, 102, 103] as [UInt32] {
            let message = try await bob.send("from \(sid)", to: .direct(alice.jid))
            let text = message.xml().replacingOccurrences(
                of: "sid='\(bobID)'", with: "sid='\(sid)'")
            let relabelled = try #require(SessionServer.elements(text).first)
            let encrypted = try #require(ChatMessage(element: relabelled)?.encrypted)
            let result = await alice.manager.decrypt(
                encrypted, from: bob.jid, recipient: nil, known: true)
            #expect(result?.content == .failed(.noSession))
            // Each repair has run before the next device id comes: the hourly limit, not the
            // queue's one entry per JID, keeps the next from being asked.
            await alice.manager.settled()
        }

        let bundleRequests = alice.sender.sent.dropFirst(before).filter { iq in
            iq.name == "iq"
                && iq.child("pubsub", namespace: PubSub.namespace)?
                    .child("items", namespace: PubSub.namespace)?[attribute: "node"]?
                    .hasPrefix(OMEMOBundle.node(version: .v03, deviceID: 0).dropLast()) == true
        }
        #expect(bundleRequests.count == 1)
    }

    @Test func sealedStanzasCarryNoClearLinksOrFileMetadata() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        var plain = ChatMessage.text("https://files.example/secret.pdf", to: bob.jid, id: "f1")
        plain.append(
            OOB.element(url: try #require(URL(string: "https://files.example/secret.pdf"))))
        plain.append(Element("file-sharing", namespace: StatelessFileSharing.namespace))
        #expect(try await alice.manager.send(plain, to: .direct(bob.jid)))
        let stanza = try #require(alice.sender.messages.last)
        #expect(!stanza.xml().contains("files.example"))
        #expect(stanza.child("x", namespace: ChatMessage.oobNamespace) == nil)
        #expect(stanza.child("file-sharing", namespace: StatelessFileSharing.namespace) == nil)
    }

    // MARK: I1: a resend is encrypted again

    @Test func aResendIsEncryptedForTheTrustOfThatMoment() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob2 = try OMEMOParty(Self.bob, pep: pep)
        let bob1 = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob2, bob1] { await party.start() }
        await alice.manager.setForcedVersion(.v2)
        let bob = try JID(Self.bob)
        let plain = ChatMessage.text("secret", to: bob, id: "r1")

        alice.sender.setOffline(true)
        #expect(try await !alice.manager.send(plain, to: .direct(bob)))
        // Offline, the user refuses bob's second device.
        try await alice.manager.engine.setTrust(
            .distrusted, for: DeviceAddress(jid: bob, deviceID: try await bob2.deviceID(.v2)),
            version: .v2)
        alice.sender.setOffline(false)
        #expect(try await alice.manager.send(plain, to: .direct(bob)))

        let stanza = try #require(alice.sender.messages.last)
        #expect(!Self.keyedDevices(stanza).contains(try await bob2.deviceID(.v2)))
        #expect(try await bob1.open(stanza, from: alice.jid).body == "secret")
    }

    // MARK: I2: the chat's setting at send time

    @Test func aMessageQueuedInTheClearIsEncryptedOnceTheChatIsOMEMO() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep) { database, accountID in
            for jid in [Self.bob, "nobody@example.test"] {
                var chat = try database.ensureChat(accountID: accountID, jid: jid, kind: .direct)
                // Written while the chat was in the clear; switched to OMEMO before it went out.
                _ = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: accountID, chatID: try #require(chat.id),
                        originID: jid == Self.bob ? "q1" : "q2", senderJID: Self.me,
                        body: "queued \(jid)", timestamp: Date()))
                chat.encryption = .omemo
                try database.updateChat(chat)
            }
        }

        let stanza = try await OMEMOPipelineTests.sent("q1", by: harness)
        #expect(ChatMessage(element: stanza)?.encrypted != nil)
        #expect(try await bob.open(stanza, from: try JID(Self.alice)).body == "queued \(Self.bob)")
        #expect(try harness.message(originID: "q1")?.encryption == .omemo)
        // Where it cannot be encrypted it fails, and never goes out.
        try await waitUntil("failed") { try harness.message(originID: "q2")?.state == .failed }
        #expect(!harness.server.stanzas.contains { $0.xml().contains("queued") })
        await harness.stop()
    }

    // MARK: I3: reactions (R47)

    @Test func reactionsGoInsideTheOMEMO2Envelope() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let message = try await bob.send("react to me", to: .direct(account), id: "t1")
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "t1") != nil }
        let target = try #require(try harness.message(originID: "t1")?.id)
        #expect(await harness.session.canReact(chatID: chatID))

        let before = harness.server.stanzas.count
        try await harness.session.react(messageID: target, emojis: ["👍"])
        try await waitUntil("sent") {
            harness.server.stanzas.dropFirst(before).contains {
                $0.name == "message" && ChatMessage(element: $0)?.encrypted != nil
            }
        }
        let stanza = try #require(
            harness.server.stanzas.dropFirst(before).last {
                $0.name == "message" && ChatMessage(element: $0)?.encrypted != nil
            })
        #expect(stanza.child("reactions", namespace: ChatMessage.reactionsNamespace) == nil)
        #expect(!stanza.xml().contains("👍"))
        let opened = try await bob.open(stanza, from: account)
        guard case .message(let decrypted) = opened.content else {
            Issue.record("Not a message: \(opened.content)")
            return
        }
        let reactions = try #require(
            decrypted.elements.first { $0.name == "reactions" })
        #expect(reactions[attribute: "id"] == "t1")
        #expect(
            reactions.children("reaction", namespace: ChatMessage.reactionsNamespace).map(\.text)
                == ["👍"])
        await harness.stop()
    }

    @Test func legacyOMEMOChatsTakeNoReactions() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep) { database, accountID in
            try Self.omemoChat(Self.bob)(database, accountID)
            _ = try database.ensureChat(
                accountID: accountID, jid: "plain@example.test", kind: .direct)
        }
        await harness.session.omemo.setForcedVersion(.v03)
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let plainChat = try #require(try harness.chat("plain@example.test")?.id)
        let message = try await bob.send("react to me", to: .direct(account), id: "t1")
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "t1") != nil }
        let target = try #require(try harness.message(originID: "t1")?.id)

        #expect(await !harness.session.canReact(chatID: chatID))
        #expect(await harness.session.canReact(chatID: plainChat))
        await #expect(throws: SessionError.encryption(.reactionsNeedOMEMO2)) {
            try await harness.session.react(messageID: target, emojis: ["👍"])
        }
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.xml().contains("👍") })
        #expect(try harness.database.reactions(messageID: target).isEmpty)
        await harness.stop()
    }

    @Test func clearReactionsCountOnlyFromTheChatsPeer() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep) { database, accountID in
            try Self.omemoChat(Self.bob)(database, accountID)
            let chat = try #require(try database.chat(accountID: accountID, jid: Self.bob))
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: try #require(chat.id), originID: "m1",
                    senderJID: Self.me, body: "mine", timestamp: Date(), encryption: .omemo))
        }
        let account = try JID(Self.alice)
        let mine = try #require(try harness.message(originID: "m1")?.id)
        func reaction(_ emoji: String, from: String, to: String) -> String {
            "<message from='\(from)' to='\(to)' type='chat' id='\(UUID().uuidString)'>"
                + "<reactions xmlns='urn:xmpp:reactions:0' id='m1'><reaction>\(emoji)</reaction>"
                + "</reactions></message>"
        }

        // From bob, in the clear (as Conversations sends them): taken.
        try harness.deliver(reaction("👍", from: "\(Self.bob)/phone", to: Self.me))
        // From another device of the account, copied as a sent carbon: not the chat's peer.
        try harness.deliver(
            OMEMOPipelineTests.sentCarbon(
                reaction("😡", from: "\(Self.alice)/phone", to: Self.bob)))
        // Beside an encrypted message from bob: not his to authenticate.
        var encrypted = try await bob.send("a message", to: .direct(account), id: "e1")
        encrypted.append(
            Element(
                "reactions", namespace: ChatMessage.reactionsNamespace, attributes: ["id": "m1"],
                children: [
                    .element(
                        Element(
                            "reaction", namespace: ChatMessage.reactionsNamespace,
                            children: [.text("🎉")]))
                ]))
        try Self.deliver(encrypted, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "e1") != nil }
        try await harness.barrier()

        let reactions = try harness.database.reactions(messageID: mine)
        #expect(reactions.map(\.reactorKey) == [Self.bob])
        #expect(reactions.first?.emojis == ["👍"])
        #expect(try harness.message(originID: "e1")?.body == "a message")
        await harness.stop()
    }

    // MARK: I5: notices give way to a copy that decrypts

    @Test func aCorruptedCopyGivesWayToTheIntactOne() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep)
        let account = try JID(Self.alice)
        let message = try await bob.send("intact", to: .direct(account), id: "c1")

        try Self.deliver(try Self.corrupted(message), from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("notice") {
            try harness.message(originID: "c1")?.body == AccountSession.cannotDecryptText
        }
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("upgraded") { try harness.message(originID: "c1")?.body == "intact" }

        let row = try #require(try harness.message(originID: "c1"))
        #expect(row.kind == .text)
        #expect(row.encryption == .omemo)
        #expect(row.senderDeviceFingerprint != nil)
        #expect(try harness.messages().count == 1)
        #expect(try harness.chat(Self.bob)?.unreadCount == 1)
        await harness.stop()
    }

    @Test func aRoomMessageIsReadOnceItsSenderIsKnown() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let room = try JID(Self.room)
        let account = try JID(Self.alice)
        pep.setMembers([account, bob.jid], affiliation: .member, of: room)
        let lifecycle = ChangingRoomLifecycle(
            own: RoomOccupant(jid: try room.withResource("alice")))
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        await harness.session.setRoomLifecycle(lifecycle)
        await harness.session.setRoomTrust(
            RoomTrust(nonAnonymous: true, membersOnly: true), for: room)
        _ = try await OMEMOPipelineTests.online(pep: pep, harness: harness)
        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let message = try await bob.send("hello room", to: .room(omemoRoom, chatID: 1), id: "g1")

        // Before the room said who bob is.
        try Self.deliver(message, from: "\(Self.room)/bob", to: harness)
        try await waitUntil("notice") {
            try harness.message(originID: "g1")?.body == AccountSession.cannotDecryptText
        }
        await lifecycle.learn(try room.withResource("bob"), is: bob.jid)
        try Self.deliver(message, from: "\(Self.room)/bob", to: harness)
        try await waitUntil("upgraded") {
            try harness.message(originID: "g1")?.body == "hello room"
        }
        #expect(try harness.messages().count == 1)
        await harness.stop()
    }

    @Test func aRedeliveredUnreadableMessageGetsNoReceipt() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(
            pep: pep,
            options: .init(
                roster: .items(["<item jid='\(Self.bob)' subscription='both'/>"], version: "v1")))
        let account = try JID(Self.alice)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: .v2)
        let message = try Self.rekeyed(
            try await bob.send("not here", to: .direct(account), id: "u1"), from: own, to: 4242)

        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "u1") != nil }
        try await harness.barrier()

        #expect(OMEMOPipelineTests.receipts(harness).isEmpty)
        #expect(try harness.messages().count == 1)
        await harness.stop()
    }

    // MARK: Answers to room messages, and unreadable corrections

    @Test func answersToARoomMessageGoToTheSendersRealJID() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let room = try JID(Self.room)
        let account = try JID(Self.alice)
        pep.setMembers([account, bob.jid], affiliation: .member, of: room)
        let harness = try await OMEMOPipelineTests.roomHarness(
            pep: pep, trust: RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: true),
            realJIDs: [try room.withResource("bob"): bob.jid])
        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let before = harness.server.stanzas.count

        // Bob's first message is a key exchange: it is answered.
        let message = try await bob.send("first", to: .room(omemoRoom, chatID: 1), id: "k1")
        try Self.deliver(message, from: "\(Self.room)/bob", to: harness)
        try await waitUntil("answered") {
            harness.server.stanzas.dropFirst(before).contains {
                $0.name == "message" && ChatMessage(element: $0)?.encrypted != nil
            }
        }
        let answers = harness.server.stanzas.dropFirst(before).filter {
            $0.name == "message" && ChatMessage(element: $0)?.encrypted != nil
        }
        #expect(answers.allSatisfy { $0.to == bob.jid && $0.type == "chat" })
        #expect(!answers.contains { $0.to?.bare == room })
        await harness.stop()
    }

    @Test func anUnreadableCorrectionLeavesTheTextAlone() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep)
        let account = try JID(Self.alice)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: .v2)
        let original = try await bob.send("original", to: .direct(account), id: "o1")
        try Self.deliver(original, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "o1") != nil }

        let correction = ChatMessage.correction("changed", replacing: "o1", to: account, id: "c1")
        _ = try await bob.manager.send(correction, to: .direct(account))
        let sent = try #require(bob.sender.messages.last)
        try Self.deliver(
            try Self.rekeyed(sent, from: own, to: 4242), from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("notice") { try harness.message(originID: "c1") != nil }

        #expect(try harness.message(originID: "o1")?.body == "original")
        #expect(try harness.message(originID: "o1")?.editedAt == nil)
        await harness.stop()
    }

    // MARK: M13: a file to an OMEMO contact

    @Test func anEncryptedFileGoesOutEncryptedAfterItsUpload() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let (media, environment) = try SessionFilesTests.mediaRig()
        defer { media.cleanUp() }
        let harness = try await SessionHarness(media: environment, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        harness.server.setResponder { iq in
            SessionFilesTests.uploadResponder(iq)
                ?? pep.answer(iq, from: account).map { [$0.xml()] }
        }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("secret".utf8))

        let id = try await harness.session.sendFile(url: file, chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let stanza = try await OMEMOPipelineTests.sent(originID, by: harness)

        // Nothing of the upload host, the name or the link in the clear; no file metadata.
        let xml = stanza.xml()
        #expect(!xml.contains("upload.example.test") && !xml.contains("notes"))
        #expect(stanza.child("x", namespace: ChatMessage.oobNamespace) == nil)
        #expect(stanza.child("file-sharing", namespace: StatelessFileSharing.namespace) == nil)
        let link = try #require(try await bob.open(stanza, from: account).body)
        #expect(link.hasPrefix("aesgcm://upload.example.test/"))
        #expect(try harness.database.message(id: id)?.encryption == .omemo)
        await harness.stop()
    }

    // MARK: M5: nothing after stop

    @Test func aStoppedManagerTakesNoMoreWork() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        let stanza = try await bob.send("late", to: .direct(alice.jid))
        await alice.manager.stop()

        await #expect(throws: EncryptionError.notReady) {
            try await alice.manager.send(ChatMessage.text("x", to: bob.jid), to: .direct(bob.jid))
        }
        let encrypted = try #require(ChatMessage(element: stanza)?.encrypted)
        #expect(
            await alice.manager.decrypt(encrypted, from: bob.jid, recipient: nil, known: true)
                == nil)
        #expect(alice.sender.messages.isEmpty)
    }
}
