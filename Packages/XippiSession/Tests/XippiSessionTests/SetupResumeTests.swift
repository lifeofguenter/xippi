import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A fresh session's start cut short by a resumable drop (I1), and the outbox flush that
/// never holds up the stanzas that come meanwhile (I2).
@Suite struct SetupResumeTests {
    static let me = SessionServer.fullJID

    /// Binding and carbons, which the stream needs before the session starts.
    static func isNegotiation(_ iq: Element) -> Bool {
        let namespace = iq.elements.first?.namespace
        return namespace == "urn:ietf:params:xml:ns:xmpp-bind"
            || namespace == "urn:ietf:params:xml:ns:xmpp-session"
            || namespace == "urn:xmpp:carbons:2"
    }

    static func asks(_ iq: Element, _ name: String, _ namespace: String, to: String? = nil)
        -> Bool
    {
        iq.name == "iq" && iq.elements.first?.name == name
            && iq.elements.first?.namespace == namespace && (to == nil || iq.to?.description == to)
    }

    /// The server answers no request on the first stream; the stream drops while the start
    /// waits, and the session resumes on the next one: every step of the start and the setup
    /// is asked again there and done.
    @Test func aDropDuringSetupThenAResumeCompletesEveryStep() async throws {
        var options = SessionServer.Options()
        options.roster = .items(
            ["<item jid='bob@example.test' subscription='both' name='Bob'/>"], version: "v2")
        let harness = try await SessionHarness(options: options)
        let catchUp = CountingCatchUp()
        await harness.session.setArchiveCatchUp(catchUp)
        let holding = Locked(true)
        harness.server.setResponder { iq in
            holding.value && !Self.isNegotiation(iq) ? [] : nil
        }

        try await harness.session.start()
        try await waitUntil("roster asked") {
            harness.server.received.contains {
                $0.connection == 0 && Self.asks($0.element, "query", "jabber:iq:roster")
            }
        }
        // The drop comes while every request of the start waits for its answer.
        await harness.clock.advance(by: .seconds(11))
        holding.set(false)
        try harness.latestTransport.simulateEOF()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }

        let all: AccountSession.SetupSteps = [
            .accountFeatures, .serverFeatures, .roster, .archive, .blocklist, .displayed,
            .ownVCardHash,
        ]
        try? await waitUntil("setup done") { await harness.session.setupDone == all }
        let done = await harness.session.setupDone
        #expect(done.rawValue == all.rawValue)
        let second = harness.server.received.filter { $0.connection == 1 }.map(\.element)
        #expect(
            second.contains {
                Self.asks($0, "query", Disco.infoNamespace, to: SessionServer.account)
            })
        #expect(
            second.contains {
                Self.asks($0, "query", Disco.infoNamespace, to: SessionServer.domain)
            })
        #expect(second.contains { Self.asks($0, "query", "jabber:iq:roster") })
        #expect(second.contains { Self.asks($0, "blocklist", "urn:xmpp:blocking") })
        #expect(second.contains { Self.asks($0, "pubsub", "http://jabber.org/protocol/pubsub") })
        #expect(second.contains { Self.asks($0, "vCard", "vcard-temp") })
        #expect(await harness.session.accountFeatures.contains("urn:xmpp:mam:2"))
        #expect(await harness.session.serverFeatures.contains("urn:xmpp:blocking"))
        #expect(
            try harness.database.rosterItems(accountID: harness.accountID).map(\.jid)
                == ["bob@example.test"])
        #expect(await catchUp.started.count == 1)

        // A second resume asks nothing again.
        let asked = harness.server.received.count
        try await harness.drop()
        try await waitUntil("resumed again") { await harness.session.progress.resumed == 2 }
        try await harness.barrier()
        let third = harness.server.received.dropFirst(asked).map(\.element)
        #expect(!third.contains { Self.asks($0, "query", "jabber:iq:roster") })
        #expect(await catchUp.started.count == 1)
        await harness.stop()
    }

    /// The disco that does not answer keeps what was known: features are never emptied by a
    /// failed request.
    @Test func aFailedDiscoKeepsTheFeaturesKnown() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        #expect(await harness.session.accountFeatures.contains("urn:xmpp:mam:2"))

        // The next fresh session's disco fails.
        harness.server.update { $0.resumeSucceeds = false }
        harness.server.setResponder { iq in
            Self.asks(iq, "query", Disco.infoNamespace)
                ? [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
                : nil
        }
        try await harness.drop()
        try await waitUntil("restarted") { await harness.session.progress.started == 2 }
        #expect(await harness.session.accountFeatures.contains("urn:xmpp:mam:2"))
        #expect(await harness.session.serverFeatures.contains("urn:xmpp:blocking"))
        #expect(await !harness.session.setupDone.contains(.accountFeatures))
        await harness.stop()
    }

    // MARK: I2

    static let bob = OMEMOFixRoundTests.bob
    static let alice = OMEMOFixRoundTests.alice

    /// A pending OMEMO message waits for Bob's device lists at the start: a message that
    /// comes meanwhile is stored and a request answered, without waiting for the seal; then
    /// the pending one goes, once.
    @Test func sealingThePendingMessagesHoldsUpNoStanza() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let held = Locked<[Element]>([])
        let harness = try await SessionHarness(seed: OMEMOFixRoundTests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        harness.server.setResponder { iq in
            if EncryptionDefaultTests.asksBobsList(iq) {
                held.withLock { $0.append(iq) }
                return []
            }
            return pep.answer(iq, from: account).map { [$0.xml()] }
        }
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "p-1",
                senderJID: Self.me, body: "sealed later", timestamp: Date(),
                encryption: .omemo))

        try await harness.session.start()
        try await waitUntil("bob's lists asked") { !held.value.isEmpty }
        try harness.deliver(
            "<message from='carol@example.test/x' to='\(Self.me)' type='chat' id='c1'>"
                + "<body>Hi there</body></message>")
        try await harness.barrier()
        #expect(try harness.messages().contains { $0.body == "Hi there" })
        #expect(harness.server.messages(id: "p-1").isEmpty)

        // Bob's lists come: the pending message goes.
        try await waitUntil("sent") {
            try HeldMessageTests.answer(held, from: pep, harness)
            return !harness.server.messages(id: "p-1").isEmpty
        }
        try await waitUntil("started") { await harness.session.progress.started == 1 }
        try await harness.barrier()
        let sent = harness.server.messages(id: "p-1")
        #expect(sent.count == 1)
        #expect(ChatMessage(element: try #require(sent.first))?.encrypted != nil)
        #expect(try await bob.open(try #require(sent.first), from: account).body == "sealed later")
        await harness.stop()
    }
}
