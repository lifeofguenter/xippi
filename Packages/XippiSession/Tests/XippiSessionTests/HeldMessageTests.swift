import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Messages written in a chat that waits for its encryption default (R63): nobody has them
/// yet, so an edit or a retraction changes only the row (C3); they never hold up the outbox
/// (I11); the retries end when nothing is left to send (I12); and they go as soon as the chat
/// is settled, whoever settled it (M25).
@Suite struct HeldMessageTests {
    static let bob = OMEMOFixRoundTests.bob
    static let alice = OMEMOFixRoundTests.alice
    static let replace = "urn:xmpp:message-correct:0"

    /// Bob publishes OMEMO, and his server answers for his lists only when the test says so.
    static func slowBob() async throws -> (SessionHarness, OMEMOParty, FakePEP, Locked<[Element]>) {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let held = Locked<[Element]>([])
        let harness = try await OMEMOFixRoundTests.online(
            pep: pep,
            before: { iq in
                guard EncryptionDefaultTests.asksBobsList(iq) else { return nil }
                held.withLock { $0.append(iq) }
                return []
            })
        return (harness, bob, pep, held)
    }

    /// Bob's server fails to answer for his lists while `broken` holds.
    static func brokenBob(
        _ broken: Locked<Bool>, options: SessionServer.Options = SessionServer.Options()
    ) async throws -> (SessionHarness, FakePEP) {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await OMEMOFixRoundTests.online(
            pep: pep, options: options,
            before: { iq in
                guard broken.value, EncryptionDefaultTests.asksBobsList(iq) else { return nil }
                return [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
            })
        return (harness, pep)
    }

    static func answer(_ held: Locked<[Element]>, from pep: FakePEP, _ harness: SessionHarness)
        throws
    {
        let account = try JID(Self.alice)
        let requests = held.withLock { list in
            let taken = list
            list = []
            return taken
        }
        for request in requests {
            let answer = try #require(pep.answer(request, from: account))
            try harness.deliver(answer.xml())
        }
    }

    static func listRequests(_ harness: SessionHarness) -> Int {
        harness.server.stanzas.filter(EncryptionDefaultTests.asksBobsList).count
    }

    // MARK: C3

    @Test func anEditOfAHeldMessageGoesOnceEncryptedWithTheNewText() async throws {
        let (harness, bob, pep, held) = try await Self.slowBob()
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)

        let id = try await harness.session.send(text: "frist words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        // Up, and the typo fixed while the chat still waits.
        try await harness.session.correct(messageID: id, newText: "first words")
        try await harness.barrier()
        #expect(!harness.server.stanzas.contains { $0.xml().contains("words") })
        #expect(try harness.database.message(id: id)?.body == "first words")

        try await waitUntil("lists asked") { held.value.count == 2 }
        try Self.answer(held, from: pep, harness)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        try await harness.barrier()
        #expect(harness.server.messages(id: originID).count == 1)
        #expect(try await bob.open(sent, from: try JID(Self.alice)).body == "first words")
        #expect(
            !harness.server.stanzas.contains { $0.child("replace", namespace: Self.replace) != nil }
        )
        #expect(!harness.server.stanzas.contains { $0.xml().contains("words") })
        await harness.stop()
    }

    @Test func retractingAHeldMessageSendsNothingAndEndsTheRetries() async throws {
        let broken = Locked(true)
        let (harness, _) = try await Self.brokenBob(broken)
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)

        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)
        try await harness.session.retract(messageID: id)
        try await harness.barrier()
        #expect(harness.server.messages(id: originID).isEmpty)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("retract", namespace: ChatMessage.retractionNamespace) != nil
            })
        #expect(await harness.session.defaultRetries[chatID] == nil)
        #expect(await harness.session.heldForDefault[chatID] == nil)

        // Nothing is left to send: the lists are not asked for again.
        let asked = Self.listRequests(harness)
        for _ in 0..<2 {
            await harness.sessionClock.advance(by: AccountSession.defaultRetryInterval)
            try await harness.barrier()
        }
        #expect(Self.listRequests(harness) == asked)
        #expect(harness.server.messages(id: originID).isEmpty)
        await harness.stop()
    }

    // MARK: I11

    @Test func heldRowsNeverHoldUpTheOutbox() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let held = Locked<[Element]>([])
        let harness = try await SessionHarness()
        let account = try JID(Self.alice)
        harness.server.setResponder { iq in
            if EncryptionDefaultTests.asksBobsList(iq) {
                held.withLock { $0.append(iq) }
                return []
            }
            return pep.answer(iq, from: account).map { [$0.xml()] }
        }
        let bobChat = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let carol = try harness.database.ensureChat(
            accountID: harness.accountID, jid: "carol@example.test", kind: .direct)
        let carolChat = try #require(carol.id)
        try harness.database.setEncryptionDefault(chatID: carolChat, omemo: false)

        // Written offline: two to bob, whose lists will take their time, then one to carol.
        let first = try await harness.session.send(text: "one", chatID: bobChat)
        let second = try await harness.session.send(text: "two", chatID: bobChat)
        let toCarol = try await harness.session.send(text: "hi carol", chatID: carolChat)
        let ids = try [first, second, toCarol].map {
            try #require(try harness.database.message(id: $0)?.originID)
        }

        let online = Task { try await harness.goOnline() }
        try await waitUntil("carol's message sent") {
            !harness.server.messages(id: ids[2]).isEmpty
        }
        try await online.value
        await harness.session.omemo.settled()
        // One lookup for bob's chat, not one per message: one request per list.
        try await waitUntil("lists asked") { held.value.count == 2 }
        try await harness.barrier()
        #expect(held.value.count == 2)
        #expect(harness.server.messages(id: ids[0]).isEmpty)

        try Self.answer(held, from: pep, harness)
        try await waitUntil("bob's messages sent") {
            !harness.server.messages(id: ids[1]).isEmpty
        }
        let order = harness.server.stanzas.compactMap { stanza in
            stanza.name == "message" ? ids.firstIndex(of: stanza.id ?? "") : nil
        }
        #expect(order == [2, 0, 1])
        let two = try #require(harness.server.messages(id: ids[1]).first)
        #expect(try await bob.open(two, from: account).body == "two")
        await harness.stop()
    }

    // MARK: M25

    @Test func heldRowsGoAsSoonAsTheUserChooses() async throws {
        let broken = Locked(true)
        let (harness, _) = try await Self.brokenBob(broken)
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let id = try await harness.session.send(text: "sealed, by choice", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await waitUntil("a later try planned") {
            await harness.session.defaultRetries[chatID] != nil
        }

        // Bob's server recovers, and the user turns encryption on in the inspector: the
        // message goes now, not on the next try (the session clock does not move).
        broken.set(false)
        try harness.database.updateChat(id: chatID) { $0.encryption = .omemo }
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(ChatMessage(element: sent)?.encrypted != nil)
        #expect(!sent.xml().contains("by choice"))
        await harness.stop()
    }

    // MARK: I13: no work while nothing can be sent

    /// How often held rows were looked at, after `wait` of real time.
    static func runs(after wait: Duration, _ harness: SessionHarness) async throws -> Int {
        try await Task.sleep(for: wait)
        return await harness.session.heldDeliveryRuns
    }

    @Test func aChatSettledWhileOfflineWaitsForTheNextSessionWithoutSpinning() async throws {
        let broken = Locked(true)
        // No stream management: a lost stream ends the session, and the connection's clock
        // never moves, so it stays offline until the test lets it back.
        let (harness, _) = try await Self.brokenBob(broken, options: .init(sm: false))
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)

        try harness.latestTransport.simulateEOF()
        try await waitUntil("offline") { await harness.session.progress.ended == 1 }
        // The user chooses while offline: the row waits for the next session, with no timer
        // and no loop.
        try harness.database.chooseEncryption(chatID: chatID, .omemo)
        let before = try await Self.runs(after: .milliseconds(300), harness)
        let after = try await Self.runs(after: .milliseconds(300), harness)
        #expect(after == before)
        #expect(before <= 3)
        #expect(await harness.session.defaultRetries[chatID] == nil)
        #expect(await harness.session.defaultDeliveries[chatID] == nil)

        // Back online: the fresh session's flush sends it, once, sealed.
        broken.set(false)
        await harness.clock.advance(by: .seconds(120))
        try await waitUntil("a fresh session") { await harness.session.progress.started == 2 }
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(ChatMessage(element: sent)?.encrypted != nil)
        #expect(!sent.xml().contains("first words"))
        await harness.stop()
        #expect(harness.server.messages(id: originID).count == 1)
    }

    @Test func stopEndsTheHeldWork() async throws {
        let broken = Locked(true)
        let (harness, _) = try await Self.brokenBob(broken)
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        _ = try await harness.session.send(text: "first words", chatID: chatID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)

        await harness.stop()
        #expect(await harness.session.defaultRetries.isEmpty)
        #expect(await harness.session.defaultDeliveries.isEmpty)
        let before = await harness.session.heldDeliveryRuns
        try harness.database.chooseEncryption(chatID: chatID, .omemo)
        await harness.sessionClock.advance(by: AccountSession.defaultRetryInterval)
        #expect(try await Self.runs(after: .milliseconds(300), harness) == before)
    }

    // MARK: I14: a resumed stream wakes the held rows

    @Test func aLookupThatFailedWhileCutGoesWhenTheStreamResumes() async throws {
        let broken = Locked(true)
        let (harness, _) = try await Self.brokenBob(broken)
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let id = try await harness.session.send(text: "first words", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)

        // The stream is cut and comes back resumed; bob's server recovers meanwhile. The
        // session clock does not move: the row goes because of the resume, not a timer.
        broken.set(false)
        try await harness.drop()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(ChatMessage(element: sent)?.encrypted != nil)
        #expect(!sent.xml().contains("first words"))
        try await harness.barrier()
        #expect(harness.server.messages(id: originID).count == 1)
        await harness.stop()
    }

    @Test func aSendLostInTheSleepCloseGoesWhenTheStreamResumes() async throws {
        let broken = Locked(true)
        // The server does not answer the close: the session waits to be resumed.
        let (harness, _) = try await Self.brokenBob(broken, options: .init(confirmsClose: false))
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let id = try await harness.session.send(text: "plain by choice", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)

        // The Mac starts to sleep; while the stream closes, the user chooses Off and the held
        // row's send is lost with the closing stream.
        let sleeping = Task { await harness.session.willSleep() }
        // The close waits (up to 2 s, on the connection's clock) for an answer that never
        // comes.
        try await waitUntil("closing") { harness.server.closes == 1 }
        let runs = await harness.session.heldDeliveryRuns
        try harness.database.chooseEncryption(chatID: chatID, .none)
        // The woken delivery has run, and its send was lost with the closing stream.
        try await waitUntil("the send lost") {
            let ran = await harness.session.heldDeliveryRuns > runs
            let held = await harness.session.heldForDefault[chatID]
            let running = await harness.session.defaultDeliveries[chatID]
            return ran && held == [id] && running == nil
        }
        #expect(harness.server.messages(id: originID).isEmpty)
        // The close's grace runs out unanswered: the session waits to be resumed.
        let grace = harness.clock.now.advanced(by: .seconds(2))
        try await waitUntil("close timed") {
            harness.clock.nextDeadline.map { $0 <= grace } ?? false
        }
        await harness.clock.advance(by: .seconds(3))
        await sleeping.value

        // The Mac wakes: the connection comes back at once and resumes, and the row goes.
        await harness.session.didWake()
        let went =
            (try? await waitUntil("sent after the resume") {
                await harness.session.progress.resumed == 1
                    && !harness.server.messages(id: originID).isEmpty
            }) != nil
        #expect(went)
        #expect(
            harness.server.messages(id: originID).first?.child("body")?.text == "plain by choice")
        try? await harness.barrier()
        #expect(harness.server.messages(id: originID).count == 1)
        let carriers = harness.server.received.filter { $0.element.id == originID }
        #expect(carriers.map(\.connection) == [1], "on the resumed connection, once")
        // The server answers closes again, so the stop's own close ends.
        harness.server.update { $0.confirmsClose = true }
        await harness.stop()
    }

    // MARK: M31: the user's explicit choice

    @Test func choosingOffSendsTheWaitingMessagesInTheClear() async throws {
        let broken = Locked(true)
        let (harness, _) = try await Self.brokenBob(broken)
        let chatID = try EncryptionDefaultTests.newChat(Self.bob, harness)
        let id = try await harness.session.send(text: "plain by choice", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await EncryptionDefaultTests.waitForRetry(chatID, harness)
        #expect(try harness.database.pendingOutgoingCount(chatID: chatID) == 1)

        // Off, chosen while it is already off: still the user's choice.
        try harness.database.chooseEncryption(chatID: chatID, .none)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(sent.child("body")?.text == "plain by choice")
        #expect(try !harness.database.awaitsEncryptionDefault(chatID: chatID))
        await harness.stop()
    }

    // MARK: M29

    @Test func aFileRefusedForAnUnknownEncryptionSaysWhy() async throws {
        let (media, environment) = try SessionFilesTests.mediaRig()
        defer { media.cleanUp() }
        let harness = try await SessionHarness(media: environment) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        harness.server.setResponder { iq in
            if EncryptionDefaultTests.asksBobsList(iq) {
                return [SessionServer.error(iq, condition: "forbidden")]
            }
            return SessionFilesTests.uploadResponder(iq)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("hello".utf8))

        await #expect(throws: SessionError.encryption(.unreachable(try JID(Self.bob)))) {
            try await harness.session.sendFile(url: file, chatID: chatID)
        }
        #expect(media.transport.uploads.isEmpty)
        await harness.stop()
    }
}

/// Security review: a file for a contact's device goes over Jingle only once the chat's
/// encryption default is known to be the clear; OMEMO means the encrypted upload, and a
/// default that cannot be decided means nothing goes.
@Suite struct JingleRouteTests {
    static let bob = OMEMOFixRoundTests.bob

    /// Media services, bob's lists answered by `lists` (else by the PEP), uploads served.
    static func harness(
        _ pep: FakePEP, lists: (@Sendable (Element) -> [String]?)? = nil
    ) async throws -> (MediaRig, SessionHarness) {
        let (media, _) = try SessionFilesTests.mediaRig()
        let environment = MediaEnvironment(
            directory: media.library.directory, transport: media.transport,
            bytestreams: FakeBytestreamNetwork())
        let harness = try await SessionHarness(media: environment)
        let account = try JID(SessionServer.account)
        harness.server.setResponder { iq in
            if EncryptionDefaultTests.asksBobsList(iq), let answer = lists?(iq) { return answer }
            return SessionFilesTests.uploadResponder(iq)
                ?? pep.answer(iq, from: account).map { [$0.xml()] }
        }
        try await harness.goOnline()
        await harness.session.omemo.settled()
        return (media, harness)
    }

    static func jingle(_ harness: SessionHarness) -> Bool {
        harness.server.stanzas.contains {
            $0.child("jingle", namespace: "urn:xmpp:jingle:1") != nil
        }
    }

    @Test func aFileForAnOMEMOContactWithoutAChatIsUploadedEncrypted() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let (media, harness) = try await Self.harness(pep)
        defer { media.cleanUp() }
        #expect(try harness.chat(Self.bob) == nil)
        let file = try media.file("notes.txt", Data("secret".utf8))

        let sent = try await harness.session.sendFile(url: file, to: try JID("\(Self.bob)/phone"))
        guard case .message(let id) = sent else {
            Issue.record("offered over Jingle")
            await harness.stop()
            return
        }
        #expect(try harness.database.message(id: id)?.encryption == .omemo)
        #expect(media.transport.uploads.first?.body.count == 6 + 16)
        #expect(!Self.jingle(harness))
        #expect(try harness.chat(Self.bob)?.encryption == .omemo)
        await harness.stop()
    }

    @Test func aFileForAContactWhoseListsCannotBeReadIsRefused() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let (media, harness) = try await Self.harness(pep) { iq in
            [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
        }
        defer { media.cleanUp() }
        let file = try media.file("notes.txt", Data("secret".utf8))

        await #expect(throws: SessionError.encryption(.unreachable(try JID(Self.bob)))) {
            try await harness.session.sendFile(url: file, to: try JID("\(Self.bob)/phone"))
        }
        #expect(!Self.jingle(harness))
        #expect(media.transport.uploads.isEmpty)
        await harness.stop()
    }
}

/// I15: a file for a room occupant names one person: it never goes over Jingle in the
/// clear, and never to the whole room either. It is refused.
@Suite struct RoomFileRouteTests {
    @Test func aFileForARoomOccupantIsRefused() async throws {
        let (media, environment) = try SessionFilesTests.mediaRig()
        defer { media.cleanUp() }
        let room = "room@conference.example.test"
        let harness = try await SessionHarness(media: environment) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: room, kind: .room)
        }
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(
                state: .joined, own: RoomOccupant(jid: try JID("\(room)/alice"), occupantID: nil)))
        harness.server.setResponder(SessionFilesTests.uploadResponder)
        try await harness.goOnline()
        let roomChat = try #require(try harness.chat(room)?.id)
        let file = try media.file("notes.txt", Data("x".utf8))

        await #expect(throws: SessionError.notAllowed) {
            try await harness.session.sendFile(url: file, to: try JID("\(room)/bob"))
        }
        #expect(media.transport.uploads.isEmpty)
        #expect(!JingleRouteTests.jingle(harness))
        #expect(try harness.database.page(chatID: roomChat, before: nil, limit: 5).isEmpty)
        await harness.stop()
    }
}

/// M27: joining a channel writes only what it sets, after the join as before it.
@Suite struct ChannelJoinWriteTests {
    @Test func aDraftWrittenDuringTheJoinIsKept() async throws {
        let harness = try await SessionHarness()
        let joins = Locked<[Element]>([])
        harness.server.setResponder { iq in
            guard iq.child("client-join", namespace: MIX.pamNamespace) != nil else { return nil }
            joins.withLock { $0.append(iq) }
            return []
        }
        try await harness.goOnline()
        let channel = try JID("coffee@mix.example.test")

        let joining = Task { try await harness.session.joinChannel(jid: channel, nick: "alice") }
        try await waitUntil("join asked") { joins.value.count == 1 }
        let chatID = try #require(try harness.chat(channel.description)?.id)
        try harness.database.updateChat(id: chatID) { $0.draft = "while joining" }
        let request = try #require(joins.value.first)
        try harness.deliver(
            "<iq type='result' id='\(request.id ?? "")' to='\(SessionServer.fullJID)'>"
                + "<client-join xmlns='\(MIX.pamNamespace)'><join xmlns='\(MIX.coreNamespace)'"
                + " id='p1'><nick>alice</nick></join></client-join></iq>")
        _ = try await joining.value

        let chat = try #require(try harness.database.chat(id: chatID))
        #expect(chat.draft == "while joining")
        #expect(chat.nick == "alice")
        #expect(chat.autojoin)
        await harness.stop()
    }
}
