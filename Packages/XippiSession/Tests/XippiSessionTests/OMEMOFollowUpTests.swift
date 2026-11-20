import Foundation
import GRDB
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Task 17c: the follow-ups to Task 17b's fix rounds.
@Suite(.timeLimit(.minutes(1))) struct OMEMOFollowUpTests {
    static let alice = SessionServer.account
    static let bob = "bob@example.test"

    /// Alice's manager on a store that fails once when armed, and a message from bob.
    static func managerOnAFailingStore() async throws
        -> (OMEMOManager, FailingOnceStore, OMEMOParty)
    {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let store = FailingOnceStore(
            base: OMEMOStoreAdapter(database: alice.database, accountID: alice.accountID))
        let manager = OMEMOManager(
            account: alice.jid, store: store, sender: alice.sender, now: { Date() })
        await manager.sessionStarted(accountFeatures: OMEMOParty.features)
        await manager.settled()
        return (manager, store, bob)
    }

    // MARK: m22: a genuine duplicate after a failed try

    @Test func aDuplicateAfterAnUnrelatedFailureIsNoNotice() async throws {
        let (manager, store, bob) = try await Self.managerOnAFailingStore()
        let message = try await bob.send("hello", to: .direct(try JID(Self.alice)))
        let encrypted = try #require(ChatMessage(element: message)?.encrypted)
        let first = try #require(
            await manager.decrypt(encrypted, from: bob.jid, recipient: nil, known: true))
        #expect(first.body == "hello")

        // The same message again; the first try fails on a read, before anything is written.
        store.sessionReadArmed.set(true)
        let again = try #require(
            await manager.decrypt(encrypted, from: bob.jid, recipient: nil, known: true))
        #expect(again.content == .duplicate)
    }

    // MARK: m21: the kept messages are read in linear time

    @Test func twoThousandKeptRowsAreReadOneRowAtATime() async throws {
        let pep = FakePEP()
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let total = OMEMOPendingRepositoryLimits.total
        let perSender = OMEMOPendingRepositoryLimits.perSender
        for sender in 0..<(total / perSender) {
            let jid = "s\(sender)@example.test"
            for index in 0..<perSender {
                let stanza =
                    "<message xmlns='jabber:client' from='\(jid)/phone' "
                    + "to='\(SessionServer.fullJID)' type='chat' id='k\(sender)-\(index)'>"
                    + "<body>\(index)</body></message>"
                #expect(
                    try harness.database.keepOMEMOPending(
                        OMEMOPendingRecord(
                            accountID: harness.accountID, stanza: stanza, carbon: nil,
                            receivedAt: Date(), sender: jid, senderKnown: false)))
            }
        }

        // Every read of the kept table while they are read.
        let reads = Locked(0)
        let wholeTableReads = Locked(0)
        try await harness.database.writer.write { db in
            db.trace { event in
                let sql = event.description
                guard sql.hasPrefix("SELECT"), sql.contains("\"omemoPending\"") else { return }
                reads.withLock { $0 += 1 }
                if !sql.hasSuffix("LIMIT 1") { wholeTableReads.withLock { $0 += 1 } }
            }
        }
        await harness.session.drainPendingOMEMO()
        try await harness.database.writer.write { db in db.trace(nil) }

        #expect(try harness.database.omemoPending(accountID: harness.accountID).isEmpty)
        // One row per read, one read per row: linear, where reading the table on each step
        // reads two million rows.
        #expect(wholeTableReads.value == 0)
        #expect(reads.value <= total + 1)
        #expect(reads.value >= total)
        await harness.stop()
    }
}

/// The kept-message caps, as the store has them.
enum OMEMOPendingRepositoryLimits {
    static let total = AppDatabase.maxOMEMOPending
    static let perSender = AppDatabase.maxOMEMOPendingPerSender
}
