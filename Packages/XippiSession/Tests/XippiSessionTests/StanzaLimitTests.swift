import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// R81: a message longer than the server takes is never sent. Its row fails with a terse
/// error, once, and the stream stays up: no reconnect, and no resend in later sessions.
@Suite(.timeLimit(.minutes(1)))
struct StanzaLimitTests {
    static let bob = "bob@example.test"
    /// Over the 256 KiB a server takes when it announces no limit.
    static let tooLong = String(repeating: "log line\n", count: 32_000)

    static func harness() async throws -> SessionHarness {
        try await SessionHarness(options: .init(answersAckRequests: true)) {
            database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
    }

    @Test func tooLongMessageFailsOnceAndTheStreamStaysUp() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        let big = try await harness.session.send(text: Self.tooLong, chatID: chatID)

        try await waitUntil("failed") { try harness.database.message(id: big)?.state == .failed }
        let failed = try #require(try harness.database.message(id: big))
        #expect(failed.errorText == "Too long to send")
        let small = try await harness.session.send(text: "Still here", chatID: chatID)
        try await waitUntil("sent") { try harness.database.message(id: small)?.state == .sent }
        #expect(harness.server.messages(id: try #require(failed.originID)).isEmpty)
        #expect(harness.transports.count == 1)
        #expect(await harness.session.connectionState == .online(resumed: false))
        await harness.stop()
    }

    /// A pending row that is too long fails at the flush, and the rows after it go out; a
    /// later fresh session does not try it again.
    @Test func tooLongPendingRowFailsAndTheFlushGoesOn() async throws {
        let harness = try await SessionHarness(options: .init(answersAckRequests: true)) {
            database, accountID in
            let chat = try database.ensureChat(
                accountID: accountID, jid: Self.bob, kind: .direct)
            let chatID = try #require(chat.id)
            for (originID, body) in [("big-1", Self.tooLong), ("after-1", "After")] {
                _ = try database.insertOutgoing(
                    OutgoingMessage(
                        accountID: accountID, chatID: chatID, originID: originID,
                        senderJID: SessionServer.account, body: body, timestamp: Date()))
            }
        }
        try await harness.goOnline()

        try await waitUntil("after-1 sent") { harness.server.messages(id: "after-1").count == 1 }
        try await waitUntil("big-1 failed") {
            try harness.message(originID: "big-1")?.state == .failed
        }
        #expect(try harness.message(originID: "big-1")?.errorText == "Too long to send")
        #expect(harness.server.messages(id: "big-1").isEmpty)
        #expect(harness.transports.count == 1)

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("a fresh session") { await harness.session.progress.started == 2 }
        try await harness.barrier()
        #expect(harness.server.messages(id: "big-1").isEmpty)
        #expect(harness.server.messages(id: "after-1").count == 1)
        #expect(harness.transports.count == 2)
        await harness.stop()
    }

    /// In an OMEMO chat the stanza is only known once sealed: the manager says it is too long,
    /// not that there was no session (the session then fails the row, `failTooLong`).
    @Test func sealedMessageTooLongForTheServerIsRefused() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        alice.sender.setMaxBytes(4_096)
        let plain = ChatMessage.text(
            String(repeating: "x", count: 8_192), to: bob.jid, id: "omemo-big")

        #expect(try await alice.manager.deliver(plain, to: .direct(bob.jid)) == .tooLarge)
        #expect(alice.sender.messages.isEmpty)
        // The next message is not held up behind it.
        #expect(
            try await alice.manager.deliver(
                ChatMessage.text("short", to: bob.jid, id: "omemo-small"), to: .direct(bob.jid))
                == .sent)
        alice.sender.setOffline(true)
        #expect(
            try await alice.manager.deliver(
                ChatMessage.text("later", to: bob.jid, id: "omemo-later"), to: .direct(bob.jid))
                == .notConnected)
    }

    /// The session's side: a row too long once sealed fails with the same text, and the
    /// caller is done with it; a stanza without a row is reported not sent.
    @Test func tooLongRowFailsWithTheSameText() async throws {
        let harness = try await Self.harness()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "sealed-1",
                senderJID: SessionServer.account, body: "x", timestamp: Date()))

        #expect(await harness.session.failTooLong("sealed-1"))
        #expect(await !harness.session.failTooLong(nil))
        #expect(try harness.message(originID: "sealed-1")?.state == .failed)
        #expect(try harness.message(originID: "sealed-1")?.errorText == "Too long to send")
        await harness.stop()
    }
}
