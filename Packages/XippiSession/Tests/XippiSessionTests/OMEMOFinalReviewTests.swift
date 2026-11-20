import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The final review's OMEMO findings, in a session (alice@example.test on the scripted
/// server, with the other side an `OMEMOParty` on the same `FakePEP`).
@Suite(.timeLimit(.minutes(1))) struct OMEMOFinalReviewTests {
    static let alice = SessionServer.account
    static let bob = "bob@example.test"
    static let mallory = "mallory@example.test"

    static func deliver(_ stanza: Element, from: String, to harness: SessionHarness) throws {
        try harness.deliver(OMEMOPipelineTests.delivered(stanza, from: from))
    }

    /// `stanza` with `elements` added in the clear, as a server can.
    static func injecting(_ elements: [Element], into stanza: Element) -> Element {
        var copy = stanza
        for element in elements { copy.append(element) }
        return copy
    }

    static func reply(to id: String) -> Element {
        Element("reply", namespace: ChatMessage.replyNamespace, attributes: ["id": id])
    }

    /// A reply fallback over the first `end` code points of the body, or the whole body.
    static func fallback(end: Int?) -> Element {
        var fallback = Element(
            "fallback", namespace: ChatMessage.fallbackNamespace,
            attributes: ["for": ChatMessage.replyNamespace])
        if let end {
            fallback.append(
                Element(
                    "body", namespace: ChatMessage.fallbackNamespace,
                    attributes: ["start": "0", "end": String(end)]))
        }
        return fallback
    }

    static func replace(_ id: String) -> Element {
        Element("replace", namespace: ChatMessage.correctionNamespace, attributes: ["id": id])
    }

    /// Bob's first message, "first" with id `d0`, stored: the target of what follows.
    static func firstFromBob(
        _ bob: OMEMOParty, to harness: SessionHarness
    ) async throws -> MessageRecord {
        let account = try JID(Self.alice)
        let first = try await bob.send("first", to: .direct(account), id: "d0")
        try Self.deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("first stored") { try harness.message(originID: "d0") != nil }
        return try #require(try harness.message(originID: "d0"))
    }

    // MARK: I-2: a distrusted device

    /// A device the user distrusted goes on writing: its messages are notices, their text out
    /// of sight until the user asks, and they correct nothing; the contact stops showing as
    /// verified while it writes.
    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func aMessageFromADistrustedDeviceIsAHiddenNotice(version: OMEMO.OMEMOVersion)
        async throws
    {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await OMEMOPipelineTests.online(
            pep: pep,
            harness: SessionHarness(
                options: .init(
                    roster: .items(
                        ["<item jid='\(Self.bob)' subscription='both'/>"], version: "v1"))))
        let account = try JID(Self.alice)
        let first = try await Self.firstFromBob(bob, to: harness)
        #expect(!first.isFromDistrustedDevice)
        let shown = try #require(
            await harness.session.omemoIdentities(of: bob.jid).first { !$0.isThisDevice })
        try await harness.session.setOMEMOTrust(.distrusted, identity: shown, of: bob.jid)
        let refused = await harness.session.omemoIdentities(of: bob.jid).first {
            !$0.isThisDevice
        }
        #expect(refused?.trust == .distrusted)
        #expect(refused?.lastSeen == nil)

        let after = try await bob.send("after", to: .direct(account), id: "d1")
        try Self.deliver(after, from: "\(Self.bob)/phone", to: harness)
        var correction = ChatMessage.text("edited", to: account, id: "d2")
        correction.append(Self.replace("d0"))
        #expect(try await bob.manager.send(correction, to: .direct(account)))
        try Self.deliver(
            try #require(bob.sender.messages.last), from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("both stored") { try harness.message(originID: "d2") != nil }
        try await harness.barrier()

        let notice = try #require(try harness.message(originID: "d1"))
        #expect(notice.kind == .system)
        #expect(notice.encryption == .omemo)
        #expect(notice.body == AccountSession.distrustedDeviceText)
        #expect(notice.isFromDistrustedDevice)
        #expect(notice.distrustedText == "after")
        #expect(notice.senderDeviceFingerprint == first.senderDeviceFingerprint)
        let editing = try #require(try harness.message(originID: "d2"))
        #expect(editing.isFromDistrustedDevice)
        #expect(editing.distrustedText == "edited")
        // The message it would correct keeps its text.
        #expect(try harness.message(originID: "d0")?.body == "first")
        // Nothing tells the device its messages arrived.
        let receipts = OMEMOPipelineTests.receipts(harness)
        #expect(!receipts.contains("d1") && !receipts.contains("d2"))
        // Heard from while distrusted: the contact does not show as verified.
        let identities = await harness.session.omemoIdentities(of: bob.jid)
        #expect(identities.first { !$0.isThisDevice }?.lastSeen != nil)
        #expect(!OMEMOTrustSummary.isVerified(identities))
        await harness.stop()
    }

    // MARK: I-3: a huge device list

    /// A contact who lists 1,000 devices, whose bundles never come, does not hold up another
    /// contact's message while a message to them waits for those bundles.
    @Test func aHugeDeviceListDoesNotHoldUpAnotherContactsMessage() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let mallory = try JID(Self.mallory)
        for version in OMEMO.OMEMOVersion.allCases {
            pep.put(
                DeviceList.element(version: version, devices: Array(1...1_000)),
                id: DeviceList.itemID, node: DeviceList.node(version: version), of: mallory)
        }
        let harness = try await OMEMOPipelineTests.online(
            pep: pep, seed: OMEMOPipelineTests.omemoChat(with: Self.mallory))
        let account = try JID(Self.alice)
        let lists = Set(OMEMO.OMEMOVersion.allCases.map { DeviceList.node(version: $0) })
        let held = Locked(0)
        harness.server.setResponder { iq in
            if iq.to?.bare == mallory,
                let node = iq.elements.first?.child("items", namespace: PubSub.namespace)?[
                    attribute: "node"],
                !lists.contains(node)
            {
                held.withLock { $0 += 1 }
                return []
            }
            return pep.answer(iq, from: account).map { [$0.xml()] }
        }
        let chatID = try OMEMOPipelineTests.chatID(harness, Self.mallory)
        let sent = Locked(false)
        let sending = Task {
            _ = try? await harness.session.send(text: "hi", chatID: chatID)
            sent.set(true)
        }
        try await waitUntil("bundles asked for") { held.value > 0 }

        let message = try await bob.send("from bob", to: .direct(account), id: "b1")
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("bob's message stored") {
            try harness.message(originID: "b1")?.body == "from bob"
        }
        // The bundles never come: each wait ends at its timeout, and the message fails.
        for _ in 0..<200 where !sent.value {
            await harness.clock.advance(by: .seconds(11))
            await harness.sessionClock.advance(by: .seconds(11))
            try await Task.sleep(for: .milliseconds(5))
        }
        await sending.value
        // One message asks for a bounded number of bundles.
        #expect(held.value <= OMEMOEngine.newDevicesPerMessage)
        await harness.stop()
    }

    // MARK: I-4: reply, fallback and correction in the clear (R77)

    /// OMEMO 2: a fallback, a reply or a correction a server adds in the clear changes
    /// nothing; only the envelope says what the message replies to or corrects.
    @Test func clearMarkersBesideAnOMEMO2MessageAreIgnored() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await OMEMOPipelineTests.online(pep: pep)
        let account = try JID(Self.alice)
        _ = try await Self.firstFromBob(bob, to: harness)

        let cut = try await bob.send("hello world", to: .direct(account), id: "x1")
        try Self.deliver(
            Self.injecting([Self.reply(to: "d0"), Self.fallback(end: 6)], into: cut),
            from: "\(Self.bob)/phone", to: harness)
        let whole = try await bob.send("all of it", to: .direct(account), id: "x2")
        try Self.deliver(
            Self.injecting([Self.reply(to: "d0"), Self.fallback(end: nil)], into: whole),
            from: "\(Self.bob)/phone", to: harness)
        let moved = try await bob.send("new text", to: .direct(account), id: "x3")
        try Self.deliver(
            Self.injecting([Self.replace("d0")], into: moved), from: "\(Self.bob)/phone",
            to: harness)
        try await waitUntil("all stored") { try harness.message(originID: "x3") != nil }

        let first = try #require(try harness.message(originID: "x1"))
        #expect(first.body == "hello world")
        #expect(first.replyToMessageID == nil)
        #expect(try harness.message(originID: "x2")?.body == "all of it")
        #expect(try harness.message(originID: "x3")?.body == "new text")
        #expect(try harness.message(originID: "d0")?.body == "first")
        await harness.stop()
    }

    /// OMEMO 2: replies and corrections Xippi sends go inside the envelope, and are read
    /// from there.
    @Test func repliesAndCorrectionsTravelInsideTheEnvelope() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await OMEMOPipelineTests.online(pep: pep)
        let account = try JID(Self.alice)
        let target = try await Self.firstFromBob(bob, to: harness)

        let reply = ChatMessage.text(
            "nice", to: account, id: "r1", reply: ChatMessage.Reply(to: bob.jid, id: "d0"),
            quote: "first")
        #expect(try await bob.manager.send(reply, to: .direct(account)))
        let sentReply = try #require(bob.sender.messages.last)
        #expect(sentReply.child("reply", namespace: ChatMessage.replyNamespace) == nil)
        #expect(sentReply.child("fallback", namespace: ChatMessage.fallbackNamespace) == nil)
        try Self.deliver(sentReply, from: "\(Self.bob)/phone", to: harness)
        var correction = ChatMessage.text("first, edited", to: account, id: "r2")
        correction.append(Self.replace("d0"))
        #expect(try await bob.manager.send(correction, to: .direct(account)))
        let sentCorrection = try #require(bob.sender.messages.last)
        #expect(sentCorrection.child("replace", namespace: ChatMessage.correctionNamespace) == nil)
        try Self.deliver(sentCorrection, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("corrected") {
            try harness.message(originID: "d0")?.body == "first, edited"
        }

        let stored = try #require(try harness.message(originID: "r1"))
        #expect(stored.body == "nice")
        #expect(stored.replyToMessageID == target.id)
        await harness.stop()
    }

    /// Legacy OMEMO: reply and correction markers in the clear count, but a fallback cuts
    /// the decrypted text only where it cuts quote lines of the message the reply names.
    @Test func aLegacyFallbackCutsOnlyAQuoteOfItsTarget() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        let harness = try await OMEMOPipelineTests.online(pep: pep)
        let account = try JID(Self.alice)
        let target = try await Self.firstFromBob(bob, to: harness)

        // A server cuts "hello " and calls the rest a reply.
        let cut = try await bob.send("hello world", to: .direct(account), id: "y1")
        try Self.deliver(
            Self.injecting([Self.reply(to: "d0"), Self.fallback(end: 6)], into: cut),
            from: "\(Self.bob)/phone", to: harness)
        // A server calls the whole text a fallback.
        let whole = try await bob.send("all of it", to: .direct(account), id: "y2")
        try Self.deliver(
            Self.injecting([Self.reply(to: "d0"), Self.fallback(end: nil)], into: whole),
            from: "\(Self.bob)/phone", to: harness)
        // A real reply: its quote of "first" goes, its own text stays.
        let reply = ChatMessage.text(
            "nice", to: account, id: "y3", reply: ChatMessage.Reply(to: bob.jid, id: "d0"),
            quote: "first")
        #expect(try await bob.manager.send(reply, to: .direct(account)))
        try Self.deliver(
            try #require(bob.sender.messages.last), from: "\(Self.bob)/phone", to: harness)
        // A real reply whose quote names the author first, as XEP-0461 shows.
        let attributed = try await bob.send(
            "> bob wrote:\n> first\nyes", to: .direct(account), id: "y4")
        try Self.deliver(
            Self.injecting([Self.reply(to: "d0"), Self.fallback(end: 21)], into: attributed),
            from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("all stored") { try harness.message(originID: "y4") != nil }

        let first = try #require(try harness.message(originID: "y1"))
        #expect(first.body == "hello world")
        #expect(first.replyToMessageID == target.id)
        #expect(try harness.message(originID: "y2")?.body == "all of it")
        let real = try #require(try harness.message(originID: "y3"))
        #expect(real.body == "nice")
        #expect(real.replyToMessageID == target.id)
        #expect(try harness.message(originID: "y4")?.body == "yes")

        // A correction in the clear applies: the correction itself is encrypted.
        let correction = try await bob.send("first, edited", to: .direct(account), id: "y5")
        try Self.deliver(
            Self.injecting([Self.replace("d0")], into: correction), from: "\(Self.bob)/phone",
            to: harness)
        try await waitUntil("corrected") {
            try harness.message(originID: "d0")?.body == "first, edited"
        }
        // One in the clear does not.
        var plain = ChatMessage.text("forged", to: account, id: "y6")
        plain.append(Self.replace("d0"))
        try Self.deliver(plain, from: "\(Self.bob)/phone", to: harness)
        try await harness.barrier()
        #expect(try harness.message(originID: "d0")?.body == "first, edited")
        await harness.stop()
    }

    /// What counts as a quote of the message a legacy reply names.
    @Test func quoteLines() {
        #expect(AccountSession.isQuote("> first\n", of: "first"))
        #expect(AccountSession.isQuote(">first", of: "first"))
        #expect(AccountSession.isQuote("> two\n> lines\n", of: "two\nlines"))
        #expect(AccountSession.isQuote("> a long tex\u{2026}\n", of: "a long text indeed"))
        #expect(AccountSession.isQuote("> Anna wrote:\n> bake a cake\n", of: "bake a cake"))
        #expect(!AccountSession.isQuote("hello ", of: "first"))
        #expect(!AccountSession.isQuote("> first\nnot a quote\n", of: "first"))
        #expect(!AccountSession.isQuote("> other\n", of: "first"))
        #expect(!AccountSession.isQuote(">\n", of: "first"))
        #expect(!AccountSession.isQuote("> first\n", of: ""))
    }

    /// N-1: anyone with a legacy session can send a long message, then a reply that quotes
    /// most of it. The check runs on the account's inbound path, so it must stay linear: a
    /// quote over 4 KiB is no quote (the whole text shows), and one under it is matched in
    /// one pass over the original.
    @Test(.timeLimit(.minutes(1)))
    func quoteCheckStaysFastOnHostileInput() {
        let original = String(repeating: "a ", count: 40_000)
        let quote = "> " + String(repeating: "a ", count: 20_000) + "b\n"
        var found = true
        var elapsed = measureCPU { found = AccountSession.isQuote(quote, of: original) }
        #expect(!found)
        #expect(elapsed < .milliseconds(100), "80k original, 40k quote: \(elapsed)")

        // Just under the cap, the old search took seconds; one pass takes a few milliseconds
        // (a debug build under a full parallel run included, hence the margin).
        let nearCap = "> " + String(repeating: "a ", count: 2_000) + "b\n"
        #expect(nearCap.utf8.count <= 4096)
        elapsed = measureCPU { found = AccountSession.isQuote(nearCap, of: original) }
        #expect(!found)
        #expect(elapsed < .milliseconds(500), "80k original, 4k quote: \(elapsed)")
    }

    /// The 4 KiB cap counts the quote as sent; a quote under it still matches.
    @Test func quotesOverFourKiBAreNoQuotes() {
        let fits = String(repeating: "word ", count: 800)
        #expect(AccountSession.isQuote("> " + fits + "\n", of: "Before. " + fits + " after"))
        let long = String(repeating: "word ", count: 1_000)
        #expect(!AccountSession.isQuote("> " + long + "\n", of: long))
    }
}
