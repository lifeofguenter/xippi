import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// One OMEMO engine per account store: the lease.
@Suite("OMEMOLease")
struct OMEMOLeaseTests {
    @Test func oneHolderAtATime() throws {
        let database = try AppDatabase.inMemory()
        let leases = OMEMOLeases()
        let first = try #require(leases.acquire(database: database, accountID: 1))
        #expect(leases.acquire(database: database, accountID: 1) == nil)
        // Another account, or another store, is another lease.
        #expect(leases.acquire(database: database, accountID: 2) != nil)
        #expect(leases.acquire(database: try AppDatabase.inMemory(), accountID: 1) != nil)
        first.release()
        #expect(leases.acquire(database: database, accountID: 1) != nil)
    }

    @Test func aLeaseNobodyHoldsIsFree() throws {
        let database = try AppDatabase.inMemory()
        let leases = OMEMOLeases()
        do {
            let lease = leases.acquire(database: database, accountID: 1)
            #expect(lease != nil)
        }
        #expect(leases.acquire(database: database, accountID: 1) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionWithoutTheLeaseRunsWithoutOMEMO() async throws {
        // The account's store, its lease held as by an old engine that has not stopped.
        let database = try AppDatabase.inMemory()
        let accountID = try #require(try database.addAccount(ManagerFixture.account()).id)
        let held = try #require(
            OMEMOLeases.shared.acquire(database: database, accountID: accountID))
        defer { held.release() }
        let second = try await SessionHarness(database: database)
        #expect(!second.session.hasOMEMO)
        try await second.goOnline()
        try await Task.sleep(for: .milliseconds(300))
        // No engine worked on the store: no own device was made.
        #expect(try second.database.omemoAccount(accountID: second.accountID, version: .v2) == nil)
        // Sending in an OMEMO chat fails with a typed error, and the message waits.
        var chat = try second.database.ensureChat(
            accountID: second.accountID, jid: "bob@example.test", kind: .direct)
        chat.encryption = .omemo
        try second.database.updateChat(chat)
        let chatID = try #require(chat.id)
        await #expect(throws: SessionError.encryption(.notReady)) {
            try await second.session.send(text: "hello", chatID: chatID)
        }
        await second.stop()
    }

    // MARK: Across processes (final review I-1)

    /// A store in a directory of its own, as the app keeps it.
    static func storeOnDisk() throws -> (database: AppDatabase, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OMEMOLeaseTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("xippi.sqlite")
        return (try AppDatabase.open(at: url), url)
    }

    /// The account's lock file taken as another process would: a descriptor of its own.
    final class OtherProcess: Sendable {
        let descriptor: Int32

        init(holding path: String) throws {
            descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(descriptor >= 0)
            try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        }

        func quit() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    /// Two app instances on one store: each opens it on its own and keeps its own leases. The
    /// second gets no lease while the first holds it, whichever account asks.
    @Test func aLeaseHoldsAcrossProcesses() throws {
        let (first, url) = try Self.storeOnDisk()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let second = try AppDatabase.open(at: url)
        let here = OMEMOLeases()
        let there = OMEMOLeases()
        let held = try #require(here.acquire(database: first, accountID: 1))
        #expect(there.acquire(database: second, accountID: 1) == nil)
        // Another account of the same store is another lease.
        let other = there.acquire(database: second, accountID: 2)
        #expect(other != nil)
        other?.release()
        held.release()
        let taken = there.acquire(database: second, accountID: 1)
        #expect(taken != nil)
        // Held there now: not here.
        #expect(here.acquire(database: first, accountID: 1) == nil)
        taken?.release()
    }

    /// The lock file is the lease across processes: whoever holds it, no engine starts here.
    @Test func aLockFileHeldElsewhereRefusesTheLease() throws {
        let (database, url) = try Self.storeOnDisk()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let path = try #require(OMEMOLeases.lockFile(of: database, accountID: 7))
        #expect(path.hasPrefix(url.deletingLastPathComponent().path))
        let other = try OtherProcess(holding: path)
        let leases = OMEMOLeases()
        #expect(leases.acquire(database: database, accountID: 7) == nil)
        other.quit()
        let lease = leases.acquire(database: database, accountID: 7)
        #expect(lease != nil)
        lease?.release()
        // A store in memory has no file, and no other process can open it.
        #expect(OMEMOLeases.lockFile(of: try AppDatabase.inMemory(), accountID: 7) == nil)
    }

    /// A process waiting for the lease takes it once the process that holds it lets go, with
    /// no wake-up from that process.
    @Test(.timeLimit(.minutes(1))) func aWaitingProcessTakesTheLeaseWhenTheOtherQuits()
        async throws
    {
        let (database, url) = try Self.storeOnDisk()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let path = try #require(OMEMOLeases.lockFile(of: database, accountID: 3))
        let other = try OtherProcess(holding: path)
        let leases = OMEMOLeases(retryInterval: .milliseconds(20))
        let waiting = Task { await leases.next(database: database, accountID: 3) }
        try await Task.sleep(for: .milliseconds(100))
        other.quit()
        let lease = await waiting.value
        #expect(lease != nil)
        lease?.release()
    }

    /// A second app instance runs the account without OMEMO (R53) while the first holds the
    /// account's lock file: sending in an OMEMO chat fails with a typed error, nothing of the
    /// store is touched, and OMEMO comes on once the first instance quits.
    @Test(.timeLimit(.minutes(1)))
    func aSecondInstanceRunsWithoutOMEMOUntilTheFirstQuits() async throws {
        let (database, url) = try Self.storeOnDisk()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let accountID = try #require(try database.addAccount(ManagerFixture.account()).id)
        let other = try OtherProcess(
            holding: try #require(OMEMOLeases.lockFile(of: database, accountID: accountID)))
        let second = try await SessionHarness(database: database)
        #expect(!second.session.hasOMEMO)
        let pep = FakePEP()
        let account = try JID(SessionServer.account)
        second.server.setResponder { iq in pep.answer(iq, from: account).map { [$0.xml()] } }
        try await second.goOnline()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try database.omemoAccount(accountID: accountID, version: .v2) == nil)
        var chat = try database.ensureChat(
            accountID: accountID, jid: "bob@example.test", kind: .direct)
        chat.encryption = .omemo
        try database.updateChat(chat)
        let chatID = try #require(chat.id)
        await #expect(throws: SessionError.encryption(.notReady)) {
            try await second.session.send(text: "hello", chatID: chatID)
        }
        // An OMEMO message that comes meanwhile is kept, unread and unshown (R57).
        let ns = OMEMO.OMEMOVersion.v03.rawValue
        try second.deliver(
            "<message from='bob@example.test/phone' to='\(SessionServer.fullJID)' type='chat'"
                + " id='k1'><encrypted xmlns='\(ns)'><header sid='4242'><key rid='77'>AAAA</key>"
                + "<iv>AAAAAAAAAAAAAAAA</iv></header><payload>AAAA</payload></encrypted>"
                + "<body>fallback</body></message>")
        try await second.barrier()
        #expect(try second.message(originID: "k1") == nil)
        #expect(try database.omemoPending(accountID: accountID).count == 1)

        other.quit()
        try await waitUntil("lease taken", timeout: .seconds(10)) { second.session.hasOMEMO }
        // Read once OMEMO is on: not for this device, so the notice, never the fallback text.
        try await waitUntil("kept message read and let go") {
            try second.messages().contains { $0.stanzaMessageID == "k1" }
                && database.omemoPending(accountID: accountID).isEmpty
        }
        let read = try #require(try second.messages().first { $0.stanzaMessageID == "k1" })
        #expect(read.body == AccountSession.notForThisDeviceText)
        await second.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondEngineIsNeverMadeWhileTheFirstHoldsTheLease() async throws {
        let first = try await SessionHarness()
        try await first.goOnline()
        #expect(first.session.hasOMEMO)
        let second = try await SessionHarness(database: first.database)
        #expect(!second.session.hasOMEMO)
        await second.stop()
        await first.stop()
        // Stopped, the first engine hands the lease on.
        let third = try await SessionHarness(database: first.database)
        #expect(third.session.hasOMEMO)
        await third.stop()
    }
}
