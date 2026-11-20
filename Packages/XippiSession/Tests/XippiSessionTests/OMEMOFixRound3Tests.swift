import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Fix round 3 of Task 17b: a new identity key is never taken for the known one (N1), an old
/// key exchange never becomes current again (N2), strangers stay strangers (R54, N3), a stop
/// in the middle of an archive page loses nothing (N4), and a session without the store's
/// lease keeps what it cannot read yet, takes the lease once it is free, and reads it then
/// (R53).
@Suite(.timeLimit(.minutes(1))) struct OMEMOFixRound3Tests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"
    static let stranger = "stranger@elsewhere.test"

    // MARK: Helpers

    /// A session on `pep` and the archive `entries`, on `database` when given (a second
    /// session of the same account).
    static func online(
        pep: FakePEP, entries: Locked<[FakeArchive.Entry]> = Locked([]),
        database: AppDatabase? = nil,
        before: (@Sendable (Element) -> [String]?)? = nil,
        seed: @escaping (AppDatabase, Int64) throws -> Void = { _, _ in }
    ) async throws -> SessionHarness {
        let harness = try await SessionHarness(database: database, seed: seed)
        let account = try JID(alice)
        harness.server.setResponder { iq in
            if let answer = before?(iq) { return answer }
            if let answer = pep.answer(iq, from: account) { return [answer.xml()] }
            return OMEMOArchiveTests.archiveAnswer(iq, entries: entries.value)
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

    /// A party with `device`'s JID and device id and a new identity key: a reinstall, or
    /// anyone who knows the id from the public list and has the bundles.
    static func impostor(of device: OMEMOParty, version: OMEMO.OMEMOVersion, pep: FakePEP)
        async throws -> OMEMOParty
    {
        let party = try OMEMOParty(device.jid.description, pep: pep)
        let id = try await device.deviceID(version)
        try await OMEMOStoreAdapter(database: party.database, accountID: party.accountID)
            .saveOwnIdentity(
                OwnIdentity(
                    deviceID: id, identityKeyPair: .generate(version: version),
                    registrationID: version == .v03 ? id : nil, signedPreKeyID: 0,
                    nextPreKeyID: 1),
                version: version)
        await party.start()
        #expect(try await party.deviceID(version) == id)
        await party.manager.setForcedVersion(version)
        return party
    }

    /// The last message the session sent to `jid`, once there is one.
    static func lastMessage(to jid: String, in harness: SessionHarness) async throws -> Element {
        try await waitUntil("message to \(jid)") {
            harness.server.stanzas.contains {
                $0.name == "message" && $0.to?.bare.description == jid
            }
        }
        return try #require(
            harness.server.stanzas.last { $0.name == "message" && $0.to?.bare.description == jid })
    }

    /// OMEMO requests (device lists and bundles) sent to `jid`.
    static func omemoRequests(to jid: String, _ harness: SessionHarness) -> Int {
        OMEMOFixRoundTests.iqs(to: jid, harness)
    }

    // MARK: N1: a new identity key is never the known one

    @Test(.timeLimit(.minutes(1)), arguments: OMEMO.OMEMOVersion.allCases)
    func aForgedKeyExchangeNeverUpgradesANotice(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: version)

        // Bob's device is known by its identity; then a message under "n1" this device has
        // no key for is kept as a notice.
        let hello = try await bob.send("hello", to: .direct(account), id: "hello")
        try Self.deliver(hello, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("hello") { try harness.message(originID: "hello")?.body == "hello" }
        let elsewhere = try OMEMOFixRoundTests.rekeyed(
            try await bob.send("for another device", to: .direct(account), id: "n1"),
            from: own, to: 1)
        try Self.deliver(elsewhere, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("notice") {
            try harness.message(originID: "n1")?.body == AccountSession.notForThisDeviceText
        }

        // A key exchange under bob's device id and another identity key comes under "n1".
        let impostor = try await Self.impostor(of: bob, version: version, pep: pep)
        let forged = try await impostor.send("forged", to: .direct(account), id: "n1")
        try Self.deliver(forged, from: "\(Self.bob)/phone", to: harness)
        try await harness.barrier()

        let row = try #require(try harness.message(originID: "n1"))
        #expect(row.kind == .system)
        #expect(row.body == AccountSession.notForThisDeviceText)
        #expect(row.senderDeviceFingerprint == nil)
        #expect(try harness.messages().allSatisfy { $0.body != "forged" })
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: OMEMO.OMEMOVersion.allCases)
    func aMessageUnderANewIdentityIsMarked(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await Self.online(pep: pep, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let hello = try await bob.send("hello", to: .direct(account), id: "hello")
        try Self.deliver(hello, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("hello") { try harness.message(originID: "hello")?.body == "hello" }
        let known = try #require(try harness.message(originID: "hello")?.senderDeviceFingerprint)
        #expect(try harness.message(originID: "hello")?.identityChanged == false)

        let impostor = try await Self.impostor(of: bob, version: version, pep: pep)
        let message = try await impostor.send("new key", to: .direct(account), id: "x1")
        try Self.deliver(message, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "x1") != nil }

        // Read, under the new key's fingerprint, and flagged; never the known key's.
        let row = try #require(try harness.message(originID: "x1"))
        #expect(row.body == "new key")
        #expect(row.identityChanged)
        #expect(row.senderDeviceFingerprint != nil)
        #expect(row.senderDeviceFingerprint != known)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)), arguments: OMEMO.OMEMOVersion.allCases)
    func anArchivedKeyExchangeUnderANewIdentityIsANotice(version: OMEMO.OMEMOVersion)
        async throws
    {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await Self.online(
            pep: pep, entries: entries, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let hello = try await bob.send("hello", to: .direct(account), id: "hello")
        try Self.deliver(hello, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("hello") { try harness.message(originID: "hello")?.body == "hello" }
        let storeVersion: XippiStore.OMEMOVersion = version == .v2 ? .v2 : .v03
        let preKeys = Set(
            try harness.database.omemoPreKeys(accountID: harness.accountID, version: storeVersion)
                .map(\.keyID))
        // The session completion for bob's key exchange has gone out.
        _ = try await Self.lastMessage(to: Self.bob, in: harness)
        try await harness.barrier()
        let sent = OMEMOArchiveTests.messagesSent(harness)

        let impostor = try await Self.impostor(of: bob, version: version, pep: pep)
        let forged = try await impostor.send("forged", to: .direct(account), id: "a1")
        entries.set([
            FakeArchive.Entry(
                id: "A1",
                message: OMEMOArchiveTests.archived(
                    forged, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60))
        ])
        try await OMEMOArchiveTests.catchUp(harness, through: "A1")

        let row = try #require(try harness.message(originID: "a1"))
        #expect(row.kind == .system)
        #expect(row.body == AccountSession.cannotDecryptText)
        #expect(row.identityChanged)
        #expect(row.senderDeviceFingerprint == nil)
        #expect(
            Set(
                try harness.database.omemoPreKeys(
                    accountID: harness.accountID, version: storeVersion
                ).map(\.keyID)) == preKeys)
        #expect(OMEMOArchiveTests.messagesSent(harness) == sent)
        await harness.stop()
    }

    // MARK: N2: an old key exchange never becomes current again

    @Test(.timeLimit(.minutes(1)), arguments: OMEMO.OMEMOVersion.allCases)
    func twoArchivedCopiesOfAnOldKeyExchangeLeaveTheCurrentSession(
        version: OMEMO.OMEMOVersion
    ) async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await Self.online(
            pep: pep, entries: entries, seed: Self.omemoChat(Self.bob))
        await harness.session.omemo.setForcedVersion(version)
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: version)

        // K1 (two messages, the key exchange repeated) reached the phone only; then bob's
        // device lost its session and started K2.
        let first = try await bob.send("K1 one", to: .direct(account), id: "k1a")
        let second = try await bob.send("K1 two", to: .direct(account), id: "k1b")
        #expect(
            pep.withdraw(
                preKey: try preKeyUsed(in: first, for: own, version: version), of: account,
                deviceID: own, version: version))
        try bob.database.deleteOMEMOSession(
            accountID: bob.accountID, jid: Self.alice, version: version == .v2 ? .v2 : .v03,
            deviceID: Int(own))
        let k2 = try await bob.send("from K2", to: .direct(account), id: "k2")
        try Self.deliver(k2, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "k2")?.body == "from K2" }

        let stamp = Date().addingTimeInterval(-600)
        entries.set([
            FakeArchive.Entry(
                id: "K1A",
                message: OMEMOArchiveTests.archived(first, from: "\(Self.bob)/phone", to: Self.me),
                stamp: stamp),
            FakeArchive.Entry(
                id: "K1B",
                message: OMEMOArchiveTests.archived(
                    second, from: "\(Self.bob)/phone", to: Self.me),
                stamp: stamp.addingTimeInterval(1)),
        ])
        try await OMEMOArchiveTests.catchUp(harness, through: "K1B")
        #expect(try harness.message(originID: "k1a")?.body == "K1 one")
        #expect(try harness.message(originID: "k1b")?.body == "K1 two")

        // This Mac still writes on K2's session, which bob has.
        let id = try await harness.session.send(text: "after catch-up", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let reply = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(reply, from: account).body == "after catch-up")
        await harness.stop()
    }

    // MARK: N3, R54: nothing a stranger sends makes them known

    /// A legacy message from the stranger's device `sid` the account has no session with.
    static func unknownDevice(_ stanza: Element, sid: UInt32, from: UInt32) throws -> Element {
        let text = stanza.xml().replacingOccurrences(of: "sid='\(from)'", with: "sid='\(sid)'")
        return try #require(SessionServer.elements(text).first)
    }

    @Test(.timeLimit(.minutes(1))) func aStrangerWhoWritesFirstStaysAStranger() async throws {
        let pep = FakePEP()
        let stranger = try OMEMOParty(Self.stranger, pep: pep)
        await stranger.start()
        await stranger.manager.setForcedVersion(.v03)
        // The stranger's server answers nothing, and no clock moves.
        let harness = try await Self.online(
            pep: pep, before: { iq in iq.to?.bare.description == Self.stranger ? [] : nil })
        await harness.session.omemo.setForcedVersion(.v03)
        let account = try JID(Self.alice)

        // A message in the clear makes a chat with a text in it.
        try harness.deliver(
            "<message type='chat' from='\(Self.stranger)/x' to='\(Self.me)' id='p1'>"
                + "<body>hi there</body><origin-id xmlns='urn:xmpp:sid:0' id='p1'/></message>")
        try await waitUntil("plain") { try harness.message(originID: "p1") != nil }

        // A valid key exchange from a device the account never read of the stranger, then
        // legacy messages from devices it has no session with.
        let kex = try await stranger.send("hello", to: .direct(account), id: "s0")
        try Self.deliver(kex, from: "\(Self.stranger)/x", to: harness)
        try await waitUntil("read") { try harness.message(originID: "s0")?.body == "hello" }
        let completion = try await Self.lastMessage(to: Self.stranger, in: harness)
        _ = try await stranger.open(completion, from: account)
        let strangerID = try await stranger.deviceID(.v03)
        for index in 1...5 {
            let message = try await stranger.send(
                "m\(index)", to: .direct(account), id: "s\(index)")
            try Self.deliver(
                try Self.unknownDevice(message, sid: 1_000 + UInt32(index), from: strangerID),
                from: "\(Self.stranger)/x", to: harness)
        }
        try await waitUntil("all five") { try harness.message(originID: "s5") != nil }
        await harness.session.omemo.settled()
        try await harness.barrier()

        #expect(Self.omemoRequests(to: Self.stranger, harness) == 0)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aChatTheUserReadIsNoStrangers() async throws {
        let pep = FakePEP()
        let stranger = try OMEMOParty(Self.stranger, pep: pep)
        await stranger.start()
        await stranger.manager.setForcedVersion(.v03)
        let harness = try await Self.online(pep: pep)
        await harness.session.omemo.setForcedVersion(.v03)
        let account = try JID(Self.alice)
        try harness.deliver(
            "<message type='chat' from='\(Self.stranger)/x' to='\(Self.me)' id='p1'>"
                + "<body>hi there</body><origin-id xmlns='urn:xmpp:sid:0' id='p1'/></message>")
        try await waitUntil("plain") { try harness.message(originID: "p1") != nil }
        // The user opened the chat and read it.
        let chatID = try #require(try harness.chat(Self.stranger)?.id)
        let row = try #require(try harness.message(originID: "p1")?.id)
        _ = try harness.database.markRead(chatID: chatID, upTo: row)

        let message = try await stranger.send("broken", to: .direct(account), id: "s1")
        let strangerID = try await stranger.deviceID(.v03)
        let kexOnly = try Self.unknownDevice(message, sid: 4_242, from: strangerID)
        // A key exchange from an unknown device decrypts; its list is read again.
        try Self.deliver(kexOnly, from: "\(Self.stranger)/x", to: harness)
        try await waitUntil("asked") { Self.omemoRequests(to: Self.stranger, harness) > 0 }
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aFloodOfStrangersCannotDelayAContactsRepair() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v03)
        // Every stranger's server holds what it is asked, for good.
        let harness = try await Self.online(
            pep: pep, before: { iq in iq.to?.domainpart == "elsewhere.test" ? [] : nil },
            seed: Self.omemoChat(Self.bob))
        await harness.session.omemo.setForcedVersion(.v03)
        try await OMEMOFixRoundTests.establish(bob, with: harness)
        let account = try JID(Self.alice)

        // Forty strangers send legacy messages the account has no session for.
        for index in 1...40 {
            let message = try await bob.send("flood \(index)", to: .direct(account))
            try Self.deliver(message, from: "s\(index)@elsewhere.test/x", to: harness)
        }
        // Then bob's session breaks: two messages in a row that do not authenticate.
        let before = Self.omemoRequests(to: Self.bob, harness)
        for index in 1...2 {
            let message = try await bob.send("broken \(index)", to: .direct(account))
            try Self.deliver(
                try OMEMOFixRoundTests.corruptedKeys(message), from: "\(Self.bob)/phone",
                to: harness)
        }
        // The bound only says how long a failing run takes: a worker held by a stranger's
        // server never reaches bob.
        try await waitUntil("bob's repair", timeout: .seconds(30)) {
            Self.omemoRequests(to: Self.bob, harness) > before
        }
        await harness.stop()
    }

    @Test func theRepairQueueKeepsOneJobPerJIDContactsFirstAndABound() throws {
        var queue = OMEMOManager.JobQueue()
        var taken: [Bool] = []
        let contact = try JID("bob@example.test")
        let device = DeviceAddress(jid: contact, deviceID: 7)
        taken.append(queue.add(.readLists(contact), known: true))
        // One entry per bare JID: the repair joins the list read already queued.
        taken.append(queue.add(.repair(device, .v03, failedAt: Date()), known: true))
        #expect(queue.count == 1)

        var strangers: [JID] = []
        for index in 0..<(OMEMOManager.JobQueue.capacity - 1) {
            let jid = try JID("s\(index)@elsewhere.test")
            strangers.append(jid)
            taken.append(queue.add(.readLists(jid), known: false))
        }
        #expect(queue.count == OMEMOManager.JobQueue.capacity)
        // Full: another contact's work drops the oldest stranger's.
        let carol = try JID("carol@example.test")
        taken.append(queue.add(.readLists(carol), known: true))
        #expect(taken.allSatisfy { $0 })
        #expect(queue.count == OMEMOManager.JobQueue.capacity)
        #expect(!queue.contains(strangers[0]))
        // Contacts first, in the order they came; then strangers.
        var order: [JID?] = []
        for _ in 0..<3 { order.append(queue.next()?.jid) }
        #expect(order == [contact, carol, strangers[1]])
    }

    @Test func aFullQueueOfContactsRefusesMore() throws {
        var queue = OMEMOManager.JobQueue()
        var taken: [Bool] = []
        for index in 0..<OMEMOManager.JobQueue.capacity {
            taken.append(queue.add(.readLists(try JID("c\(index)@example.test")), known: true))
        }
        #expect(taken.allSatisfy { $0 })
        let late = queue.add(.readLists(try JID("late@example.test")), known: true)
        let stranger = queue.add(.readLists(try JID("s@elsewhere.test")), known: false)
        #expect(!late && !stranger)
        let first = queue.next()?.jid
        #expect(first == (try JID("c0@example.test")))
    }

    // MARK: N4: a stop in the middle of a page

    @Test(.timeLimit(.minutes(1))) func aStopInTheMiddleOfAPageStoresNoNotices() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(
            pep: pep, entries: entries, seed: Self.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let stamp = Date().addingTimeInterval(-600)
        var archived: [FakeArchive.Entry] = []
        for index in 1...3 {
            let message = try await bob.send("m\(index)", to: .direct(account), id: "e\(index)")
            archived.append(
                FakeArchive.Entry(
                    id: "E\(index)",
                    message: OMEMOArchiveTests.archived(
                        message, from: "\(Self.bob)/phone", to: Self.me),
                    stamp: stamp.addingTimeInterval(Double(index))))
        }
        entries.set(archived)

        // The first archived copy is held in the decrypt; meanwhile the session stops.
        let gate = DecryptGate()
        await harness.session.omemo.setArchiveGate { await gate.pass() }
        let archive = try #require(await harness.session.archive)
        await archive.sessionStarted(ownJID: try JID(Self.me))
        try await waitUntil("held") { await gate.waiting > 0 }
        let stopping = Task { await harness.stop() }
        // The catch-up was cancelled before the account went offline.
        try await waitUntil("offline") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0[attribute: "type"] == "unavailable"
            }
        }
        await gate.open()
        await stopping.value

        // Once the stop returned, the run had ended: the message it was opening is stored,
        // nothing it could not read was kept as unreadable, and the page was not recorded.
        let rows = try harness.messages()
        #expect(!rows.contains { $0.kind == .system })
        #expect(rows.filter { $0.originID?.hasPrefix("e") == true }.map(\.body) == ["m1"])
        #expect(
            try harness.database.lastKnownArchiveID(
                accountID: harness.accountID, archive: Self.alice) == nil)

        // The next session reads the page again, and every message.
        let next = try await Self.online(pep: pep, entries: entries, database: harness.database)
        try await OMEMOArchiveTests.catchUp(next, through: "E3")
        for index in 1...3 {
            #expect(try next.message(originID: "e\(index)")?.body == "m\(index)")
        }
        #expect(try next.messages().filter { $0.originID?.hasPrefix("e") == true }.count == 3)
        await next.stop()
    }

    /// C1 guarantee 1: `stop()` returns only once the catch-up's run has ended, whatever it
    /// was doing; here it is held writing a page, outside OMEMO.
    @Test(.timeLimit(.minutes(1)))
    func aStopWaitsForTheCatchUpToEnd() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let harness = try await Self.online(pep: pep, entries: entries)
        entries.set([
            FakeArchive.Entry(
                id: "P1",
                message: try #require(
                    SessionServer.elements(
                        "<message xmlns='jabber:client' type='chat' from='\(Self.bob)/phone'"
                            + " to='\(Self.me)'><body>plain</body>"
                            + "<origin-id xmlns='urn:xmpp:sid:0' id='p1'/></message>"
                    ).first),
                stamp: Date().addingTimeInterval(-60))
        ])
        let gate = DecryptGate()
        let archive = try #require(await harness.session.archive as? MAMCatchUp)
        await archive.setPageGate { await gate.pass() }
        await archive.sessionStarted(ownJID: try JID(Self.me))
        try await waitUntil("held") { await gate.waiting > 0 }

        let stopped = Locked(false)
        let stopping = Task {
            await harness.stop()
            stopped.set(true)
        }
        // The stop has gone past its other steps: the stream is closed.
        try await waitUntil("offline") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0[attribute: "type"] == "unavailable"
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!stopped.value, "the stop returned while the catch-up still ran")
        await gate.open()
        await stopping.value
        #expect(stopped.value)
    }

    // MARK: R53: without the lease, and taking it later

    @Test(.timeLimit(.minutes(1)))
    func aWaiterTakesTheLeaseOnceItIsLetGo() async throws {
        let database = try AppDatabase.inMemory()
        let leases = OMEMOLeases()
        let held = try #require(leases.acquire(database: database, accountID: 1))
        let waiter = Task { await leases.next(database: database, accountID: 1) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(leases.acquire(database: database, accountID: 1) == nil)
        held.release()
        let taken = try #require(await waiter.value)
        // Held by the waiter now.
        #expect(leases.acquire(database: database, accountID: 1) == nil)
        taken.release()
        #expect(leases.acquire(database: database, accountID: 1) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledWaiterTakesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let leases = OMEMOLeases()
        let held = try #require(leases.acquire(database: database, accountID: 1))
        let waiter = Task { await leases.next(database: database, accountID: 1) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        #expect(await waiter.value == nil)
        held.release()
        #expect(leases.acquire(database: database, accountID: 1) != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionWithoutTheLeaseKeepsItsMessagesAndReadsThemOnceItHoldsIt() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // The account's keys are made and published by a first session, which stops; then
        // the store is held as by an engine that has not stopped yet (a cut session's).
        let first = try await Self.online(
            pep: pep, entries: entries, seed: Self.omemoChat(Self.bob))
        #expect(first.session.hasOMEMO)
        await first.stop()
        let account = try JID(Self.alice)
        let held = try #require(
            OMEMOLeases.shared.acquire(database: first.database, accountID: first.accountID))

        // A second session of the account, while the store is held.
        let second = try await Self.online(pep: pep, entries: entries, database: first.database)
        #expect(!second.session.hasOMEMO)
        let live = try await bob.send("while waiting", to: .direct(account), id: "w1")
        try Self.deliver(live, from: "\(Self.bob)/phone", to: second)
        let archivedCopy = try await bob.send("from the archive", to: .direct(account), id: "w0")
        entries.set([
            FakeArchive.Entry(
                id: "W0",
                message: OMEMOArchiveTests.archived(
                    archivedCopy, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60))
        ])
        let archive = try #require(await second.session.archive)
        await archive.sessionStarted(ownJID: try JID(Self.me))
        try await second.barrier()
        try await Task.sleep(for: .milliseconds(200))
        // Nothing shown yet: no fallback, no notice, no page recorded.
        #expect(try second.message(originID: "w1") == nil)
        #expect(try second.message(originID: "w0") == nil)
        #expect(
            try second.database.lastKnownArchiveID(
                accountID: second.accountID, archive: Self.alice) == nil)

        // The holder lets go: the second session takes the store and reads both.
        held.release()
        try await waitUntil("lease") { second.session.hasOMEMO }
        try await waitUntil("live message read") {
            try second.message(originID: "w1")?.body == "while waiting"
        }
        try await waitUntil("archived message read") {
            try second.message(originID: "w0")?.body == "from the archive"
        }
        #expect(try second.message(originID: "w1")?.encryption == .omemo)
        #expect(try second.database.omemoPending(accountID: second.accountID).isEmpty)

        // And it sends in OMEMO chats now.
        let chatID = try #require(try second.chat(Self.bob)?.id)
        let id = try await second.session.send(text: "back", chatID: chatID)
        let originID = try #require(try second.database.message(id: id)?.originID)
        let reply = try await OMEMOPipelineTests.sent(originID, by: second)
        #expect(try await bob.open(reply, from: account).body == "back")
        await second.stop()
    }

    // MARK: R57: after a cut

    /// A session whose stop runs out of time (ruling R53): a download from bob that never
    /// ends holds the stop, and the session's clock is stepped past its bound.
    static func cutSession(pep: FakePEP) async throws -> (SessionHarness, StuckMediaTransport) {
        let transport = StuckMediaTransport()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XippiSessionCut-\(UUID().uuidString)")
        var options = SessionServer.Options()
        options.roster = .items(["<item jid='\(bob)' subscription='both'/>"], version: "v1")
        let harness = try await SessionHarness(
            options: options,
            media: MediaEnvironment(
                directory: directory.appendingPathComponent("Media"), transport: transport,
                bytestreams: nil))
        let account = try JID(alice)
        harness.server.setResponder { iq in pep.answer(iq, from: account).map { [$0.xml()] } }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        let link = "https://files.example.test/bob/photo.png"
        try harness.deliver(
            "<message from='\(bob)/phone' to='\(me)' type='chat' id='f1'><body>\(link)</body>"
                + "<x xmlns='jabber:x:oob'><url>\(link)</url></x></message>")
        try await waitUntil("download held") { transport.started.value == 1 }

        let ended = Locked(false)
        let session = harness.session
        let stop = Task {
            await session.stop()
            ended.set(true)
        }
        for _ in 0..<10 where !ended.value {
            await harness.sessionClock.advance(by: .seconds(5))
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitUntil("stop returned") { ended.value }
        await stop.value
        return (harness, transport)
    }

    @Test(.timeLimit(.minutes(1)))
    func aMessageAfterTheCutIsKeptForTheSessionThatHoldsTheLease() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let account = try JID(Self.alice)
        let (cut, transport) = try await Self.cutSession(pep: pep)
        defer { transport.release() }

        // After the cut, an OMEMO message is never decrypted: it is kept as it came.
        let first = try #require(
            SessionServer.elements(
                OMEMOPipelineTests.delivered(
                    try await bob.send("after the cut", to: .direct(account), id: "c1"),
                    from: "\(Self.bob)/phone")
            ).first)
        #expect(await cut.session.keepsOMEMOForLater(first))
        #expect(await cut.session.keepForLater(first, carbon: nil))
        #expect(try cut.message(originID: "c1") == nil)
        #expect(try cut.database.omemoPending(accountID: cut.accountID).count == 1)
        // Nothing of it was decrypted or answered.
        #expect(await cut.session.omemo.decryptAttempts == 0)

        // The next session takes the store once the cut engine let go, and reads it.
        let next = try await Self.online(pep: pep, database: cut.database)
        try await waitUntil("lease") { next.session.hasOMEMO }
        try await waitUntil("read at start") {
            try next.message(originID: "c1")?.body == "after the cut"
        }

        // Kept later, while the next session holds the lease: read as it is kept.
        let second = try #require(
            SessionServer.elements(
                OMEMOPipelineTests.delivered(
                    try await bob.send("still draining", to: .direct(account), id: "c2"),
                    from: "\(Self.bob)/phone")
            ).first)
        #expect(await cut.session.keepForLater(second, carbon: nil))
        try await waitUntil("read as kept") {
            try next.message(originID: "c2")?.body == "still draining"
        }
        #expect(try next.messages().allSatisfy { $0.kind != .system })
        // A row goes once its message is stored.
        try await waitUntil("kept rows removed") {
            try next.database.omemoPending(accountID: next.accountID).isEmpty
        }
        await next.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func anAnswerThatCouldNotBeSentIsAskedForAgain() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        // Bob writes 53 messages on one ratchet key without hearing back.
        for index in 0..<53 {
            let message = try await bob.send("m\(index)", to: .direct(alice.jid))
            _ = try await alice.open(message, from: bob.jid)
        }
        // The 54th asks for a heartbeat, which cannot go out.
        alice.sender.setOffline(true)
        let due = try await bob.send("m53", to: .direct(alice.jid))
        _ = try await alice.open(due, from: bob.jid)
        alice.sender.setOffline(false)
        let before = alice.sender.messages.count
        // So the next one asks for it again.
        let next = try await bob.send("m54", to: .direct(alice.jid))
        _ = try await alice.open(next, from: bob.jid)
        #expect(alice.sender.messages.count == before + 1)
    }

    // MARK: R60: trust belongs to the identity key

    @Test(.timeLimit(.minutes(1)))
    func anUndecidedLegacyOnlyDeviceNeitherGetsKeysNorTurnsTheChatToLegacy() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        let bobID = try await bob.deviceID(.v2)
        // Alice writes to bob (his lists are read) and verifies his device.
        _ = try await alice.send("hello", to: .direct(bob.jid))
        try await alice.manager.setTrust(
            .verified, for: DeviceAddress(jid: bob.jid, deviceID: bobID), version: .v2)

        // A device appears in bob's legacy list only.
        let list = alice.manager.engine.deviceListElement(version: .v03, devices: [bobID, 4_242])
        _ = try await alice.manager.engine.processDeviceList(list, from: bob.jid, version: .v03)

        #expect(await alice.manager.chooseVersion(for: [bob.jid]) == .v2)
        let identities = await alice.manager.identities(of: bob.jid)
        let flagged = try #require(identities.first { $0.deviceIDs[.v03] == [4_242] })
        #expect(flagged.needsDecision)
        #expect(flagged.trust == .undecided)
        // Forced to legacy, it still gets no keys.
        await alice.manager.setForcedVersion(.v03)
        let legacy = try await alice.send("legacy", to: .direct(bob.jid))
        #expect(!OMEMOFixRoundTests.keyedDevices(legacy).contains(4_242))
    }

    /// Task 24: a refresh shows the keys of a contact's listed devices no bundle has shown.
    @Test(.timeLimit(.minutes(1)))
    func aRefreshShowsTheKeysOfAContactsListedDevices() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        let bobID = try await bob.deviceID(.v2)
        for version in OMEMO.OMEMOVersion.allCases {
            let list = alice.manager.engine.deviceListElement(version: version, devices: [bobID])
            _ = try await alice.manager.engine.processDeviceList(
                list, from: bob.jid, version: version)
        }
        #expect(await alice.manager.identities(of: bob.jid).allSatisfy { $0.identityKey == nil })

        await alice.manager.refreshIdentities(of: bob.jid)
        let identities = await alice.manager.identities(of: bob.jid)
        // One key in both versions (R66).
        #expect(identities.count == 1)
        #expect(identities.first?.identityKey != nil)
        #expect(identities.first?.deviceIDs == [.v2: [bobID], .v03: [bobID]])
    }
}

/// Holds whoever passes until `open()`.
actor DecryptGate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var waiting = 0

    func pass() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { held.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in held { continuation.resume() }
        held = []
    }
}
