import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// OMEMO messages that come back from the archive (MAM catch-up): decrypted before they are
/// stored, after the store's dedup, without answering anything and without changing a session
/// when they cannot be read.
@Suite(.timeLimit(.minutes(1))) struct OMEMOArchiveTests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"

    /// `stanza` as an archive keeps it: in `jabber:client`, from and to as given.
    static func archived(_ stanza: Element, from: String, to: String) -> Element {
        var element = clientNamespaced(stanza)
        element[attribute: "from"] = from
        element[attribute: "to"] = to
        return element
    }

    static func clientNamespaced(_ element: Element) -> Element {
        var copy = element
        if copy.namespace == nil { copy.namespace = "jabber:client" }
        copy.children = copy.children.map { node in
            guard case .element(let child) = node, child.namespace == nil else { return node }
            return .element(clientNamespaced(child))
        }
        return copy
    }

    /// Answers the session's archive queries from `entries` as a server pages them (RSM):
    /// `max` at most, what follows `after`, or the newest page for an empty `before`.
    static func archiveAnswer(_ iq: Element, entries: [FakeArchive.Entry]) -> [String]? {
        guard let query = iq.child("query", namespace: MAM.namespace),
            let queryID = query[attribute: "queryid"]
        else { return nil }
        let set = query.child("set", namespace: RSM.namespace)
        let max = set?.child("max", namespace: RSM.namespace).flatMap { Int($0.text) } ?? 100
        var page: [FakeArchive.Entry]
        let complete: Bool
        if let after = set?.child("after", namespace: RSM.namespace)?.text,
            let index = entries.firstIndex(where: { $0.id == after })
        {
            page = Array(entries[(index + 1)...].prefix(max))
            complete = index + 1 + max >= entries.count
        } else if set?.child("before", namespace: RSM.namespace) != nil {
            page = Array(entries.suffix(max))
            complete = entries.count <= max
        } else {
            page = Array(entries.prefix(max))
            complete = entries.count <= max
        }
        guard let account = try? JID(alice) else { return nil }
        let results = page.map {
            FakeArchive.result($0, queryID: queryID, from: nil, to: account).xml()
        }
        var rsm = Element("set", namespace: RSM.namespace)
        if let first = page.first, let last = page.last {
            rsm.append(Element("first", namespace: RSM.namespace, children: [.text(first.id)]))
            rsm.append(Element("last", namespace: RSM.namespace, children: [.text(last.id)]))
        }
        let fin = Element(
            "fin", namespace: MAM.namespace, attributes: ["complete": complete ? "true" : "false"],
            children: [.element(rsm)])
        return results + [iq.iqResult(payload: fin).xml()]
    }

    /// A session whose PubSub comes from `pep` and whose archive holds `entries`.
    static func online(
        pep: FakePEP, entries: Locked<[FakeArchive.Entry]>,
        seed: @escaping (AppDatabase, Int64) throws -> Void = { _, _ in }
    ) async throws -> SessionHarness {
        let harness = try await SessionHarness(seed: seed)
        let account = try JID(alice)
        harness.server.setResponder { iq in
            if let answer = pep.answer(iq, from: account) { return [answer.xml()] }
            return archiveAnswer(iq, entries: entries.value)
        }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        return harness
    }

    /// Runs the account's catch-up and waits until it stored the archive through `id`.
    static func catchUp(
        _ harness: SessionHarness, through id: String, timeout: Duration = .seconds(5)
    ) async throws {
        let archive = try #require(await harness.session.archive)
        await archive.sessionStarted(ownJID: try JID(me))
        try await waitUntil("archive stored through \(id)", timeout: timeout) {
            try harness.database.lastKnownArchiveID(
                accountID: harness.accountID, archive: alice) == id
        }
    }

    static func messagesSent(_ harness: SessionHarness) -> Int {
        harness.server.stanzas.filter { $0.name == "message" }.count
    }

    static func sessionState(_ harness: SessionHarness, version: XippiStore.OMEMOVersion)
        throws -> [Data]
    {
        try harness.database.omemoSessions(
            accountID: harness.accountID, jid: bob, version: version
        ).map(\.state)
    }

    // MARK: Direct messages

    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func anArchiveCopyBeforeTheLiveCopy(version: OMEMO.OMEMOVersion) async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        await bob.manager.setForcedVersion(version)
        let harness = try await Self.online(pep: pep, entries: entries)
        let account = try JID(Self.alice)
        let preKeys = try harness.database.omemoPreKeys(
            accountID: harness.accountID, version: OMEMOStoreAdapter.stored(version)
        ).count

        // Bob's first message (a key exchange) reached another of our devices; this one finds
        // it in the archive.
        let sent = try await bob.send("from the archive", to: .direct(account), id: "o1")
        entries.set([
            FakeArchive.Entry(
                id: "A1", message: Self.archived(sent, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60))
        ])
        let before = Self.messagesSent(harness)
        try await Self.catchUp(harness, through: "A1")

        let row = try #require(try harness.message(originID: "o1"))
        #expect(row.body == "from the archive")
        #expect(row.encryption == .omemo)
        #expect(row.senderDeviceFingerprint != nil)
        #expect(row.archiveID == "A1")
        // The pre key went once, with the session; catch-up answers nothing.
        #expect(
            try harness.database.omemoPreKeys(
                accountID: harness.accountID, version: OMEMOStoreAdapter.stored(version)
            ).count == preKeys - 1)
        try await harness.barrier()
        #expect(Self.messagesSent(harness) == before)

        // The live copy now: a copy of the stored row, never decrypted again.
        let attempts = await harness.session.omemo.decryptAttempts
        var live = sent
        live.append(
            Element(
                "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                attributes: ["by": Self.alice, "id": "A1"]))
        try harness.deliver(OMEMOPipelineTests.delivered(live, from: "\(Self.bob)/phone"))
        try await harness.barrier()
        #expect(await harness.session.omemo.decryptAttempts == attempts)
        #expect(try harness.messages().map(\.body) == ["from the archive"])
        await harness.stop()
    }

    @Test func theLiveCopyBeforeTheArchiveCopy() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries)
        let account = try JID(Self.alice)

        let sent = try await bob.send("live first", to: .direct(account), id: "o2")
        var live = sent
        live.append(
            Element(
                "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                attributes: ["by": Self.alice, "id": "A2"]))
        try harness.deliver(OMEMOPipelineTests.delivered(live, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "o2")?.body == "live first" }
        let attempts = await harness.session.omemo.decryptAttempts
        let state = try Self.sessionState(harness, version: .v2)
        let preKeys = try harness.database.omemoPreKeys(accountID: harness.accountID, version: .v2)
            .count

        // The archive's copy, and a second copy of the same key exchange under ids the store
        // does not know: neither takes the pre key or the session a second time.
        var unknown = Self.archived(sent, from: "\(Self.bob)/phone", to: Self.me)
        unknown[attribute: "id"] = "other-id"
        unknown.children.removeAll { node in
            if case .element(let child) = node {
                return child.namespace == ChatMessage.stanzaIDNamespace
            }
            return false
        }
        entries.set([
            FakeArchive.Entry(
                id: "A2", message: Self.archived(sent, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60)),
            FakeArchive.Entry(id: "A3", message: unknown, stamp: Date().addingTimeInterval(-50)),
        ])
        let before = Self.messagesSent(harness)
        try await Self.catchUp(harness, through: "A3")

        #expect(try harness.messages().map(\.body) == ["live first"])
        #expect(try harness.message(originID: "o2")?.archiveID == "A2")
        // Only the copy the store did not know went to the engine, which knew its key used.
        #expect(await harness.session.omemo.decryptAttempts == attempts + 1)
        #expect(try Self.sessionState(harness, version: .v2) == state)
        #expect(
            try harness.database.omemoPreKeys(accountID: harness.accountID, version: .v2).count
                == preKeys)
        try await harness.barrier()
        #expect(Self.messagesSent(harness) == before)
        await harness.stop()
    }

    @Test func anOldArchivedMessageLeavesTheSessionUnchanged() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        // Legacy OMEMO repairs a session that fails twice in a row: catch-up must not.
        await harness.session.omemo.setForcedVersion(.v03)
        await bob.manager.setForcedVersion(.v03)
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        // Two messages never reach this device live; a third does.
        let lost = [
            try await bob.send("lost one", to: .direct(account), id: "lost-1"),
            try await bob.send("lost two", to: .direct(account), id: "lost-2"),
        ]
        let third = try await bob.send("third", to: .direct(account), id: "m-0")
        try harness.deliver(OMEMOPipelineTests.delivered(third, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "m-0") != nil }
        // Seven round trips: bob's ratchet moves on well past the chains whose keys are kept.
        for round in 1...7 {
            let id = try await harness.session.send(text: "reply \(round)", chatID: chatID)
            let originID = try #require(try harness.database.message(id: id)?.originID)
            let reply = try await OMEMOPipelineTests.sent(originID, by: harness)
            #expect(try await bob.open(reply, from: account).body == "reply \(round)")
            let next = try await bob.send("next \(round)", to: .direct(account), id: "m-\(round)")
            try harness.deliver(OMEMOPipelineTests.delivered(next, from: "\(Self.bob)/phone"))
            try await waitUntil("stored") {
                try harness.message(originID: "m-\(round)")?.body == "next \(round)"
            }
        }
        let state = try Self.sessionState(harness, version: .v03)
        #expect(state.count == 1)
        try await harness.barrier()
        let before = Self.messagesSent(harness)

        entries.set(
            lost.enumerated().map { index, stanza in
                FakeArchive.Entry(
                    id: "L\(index + 1)",
                    message: Self.archived(stanza, from: "\(Self.bob)/phone", to: Self.me),
                    stamp: Date().addingTimeInterval(-600 + Double(index)))
            })
        try await Self.catchUp(harness, through: "L2")

        // Stored as notices, never as the fallback text.
        for id in ["lost-1", "lost-2"] {
            let row = try #require(try harness.message(originID: id))
            #expect(row.body == AccountSession.cannotDecryptText)
            #expect(row.kind == .system)
        }
        // The session is as it was, and nothing was sent: no repair, no heartbeat.
        #expect(try Self.sessionState(harness, version: .v03) == state)
        try await harness.barrier()
        #expect(Self.messagesSent(harness) == before)
        // The live session still reads bob.
        let after = try await bob.send("still here", to: .direct(account), id: "m-8")
        try harness.deliver(OMEMOPipelineTests.delivered(after, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "m-8")?.body == "still here" }
        await harness.stop()
    }

    @Test func ourOwnSentMessagesInTheArchive() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        // The account's other device starts after this one, so it encrypts for it too.
        let phone = try OMEMOParty(Self.alice, pep: pep)
        await phone.start()

        // Sent from the phone; its carbon never reached this Mac.
        let fromPhone = try await phone.send("from my phone", to: .direct(bob.jid), id: "s1")
        // Sent from this Mac, stored here already.
        let id = try await harness.session.send(text: "from this Mac", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let fromHere = try await OMEMOPipelineTests.sent(originID, by: harness)
        let attempts = await harness.session.omemo.decryptAttempts

        entries.set([
            FakeArchive.Entry(
                id: "S1",
                message: Self.archived(fromPhone, from: "\(Self.alice)/phone", to: Self.bob),
                stamp: Date().addingTimeInterval(-60)),
            FakeArchive.Entry(
                id: "S2", message: Self.archived(fromHere, from: Self.me, to: Self.bob),
                stamp: Date().addingTimeInterval(-30)),
        ])
        try await Self.catchUp(harness, through: "S2")

        let phoneRow = try #require(try harness.message(originID: "s1"))
        #expect(phoneRow.body == "from my phone")
        #expect(phoneRow.direction == .outgoing)
        #expect(phoneRow.encryption == .omemo)
        #expect(phoneRow.chatID == chatID)
        // This Mac's own message is a copy of its row: it gets the archive id, nothing more.
        let ownRow = try #require(try harness.database.message(id: id))
        #expect(ownRow.body == "from this Mac")
        #expect(ownRow.archiveID == "S2")
        #expect(await harness.session.omemo.decryptAttempts == attempts + 1)
        #expect(try harness.messages().count == 2)
        await harness.stop()
    }

    // MARK: Guarantees of the review's concern 1

    /// A live message more than the ratchet's skip limit ahead of this device fails, and is
    /// read once catch-up has walked the chain up to it.
    @Test func aLiveMessageFarAheadIsReadAfterCatchUp() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries)
        let account = try JID(Self.alice)
        let start = Date().addingTimeInterval(-3_600)

        // A first message came live and was caught up: the archive is read on from it.
        let opening = try await bob.send("m0", to: .direct(account), id: "f0")
        try harness.deliver(OMEMOPipelineTests.delivered(opening, from: "\(Self.bob)/phone"))
        try await waitUntil("first message") { try harness.message(originID: "f0")?.body == "m0" }
        var archived = [
            FakeArchive.Entry(
                id: "F0", message: Self.archived(opening, from: "\(Self.bob)/phone", to: Self.me),
                stamp: start)
        ]
        try harness.database.recordPage(
            accountID: harness.accountID, archive: Self.alice, after: nil, first: "F0",
            last: "F0", startTime: start, endTime: start)

        // Then the Mac was away while bob wrote 1,500 messages, more than the ratchet skips
        // in one jump; only the last reached it live (the phone had the rest).
        let count = 1_500
        #expect(count > RatchetSession.maxSkippedMessageKeys)
        var last: Element?
        for index in 1...count {
            let message = try await bob.send("m\(index)", to: .direct(account), id: "f\(index)")
            archived.append(
                FakeArchive.Entry(
                    id: "F\(index)",
                    message: Self.archived(message, from: "\(Self.bob)/phone", to: Self.me),
                    stamp: start.addingTimeInterval(Double(index))))
            last = message
        }
        var live = try #require(last)
        live.append(
            Element(
                "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                attributes: ["by": Self.alice, "id": "F\(count)"]))
        try harness.deliver(OMEMOPipelineTests.delivered(live, from: "\(Self.bob)/phone"))
        try await waitUntil("notice") {
            try harness.message(originID: "f\(count)")?.body == AccountSession.cannotDecryptText
        }

        // Catch-up walks the chain page by page up to the live message, which is then read;
        // an archive copy is answered by nothing.
        let sent = Self.messagesSent(harness)
        entries.set(archived)
        try await Self.catchUp(harness, through: "F\(count)", timeout: .seconds(60))
        #expect(try harness.message(originID: "f\(count)")?.body == "m\(count)")
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        // The store hands out at most 1,000 rows a page.
        var rows: [MessageRecord] = []
        var before: (Date, Int64)?
        while true {
            let page = try harness.database.page(chatID: chatID, before: before, limit: 1_000)
            rows = page + rows
            guard page.count == 1_000, let oldest = page.first, let id = oldest.id else { break }
            before = (oldest.timestamp, id)
        }
        #expect(rows.count == count + 1)
        #expect(rows.first { $0.originID == "f1" }?.body == "m1")
        #expect(rows.allSatisfy { $0.encryption == .omemo && $0.kind == .text })
        #expect(Self.messagesSent(harness) == sent)
        await harness.stop()
    }

    /// An old key exchange in the archive never takes the place of the session that read
    /// newer messages from the device.
    @Test func anOldKeyExchangeLeavesTheCurrentSessionInPlace() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        let account = try JID(Self.alice)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let own = try await harness.session.omemo.engine.ensureOwnDevice(version: .v2)

        // K1 reached the phone only; then bob's device lost its session and started K2.
        let first = try await bob.send("from K1", to: .direct(account), id: "k1")
        #expect(
            pep.withdraw(
                preKey: try preKeyUsed(in: first, for: own, version: .v2), of: account,
                deviceID: own, version: .v2))
        try bob.database.deleteOMEMOSession(
            accountID: bob.accountID, jid: Self.alice, version: .v2, deviceID: Int(own))
        let second = try await bob.send("from K2", to: .direct(account), id: "k2")
        try harness.deliver(OMEMOPipelineTests.delivered(second, from: "\(Self.bob)/phone"))
        try await waitUntil("stored") { try harness.message(originID: "k2")?.body == "from K2" }

        entries.set([
            FakeArchive.Entry(
                id: "K1", message: Self.archived(first, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-600))
        ])
        try await Self.catchUp(harness, through: "K1")
        #expect(try harness.message(originID: "k1")?.body == "from K1")

        // This Mac still writes on K2's session, which bob has.
        let id = try await harness.session.send(text: "after catch-up", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let reply = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(try await bob.open(reply, from: account).body == "after catch-up")
        await harness.stop()
    }

    /// The envelope's time is checked against the archive's stamp, not against now.
    @Test func anOMEMO2CopyOlderThanADayIsRead() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let date = ManualDate()
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        date.advance(by: twoDaysAgo.timeIntervalSince(date.now))
        let bob = try OMEMOParty(Self.bob, pep: pep, now: { date.now })
        await bob.start()
        await bob.manager.setForcedVersion(.v2)
        let harness = try await Self.online(pep: pep, entries: entries)
        let sent = try await bob.send(
            "from two days ago", to: .direct(try JID(Self.alice)), id: "d1")
        entries.set([
            FakeArchive.Entry(
                id: "D1", message: Self.archived(sent, from: "\(Self.bob)/phone", to: Self.me),
                stamp: twoDaysAgo)
        ])
        try await Self.catchUp(harness, through: "D1")
        #expect(try harness.message(originID: "d1")?.body == "from two days ago")
        await harness.stop()
    }

    @Test func aClearLinkBesideAnArchivedEncryptedBodyIsNotStored() async throws {
        let pep = FakePEP()
        let entries = Locked<[FakeArchive.Entry]>([])
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await Self.online(pep: pep, entries: entries)
        var sent = try await bob.send("just text", to: .direct(try JID(Self.alice)), id: "l1")
        sent.append(OOB.element(url: try #require(URL(string: "https://evil.example/x.png"))))
        entries.set([
            FakeArchive.Entry(
                id: "L1", message: Self.archived(sent, from: "\(Self.bob)/phone", to: Self.me),
                stamp: Date().addingTimeInterval(-60))
        ])
        try await Self.catchUp(harness, through: "L1")
        let row = try #require(try harness.message(originID: "l1"))
        #expect(row.body == "just text")
        let rowID = try #require(row.id)
        #expect(try harness.database.attachments(messageID: rowID).isEmpty)
        await harness.stop()
    }

    // MARK: Rooms

    @Test func roomArchivesDecryptOnlyWhereOMEMOIsAllowed() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let bob = try OMEMOParty(Self.bob, pep: pep)
        for party in [alice, bob] { await party.start() }
        let room = try JID("room@conference.example.test")
        let open = try JID("open@conference.example.test")
        pep.setMembers([alice.jid, bob.jid], affiliation: .member, of: room)

        let database = try AppDatabase.inMemory()
        let accountID = try #require(
            try database.addAccount(
                AccountRecord(
                    jid: Self.alice, enabled: true, resource: "res", clientID: UUID().uuidString,
                    hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                    pinnedCertSHA256: [], rosterVersion: nil, smResume: nil, createdAt: Date())
            ).id)
        let roomChat = try #require(
            try database.ensureChat(accountID: accountID, jid: room.description, kind: .room).id)
        let openChat = try #require(
            try database.ensureChat(accountID: accountID, jid: open.description, kind: .room).id)
        let fake = FakeArchive(account: alice.jid)
        let manager = alice.manager
        let catchUp = MAMCatchUp(
            accountID: accountID, account: alice.jid, database: database, sender: fake,
            clock: ContinuousClock(),
            realJID: { _, occupantID in occupantID == "occ-bob" ? try? JID(Self.bob) : nil },
            openEncrypted: { [database] in
                await AccountSession.openArchived($0, omemo: manager, database: database)
            })
        fake.setSink { [catchUp] in catchUp.receive($0) }

        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let sent = try await bob.send("room secret", to: .room(omemoRoom, chatID: 1), id: "g1")
        func entry(_ id: String, in room: JID) -> FakeArchive.Entry {
            var message = Self.archived(sent, from: "\(room)/bob", to: Self.alice)
            message[attribute: "to"] = nil
            message.append(
                Element(
                    "occupant-id", namespace: MUCPresence.occupantIDNamespace,
                    attributes: ["id": "occ-bob"]))
            return FakeArchive.Entry(id: id, message: message, stamp: Date())
        }
        fake.set(room.description, [entry("R1", in: room)])
        fake.set(open.description, [entry("R2", in: open)])
        let own = RoomOccupant(jid: try room.withResource("alice"), occupantID: "occ-alice")
        let suitable = RoomTrust(
            stanzaIDs: true, occupantIDs: true, nonAnonymous: true, membersOnly: true)

        await catchUp.roomJoined(
            RoomArchive(
                chatID: roomChat, room: room, ownOccupant: own, trust: suitable, nick: "alice"))
        try await waitUntil("room stored") {
            try database.lastKnownArchiveID(accountID: accountID, archive: room.description) == "R1"
        }
        let readable = try #require(
            try database.page(chatID: roomChat, before: nil, limit: 10).first)
        #expect(readable.body == "room secret")
        #expect(readable.encryption == .omemo)

        // A room anyone may join shows addresses, but OMEMO is not used there: nothing is
        // decrypted, though the sender is known.
        let attempts = await manager.decryptAttempts
        var anyoneMayJoin = suitable
        anyoneMayJoin.membersOnly = false
        await catchUp.roomJoined(
            RoomArchive(
                chatID: openChat, room: open, ownOccupant: own, trust: anyoneMayJoin, nick: "alice")
        )
        try await waitUntil("open room stored") {
            try database.lastKnownArchiveID(accountID: accountID, archive: open.description) == "R2"
        }
        let notice = try #require(try database.page(chatID: openChat, before: nil, limit: 10).first)
        #expect(notice.body == AccountSession.cannotDecryptText)
        #expect(notice.kind == .system)
        #expect(await manager.decryptAttempts == attempts)
        #expect(fake.sent.isEmpty && alice.sender.messages.isEmpty)
    }
}
