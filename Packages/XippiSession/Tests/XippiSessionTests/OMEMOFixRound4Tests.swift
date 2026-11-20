import Foundation
import OMEMO
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A room lifecycle that knows its occupants' real JIDs by occupant id, as a joined
/// non-anonymous room learns them from presence.
actor OccupantRooms: RoomLifecycle {
    let own: RoomOccupant?
    let byOccupantID: [String: JID]

    init(own: RoomOccupant?, byOccupantID: [String: JID]) {
        self.own = own
        self.byOccupantID = byOccupantID
    }

    func ownOccupant(in chatID: Int64) async -> RoomOccupant? { own }
    func realJID(of occupant: JID) async -> JID? { nil }
    func sessionStarted(ownJID: JID) async {}
    func sessionResumed() async {}
    func sessionEnded(resumable: Bool) async {}
    func handle(presence: Element) async -> Bool { false }
    func handle(message: Element) async -> Bool { false }
    func join(chatID: Int64) async {}
    func leave(chatID: Int64) async {}
    func changeNick(chatID: Int64, to nick: String) async {}
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? {
        byOccupantID[occupantID]
    }
    func reloadWanted() async {}
    func rosterItemRemoved(_ jid: JID) async {}
    func state(of chatID: Int64) async -> RoomState { .joined }
}

/// Fix round 4 of Task 17b.
@Suite(.timeLimit(.minutes(1))) struct OMEMOFixRound4Tests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"
    static let carol = "carol@example.test"
    static let room = OMEMOPipelineTests.room

    static func deliver(_ stanza: Element, from: String, to harness: SessionHarness) throws {
        try harness.deliver(OMEMOPipelineTests.delivered(stanza, from: from))
    }

    /// Archive queries answered from `entries` by archive (nil: the account's own), the room's
    /// results from the room.
    static func archiveAnswer(
        _ iq: Element, entries: Locked<[String: [FakeArchive.Entry]]>
    ) -> [String]? {
        guard let query = iq.child("query", namespace: MAM.namespace),
            let queryID = query[attribute: "queryid"], let account = try? JID(alice)
        else { return nil }
        let archive = iq.to?.bare
        let page = entries.value[archive?.description ?? alice] ?? []
        let results = page.map {
            FakeArchive.result($0, queryID: queryID, from: archive?.description, to: account).xml()
        }
        var rsm = Element("set", namespace: RSM.namespace)
        if let first = page.first, let last = page.last {
            rsm.append(Element("first", namespace: RSM.namespace, children: [.text(first.id)]))
            rsm.append(Element("last", namespace: RSM.namespace, children: [.text(last.id)]))
        }
        let fin = Element(
            "fin", namespace: MAM.namespace, attributes: ["complete": "true"],
            children: [.element(rsm)])
        return results + [iq.iqResult(payload: fin).xml()]
    }

    // MARK: N6, R69 (a): members of an OMEMO room are known

    /// Carol, a member but no contact, writes from a device the account has not read; the
    /// account wrote to the room before, so it has the member list.
    static func newDeviceOfAMember(trustAfterSending: RoomTrust?) async throws -> (Int, Int) {
        let pep = FakePEP()
        let carol = try OMEMOParty(Self.carol, pep: pep)
        await carol.start()
        let room = try JID(Self.room)
        pep.setMembers([try JID(Self.alice), carol.jid], affiliation: .member, of: room)
        let suitable = RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: true)
        let harness = try await OMEMOPipelineTests.roomHarness(
            pep: pep, trust: suitable, realJIDs: [try room.withResource("carol"): carol.jid])
        let chatID = try OMEMOPipelineTests.chatID(harness, Self.room)
        await harness.session.resendPending(chatID: chatID)
        let id = try await harness.session.send(text: "hello all", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        _ = try await OMEMOPipelineTests.sent(originID, by: harness)
        if let trustAfterSending {
            await harness.session.setRoomTrust(trustAfterSending, for: room)
        }

        let tablet = try OMEMOParty(Self.carol, pep: pep)
        await tablet.start()
        let before = OMEMOFixRoundTests.iqs(to: Self.carol, harness)
        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let message = try await tablet.send(
            "from my tablet", to: .room(omemoRoom, chatID: 1), id: "t1")
        try Self.deliver(message, from: "\(Self.room)/carol", to: harness)
        try await waitUntil("stored") { try harness.message(originID: "t1") != nil }
        await harness.session.omemo.settled()
        try await harness.barrier()
        let after = OMEMOFixRoundTests.iqs(to: Self.carol, harness)
        await harness.stop()
        return (before, after)
    }

    @Test func aMemberOfAnOMEMORoomIsKnown() async throws {
        let (before, after) = try await Self.newDeviceOfAMember(trustAfterSending: nil)
        #expect(after > before)
    }

    @Test func aMemberIsNoOneWhereOMEMOIsNotAllowed() async throws {
        let open = RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: false)
        let (before, after) = try await Self.newDeviceOfAMember(trustAfterSending: open)
        #expect(after == before)
    }

    // MARK: N7: kept messages are read when the stream resumes

    @Test func keptMessagesAreReadOnResumeBeforeLiveOnes() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        // Three messages kept, not yet read (as a drain the stream cut short leaves them).
        for index in 1...3 {
            let message = try await bob.send("kept \(index)", to: .direct(account), id: "k\(index)")
            let element = try #require(
                SessionServer.elements(
                    OMEMOPipelineTests.delivered(message, from: "\(Self.bob)/phone")
                ).first)
            #expect(
                try harness.database.keepOMEMOPending(
                    OMEMOPendingRecord(
                        accountID: harness.accountID, stanza: element.xml(), carbon: nil,
                        receivedAt: Date(), sender: Self.bob, senderKnown: true)))
        }

        // The stream drops and resumes; then a live message from bob.
        try await harness.drop()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }
        let live = try await bob.send("live", to: .direct(account), id: "l1")
        try Self.deliver(live, from: "\(Self.bob)/phone", to: harness)

        try await waitUntil("all read") {
            try ["k1", "k2", "k3", "l1"].allSatisfy { try harness.message(originID: $0) != nil }
        }
        let ids = try ["k1", "k2", "k3", "l1"].map {
            try #require(try harness.message(originID: $0)?.id)
        }
        #expect(ids == ids.sorted())
        #expect(try harness.message(originID: "k3")?.body == "kept 3")
        #expect(try harness.database.omemoPending(accountID: harness.accountID).isEmpty)
        await harness.stop()
    }

    // MARK: m11: kept messages read late change no current session

    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func keptMessagesOfAnOldKeyExchangeLeaveTheCurrentSession(version: OMEMO.OMEMOVersion)
        async throws
    {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        await harness.session.omemo.setForcedVersion(version)
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: version)

        // K1 (repeated key exchange) waits in the store; bob's device starts K2, read live.
        var k1: [Element] = []
        for (text, id) in [("K1 one", "k1a"), ("K1 two", "k1b")] {
            k1.append(try await bob.send(text, to: .direct(account), id: id))
        }
        #expect(
            pep.withdraw(
                preKey: try preKeyUsed(in: k1[0], for: own, version: version), of: account,
                deviceID: own, version: version))
        try bob.database.deleteOMEMOSession(
            accountID: bob.accountID, jid: Self.alice,
            version: version == .v2 ? .v2 : .v03, deviceID: Int(own))
        let k2 = try await bob.send("from K2", to: .direct(account), id: "k2")
        try Self.deliver(k2, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("K2") { try harness.message(originID: "k2")?.body == "from K2" }
        for message in k1 {
            let element = try #require(
                SessionServer.elements(
                    OMEMOPipelineTests.delivered(message, from: "\(Self.bob)/phone")
                ).first)
            #expect(
                try harness.database.keepOMEMOPending(
                    OMEMOPendingRecord(
                        accountID: harness.accountID, stanza: element.xml(), carbon: nil,
                        receivedAt: Date(), sender: Self.bob, senderKnown: true)))
        }
        await harness.session.drainPendingOMEMO()
        #expect(try harness.message(originID: "k1b")?.body == "K1 two")

        // This Mac still writes on K2, which bob has.
        let id = try await harness.session.send(text: "after", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let reply = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(reply, from: account).body == "after")
        await harness.stop()
    }

    // MARK: A room's archive page deferred without the lease

    @Test func aRoomArchivePageDeferredWithoutTheLeaseIsReadOnceItIsTaken() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let room = try JID(Self.room)
        pep.setMembers([try JID(Self.alice), bob.jid], affiliation: .member, of: room)
        // The account's keys come from a first session; then the store is held, as by a cut
        // session's engine that has not stopped yet.
        let first = try await OMEMOFixRound3Tests.online(pep: pep)
        await first.stop()
        let held = try #require(
            OMEMOLeases.shared.acquire(database: first.database, accountID: first.accountID))

        let entries = Locked<[String: [FakeArchive.Entry]]>([:])
        let second = try await SessionHarness(database: first.database) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        let own = RoomOccupant(jid: try room.withResource("alice"), occupantID: "occ-alice")
        await second.session.setRoomLifecycle(
            OccupantRooms(own: own, byOccupantID: ["occ-bob": bob.jid]))
        let trust = RoomTrust(
            stanzaIDs: true, occupantIDs: true, nonAnonymous: true, membersOnly: true)
        await second.session.setRoomTrust(trust, for: room)
        let account = try JID(Self.alice)
        second.server.setResponder { iq in
            if let answer = pep.answer(iq, from: account) { return [answer.xml()] }
            return Self.archiveAnswer(iq, entries: entries)
        }
        try await second.goOnline()
        #expect(!second.session.hasOMEMO)

        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let sent = try await bob.send("room secret", to: .room(omemoRoom, chatID: 1), id: "g1")
        var archived = OMEMOArchiveTests.archived(sent, from: "\(Self.room)/bob", to: Self.alice)
        archived[attribute: "to"] = nil
        archived.append(
            Element(
                "occupant-id", namespace: MUCPresence.occupantIDNamespace,
                attributes: ["id": "occ-bob"]))
        entries.set([Self.room: [FakeArchive.Entry(id: "R1", message: archived, stamp: Date())]])
        let chatID = try OMEMOPipelineTests.chatID(second, Self.room)
        let archive = try #require(await second.session.archive as? MAMCatchUp)
        await archive.roomJoined(
            RoomArchive(chatID: chatID, room: room, ownOccupant: own, trust: trust, nick: "alice"))
        try await second.barrier()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try second.message(originID: "g1") == nil)
        #expect(
            try second.database.lastKnownArchiveID(
                accountID: second.accountID, archive: Self.room) == nil)

        held.release()
        try await waitUntil("lease") { second.session.hasOMEMO }
        try await waitUntil("room page read") {
            try second.message(originID: "g1")?.body == "room secret"
        }
        await second.stop()
    }

    // MARK: m8: nothing is decrypted from the archive after a cut

    @Test func theArchiveHookOpensNothingAfterACut() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let (cut, transport, gate) = try await Self.cutWithEngineHeld(pep: pep)
        defer { transport.release() }
        let account = try JID(Self.alice)
        let message = try await bob.send("archived", to: .direct(account), id: "a1")
        let archived = ArchivedEncryptedMessage(
            message: OMEMOArchiveTests.archived(message, from: "\(Self.bob)/phone", to: Self.me),
            sender: bob.jid, conversation: bob.jid, inRoom: false, roomTrust: nil,
            outgoing: false, time: Date(), chatID: nil, storedCopy: nil)
        let catchUp = try #require(await cut.session.archive as? MAMCatchUp)
        let hook = await catchUp.openEncrypted
        let attempts = await cut.session.omemo.decryptAttempts
        #expect(await hook(archived) == nil)
        #expect(await cut.session.omemo.decryptAttempts == attempts)
        await gate.open()
    }

    /// A session cut while its engine's stop is held, so the engine still holds the lease.
    static func cutWithEngineHeld(pep: FakePEP) async throws
        -> (SessionHarness, StuckMediaTransport, DecryptGate)
    {
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
        let gate = DecryptGate()
        let omemo = harness.session.omemo
        await harness.session.setEngineStop {
            await gate.pass()
            await omemo.stop()
        }
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
        try await waitUntil("engine stop held") { await gate.waiting > 0 }
        return (harness, transport, gate)
    }

    // MARK: m10: an engine error does not hold the catch-up

    @Test func anEngineErrorDuringCatchUpLeavesANoticeACopyCanStillUpgrade() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, entries: entries, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let message = try await bob.send("archived", to: .direct(account), id: "e1")
        entries.set([
            FakeArchive.Entry(
                id: "E1",
                message: OMEMOArchiveTests.archived(
                    message, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60))
        ])
        // The engine fails on its own store: its OMEMO 2 identity no longer reads.
        var record = try #require(
            try harness.database.omemoAccount(accountID: harness.accountID, version: .v2))
        record.identityPrivate = Data([1, 2, 3])
        try harness.database.saveOMEMOAccount(record)
        try await OMEMOArchiveTests.catchUp(harness, through: "E1")
        let row = try #require(try harness.message(originID: "e1"))
        #expect(row.kind == .system)
        #expect(row.body == AccountSession.cannotDecryptText)
        #expect(!row.identityChanged)
        await harness.stop()
    }

    // MARK: m7: a correction is not read into a notice

    @Test func anUnreadableCorrectionStaysANoticeWhenACopyDecrypts() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: .v2)
        let first = try await bob.send("first", to: .direct(account), id: "m1")
        try Self.deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("first") { try harness.message(originID: "m1")?.body == "first" }

        var plain = ChatMessage.text("corrected", to: account, id: "c2")
        plain.append(
            Element("replace", namespace: ChatMessage.correctionNamespace, attributes: ["id": "m1"])
        )
        #expect(try await bob.manager.send(plain, to: .direct(account)))
        let correction = try #require(bob.sender.messages.last)
        try Self.deliver(
            try OMEMOFixRoundTests.rekeyed(correction, from: own, to: 1),
            from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("notice") {
            try harness.message(originID: "c2")?.body == AccountSession.notForThisDeviceText
        }
        try Self.deliver(correction, from: "\(Self.bob)/phone", to: harness)
        try await harness.barrier()
        #expect(try harness.message(originID: "c2")?.kind == .system)
        #expect(try harness.message(originID: "m1")?.body == "first")
        await harness.stop()
    }

    // MARK: m6: a reaction inside an OMEMO 2 envelope

    @Test func aReactionInsideAnOMEMO2EnvelopeIsStored() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let first = try await bob.send("first", to: .direct(account), id: "m1")
        try Self.deliver(first, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("first") { try harness.message(originID: "m1") != nil }
        let target = try #require(try harness.message(originID: "m1")?.id)

        var plain = Element.message(type: "chat", to: account)
        plain[attribute: "id"] = "r1"
        plain.append(
            Element(
                "reactions", namespace: ChatMessage.reactionsNamespace, attributes: ["id": "m1"],
                children: [
                    .element(
                        Element(
                            "reaction", namespace: ChatMessage.reactionsNamespace,
                            children: [.text("👍")]))
                ]))
        #expect(try await bob.manager.send(plain, to: .direct(account)))
        let sent = try #require(bob.sender.messages.last)
        #expect(sent.child("reactions", namespace: ChatMessage.reactionsNamespace) == nil)
        try Self.deliver(sent, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("reaction stored") {
            try harness.database.reactions(messageID: target).contains { $0.emojis.contains("👍") }
        }
        await harness.stop()
    }
}
