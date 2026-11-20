import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// R63 (a): a new direct chat starts with OMEMO when the contact publishes OMEMO devices, in
/// either version, and in the clear otherwise; an OMEMO message turns a chat in the clear to
/// OMEMO, and the user may turn it off again. Rooms start in the clear.
@Suite struct EncryptionDefaultTests {
    static let bob = OMEMOFixRoundTests.bob
    static let alice = OMEMOFixRoundTests.alice

    /// A chat made as the app makes one (a contact sheet, an `xmpp:` link): the store's row.
    static func newChat(_ jid: String, kind: ChatKind = .direct, _ harness: SessionHarness)
        throws -> Int64
    {
        try #require(
            try harness.database.ensureChat(accountID: harness.accountID, jid: jid, kind: kind).id)
    }

    @Test(arguments: [OMEMO.OMEMOVersion.v03, .v2])
    func aNewChatWithAContactThatPublishesOMEMOStartsEncrypted(_ version: OMEMO.OMEMOVersion)
        async throws
    {
        // Bob publishes a device in this version only.
        let pep = FakePEP()
        pep.put(
            DeviceList.element(version: version, devices: [4242]), id: "current",
            node: DeviceList.node(version: version), of: try JID(Self.bob))
        let harness = try await OMEMOFixRoundTests.online(pep: pep)
        let chatID = try Self.newChat(Self.bob, harness)

        await harness.session.prepareChat(chatID: chatID)
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)
        #expect(try !harness.database.awaitsEncryptionDefault(chatID: chatID))
        await harness.stop()
    }

    @Test func aNewChatWithAContactWithoutOMEMOStartsInTheClear() async throws {
        let pep = FakePEP()
        let harness = try await OMEMOFixRoundTests.online(pep: pep)
        let chatID = try Self.newChat(Self.bob, harness)

        await harness.session.prepareChat(chatID: chatID)
        #expect(try harness.chat(Self.bob)?.encryption == EncryptionMode.none)
        #expect(try !harness.database.awaitsEncryptionDefault(chatID: chatID))
        await harness.stop()
    }

    @Test func theFirstMessageWaitsForTheDefault() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await OMEMOFixRoundTests.online(pep: pep)
        let chatID = try Self.newChat(Self.bob, harness)

        // Sent before the chat was ever opened.
        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(!sent.xml().contains("first words"))
        #expect(try await bob.open(sent, from: try JID(Self.alice)).body == "first words")
        await harness.stop()
    }

    @Test func roomsStartInTheClear() async throws {
        let pep = FakePEP()
        let harness = try await OMEMOFixRoundTests.online(pep: pep)
        let chatID = try Self.newChat("room@conference.example.test", kind: .room, harness)

        await harness.session.prepareChat(chatID: chatID)
        #expect(try harness.database.chat(id: chatID)?.encryption == EncryptionMode.none)
        await harness.stop()
    }

    @Test func anOMEMOMessageTurnsAChatInTheClearToOMEMO() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        // The user chose the clear before.
        let harness = try await OMEMOFixRoundTests.online(pep: pep) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            try database.setEncryptionDefault(chatID: try #require(chat.id), omemo: false)
        }
        await harness.session.omemo.setForcedVersion(.v03)
        let account = try JID(Self.alice)

        let first = try await bob.send("hello", to: .direct(account), id: "hello")
        try OMEMOFixRoundTests.deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "hello") != nil }
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)

        // Turned off again: a message in the clear leaves it off; the next OMEMO one turns it
        // on again.
        var chat = try #require(try harness.chat(Self.bob))
        chat.encryption = .none
        try harness.database.updateChat(chat)
        try harness.deliver(
            AccountSessionTests.chat(
                "\(Self.bob)/phone", id: "plain", body: "hi",
                extra: ReplyPrivacyTests.origin("plain")))
        try await waitUntil("stored") { try harness.message(originID: "plain") != nil }
        #expect(try harness.chat(Self.bob)?.encryption == EncryptionMode.none)

        let again = try await bob.send("again", to: .direct(account), id: "again")
        try OMEMOFixRoundTests.deliver(again, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "again") != nil }
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)
        await harness.stop()
    }

    @Test func anOMEMOMessageStartsANewChatEncryptedWithoutAskingAnything() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        let harness = try await OMEMOFixRoundTests.online(pep: pep)
        await harness.session.omemo.setForcedVersion(.v03)

        let first = try await bob.send("hello", to: .direct(try JID(Self.alice)), id: "hello")
        try OMEMOFixRoundTests.deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "hello") != nil }
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)
        await harness.stop()
    }

    /// Waits until the chat's next try is planned and its timer waits on the session clock,
    /// so an advance reaches it.
    static func waitForRetry(_ chatID: Int64, _ harness: SessionHarness) async throws {
        let deadline = harness.sessionClock.now.advanced(by: AccountSession.defaultRetryInterval)
        try await waitUntil("a later try planned") {
            await harness.session.defaultRetries[chatID] != nil
                && harness.sessionClock.nextDeadline == deadline
        }
    }

    // MARK: I8, I9: an unread list decides nothing, and the message waits as pending

    /// Whether `iq` asks for one of bob's device lists.
    static func asksBobsList(_ iq: Element) -> Bool {
        guard iq.to?.bare.description == bob,
            let node = iq.child("pubsub", namespace: PubSub.namespace)?
                .child("items", namespace: PubSub.namespace)?[attribute: "node"]
        else { return false }
        return node == DeviceList.node(version: .v03) || node == DeviceList.node(version: .v2)
    }

    @Test func aListThatCannotBeReadLeavesTheChatWaiting() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // Bob's server fails to answer for his lists until it recovers.
        let broken = Locked(true)
        let harness = try await OMEMOFixRoundTests.online(
            pep: pep,
            before: { iq in
                guard broken.value, Self.asksBobsList(iq) else { return nil }
                return [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
            })
        let chatID = try Self.newChat(Self.bob, harness)

        await harness.session.prepareChat(chatID: chatID)
        #expect(try harness.database.awaitsEncryptionDefault(chatID: chatID))
        #expect(try harness.chat(Self.bob)?.encryption == EncryptionMode.none)

        // Written now, it waits as pending: never in the clear.
        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await harness.barrier()
        #expect(try harness.database.message(id: id)?.state == .pending)
        #expect(harness.server.messages(id: originID).isEmpty)
        #expect(!harness.server.stanzas.contains { $0.xml().contains("first words") })

        // The lists read on a later try: the chat turns to OMEMO and the message goes, sealed.
        // The lookup failed and the next try waits on the clock; then bob's server recovers.
        try await Self.waitForRetry(chatID, harness)
        broken.set(false)
        await harness.sessionClock.advance(by: AccountSession.defaultRetryInterval)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(!sent.xml().contains("first words"))
        #expect(try await bob.open(sent, from: try JID(Self.alice)).body == "first words")
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)
        await harness.stop()
    }

    @Test func aChatOpenedOfflineKeepsWaiting() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await SessionHarness()
        let account = try JID(Self.alice)
        harness.server.setResponder { iq in pep.answer(iq, from: account).map { [$0.xml()] } }
        let chatID = try Self.newChat(Self.bob, harness)

        // Not online yet: nothing can be read, so nothing is decided.
        await harness.session.prepareChat(chatID: chatID)
        #expect(try harness.database.awaitsEncryptionDefault(chatID: chatID))
        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)

        try await harness.goOnline()
        await harness.session.omemo.settled()
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(!sent.xml().contains("first words"))
        #expect(try await bob.open(sent, from: account).body == "first words")
        await harness.stop()
    }

    @Test func theRowIsThereBeforeTheLookupEnds() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // Bob's server takes its time: his lists are answered only when the test says so.
        let held = Locked<[Element]>([])
        let harness = try await OMEMOFixRoundTests.online(
            pep: pep,
            before: { iq in
                guard Self.asksBobsList(iq) else { return nil }
                held.withLock { $0.append(iq) }
                return []
            })
        let chatID = try Self.newChat(Self.bob, harness)
        let account = try JID(Self.alice)

        let sending = Task { try await harness.session.send(text: "first words", chatID: chatID) }
        try await waitUntil("the row written") {
            try harness.database.page(chatID: chatID, before: nil, limit: 5).contains {
                $0.body == "first words" && $0.state == .pending
            }
        }
        let id = try await sending.value
        let originID = try #require(try harness.database.message(id: id)?.originID)
        #expect(harness.server.messages(id: originID).isEmpty)

        try await waitUntil("lists asked") { held.value.count == 2 }
        for request in held.value {
            let answer = try #require(pep.answer(request, from: account))
            try harness.deliver(answer.xml())
        }
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(sent, from: account).body == "first words")
        await harness.stop()
    }

    // MARK: C2: content that came encrypted

    @Test func anEncryptedCorrectionOfAPlainMessageIsNeverQuotedInTheClear() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        let harness = try await OMEMOFixRoundTests.online(pep: pep) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            try database.setEncryptionDefault(chatID: try #require(chat.id), omemo: false)
        }
        await harness.session.omemo.setForcedVersion(.v03)
        let account = try JID(Self.alice)
        try harness.deliver(
            AccountSessionTests.chat(
                "\(Self.bob)/phone", id: "p1", body: "see you",
                extra: ReplyPrivacyTests.origin("p1")))
        try await waitUntil("stored") { try harness.message(originID: "p1") != nil }

        // Bob's client turned OMEMO on, and corrects the message with it.
        let correction = ChatMessage.correction(
            "see https://example.org/plan at geo:52.5,13.4", replacing: "p1", to: account,
            id: "c1")
        _ = try await bob.manager.send(correction, to: .direct(account))
        let sealed = try #require(bob.sender.messages.last)
        try OMEMOFixRoundTests.deliver(sealed, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("corrected") {
            try harness.message(originID: "p1")?.body?.hasPrefix("see https") == true
        }
        let row = try #require(try harness.message(originID: "p1"))
        #expect(row.encryption == .omemo)
        // The chat switches in its own write, after the row's (M24).
        try await waitUntil("chat switched") {
            try harness.chat(Self.bob)?.encryption == .omemo
        }

        // The user turns OMEMO off and replies: nothing of the corrected text goes.
        try harness.database.updateChat(id: row.chatID) { $0.encryption = .none }
        let id = try await harness.session.send(text: "ok", chatID: row.chatID, replyTo: row.id)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(sent.child("body")?.text == "ok")
        #expect(!sent.xml().contains("example.org"))
        #expect(sent.child("fallback", namespace: ChatMessage.fallbackNamespace) == nil)

        // Nor does its link or place fetch anything (R49, R62).
        let chat = try #require(try harness.chat(Self.bob))
        let roster: Set<String> = [Self.bob]
        let link = try #require(URL(string: "https://example.org/plan"))
        #expect(
            !LinkPreviewTrust.request(for: row, in: chat, link: link, roster: roster, enabled: true)
                .isAllowed)
        #expect(LocationTrust.display(for: row, in: chat, roster: roster) == .coordinates)
        await harness.stop()
    }
}
