import AppKit
import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiCalls
import XippiStore

@testable import XippiSession

@Suite struct AccountSessionTests {
    static let bob = "bob@example.test"
    static let bobPhone = "bob@example.test/phone"
    static let me = SessionServer.fullJID

    static func rosterItem(_ jid: String, _ subscription: String) -> String {
        "<item jid='\(jid)' subscription='\(subscription)'/>"
    }

    static func chat(_ from: String, id: String, body: String, extra: String = "") -> String {
        "<message from='\(from)' to='\(me)' type='chat' id='\(id)'><body>\(body)</body>\(extra)"
            + "</message>"
    }

    static let receiptRequest = "<request xmlns='urn:xmpp:receipts'/>"

    // MARK: Incoming messages

    @Test func incomingMessagePersistsAndNotifies() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()

        try harness.deliver(
            Self.chat(
                Self.bobPhone, id: "m1", body: "Hello",
                extra: "<stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.test' id='arch-1'/>"
                    + "<origin-id xmlns='urn:xmpp:sid:0' id='o1'/>"))

        try await waitUntil("stored") { try harness.messages().count == 1 }
        let message = try #require(try harness.messages().first)
        let chat = try #require(try harness.chat(Self.bob))
        #expect(chat.kind == .direct)
        #expect(message.chatID == chat.id)
        #expect(message.body == "Hello")
        #expect(message.direction == .incoming)
        #expect(message.senderJID == Self.bobPhone)
        #expect(message.archiveID == "arch-1")
        #expect(message.originID == "o1")
        #expect(message.stanzaMessageID == "m1")
        try await waitUntil("notified") { harness.notifications.messages.count == 1 }
        let notified = try #require(harness.notifications.messages.first)
        #expect(notified.message.id == message.id)
        #expect(notified.chat.id == chat.id)

        // Offline delivery keeps the server's stamp; a stanza-id the sender wrote is no
        // archive id.
        try harness.deliver(
            Self.chat(
                Self.bobPhone, id: "m2", body: "Earlier",
                extra: "<delay xmlns='urn:xmpp:delay' from='example.test'"
                    + " stamp='2026-11-18T10:00:00Z'/>"
                    + "<stanza-id xmlns='urn:xmpp:sid:0' by='bob@example.test' id='forged'/>"))
        try await waitUntil("second stored") { try harness.messages().count == 2 }
        let earlier = try #require(try harness.messages().first { $0.stanzaMessageID == "m2" })
        #expect(earlier.timestamp == (try #require(XMPPDateTime.parse("2026-11-18T10:00:00Z"))))
        #expect(earlier.archiveID == nil)
        await harness.stop()
    }

    @Test func receiptSentOnlyToRosterContacts() async throws {
        let options = SessionServer.Options(
            roster: .items(
                [
                    Self.rosterItem(Self.bob, "both"),
                    Self.rosterItem("carol@example.test", "to"),
                    Self.rosterItem("dave@example.test", "from"),
                ], version: "v1"))
        let harness = try await SessionHarness(options: options)
        try await harness.goOnline()

        try harness.deliver(
            Self.chat(Self.bobPhone, id: "r1", body: "1", extra: Self.receiptRequest))
        try harness.deliver(
            Self.chat("carol@example.test/x", id: "r2", body: "2", extra: Self.receiptRequest))
        try harness.deliver(
            Self.chat("mallory@evil.test/x", id: "r3", body: "3", extra: Self.receiptRequest))
        try harness.deliver(
            Self.chat("dave@example.test/x", id: "r4", body: "4", extra: Self.receiptRequest))
        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(Self.me)' type='error' id='r5'>"
                + "<body>5</body>\(Self.receiptRequest)<error type='cancel'>"
                + "<service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>"
                + "</message>")
        try await harness.barrier()

        let receipts = harness.server.stanzas.compactMap { stanza -> (String?, String?)? in
            guard stanza.name == "message",
                let received = stanza.child("received", namespace: "urn:xmpp:receipts")
            else { return nil }
            return (stanza[attribute: "to"], received[attribute: "id"])
        }
        #expect(receipts.map(\.1) == ["r1", "r4"])
        #expect(receipts.first?.0 == Self.bobPhone)
        #expect(try harness.messages().count == 4, "the error bounce is no message")
        await harness.stop()
    }

    @Test func carbonSentMessageStoredOutgoing() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()

        try harness.deliver(
            "<message from='alice@example.test' to='\(Self.me)' type='chat'>"
                + "<sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
                + "<message xmlns='jabber:client' from='alice@example.test/phone'"
                + " to='bob@example.test' type='chat' id='c1'><body>From my phone</body>"
                + "<origin-id xmlns='urn:xmpp:sid:0' id='c1'/></message></forwarded></sent>"
                + "</message>")

        try await waitUntil("stored") { try harness.messages().count == 1 }
        let message = try #require(try harness.messages().first)
        let chat = try #require(try harness.chat(Self.bob))
        #expect(message.chatID == chat.id)
        #expect(message.direction == .outgoing)
        #expect(message.state == .sent)
        #expect(message.body == "From my phone")
        try await harness.barrier()
        #expect(harness.notifications.messages.isEmpty)

        // A received carbon is a message to us, and is announced.
        try harness.deliver(
            "<message from='alice@example.test' to='\(Self.me)' type='chat'>"
                + "<received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
                + "<message xmlns='jabber:client' from='bob@example.test/phone'"
                + " to='alice@example.test/phone' type='chat' id='c2'><body>Answer</body>"
                + "</message></forwarded></received></message>")
        try await waitUntil("received carbon stored") { try harness.messages().count == 2 }
        let answer = try #require(try harness.messages().first { $0.stanzaMessageID == "c2" })
        #expect(answer.direction == .incoming)
        try await waitUntil("notified") { harness.notifications.messages.count == 1 }
        await harness.stop()
    }

    @Test func spoofedCarbonIgnored() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()

        for from in ["mallory@evil.test/x", "alice@example.test/other", "bob@example.test"] {
            try harness.deliver(
                "<message from='\(from)' to='\(Self.me)' type='chat' id='outer'>"
                    + "<body>outer</body>"
                    + "<received xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>"
                    + "<message xmlns='jabber:client' from='bob@example.test/phone'"
                    + " to='alice@example.test/phone' type='chat' id='inner'><body>forged</body>"
                    + "</message></forwarded></received></message>")
        }
        try await harness.barrier()

        #expect(try harness.messages().isEmpty)
        #expect(try harness.chat(Self.bob) == nil)
        #expect(harness.notifications.messages.isEmpty)
        await harness.stop()
    }

    // MARK: Outgoing messages

    @Test func outboxResentOnFreshSessionOnly() async throws {
        let harness = try await SessionHarness { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: try #require(chat.id), originID: "pending-1",
                    senderJID: SessionServer.account, body: "Queued", timestamp: Date()))
        }
        try await harness.goOnline()
        try await waitUntil("pending-1 sent") {
            harness.server.messages(id: "pending-1").count == 1
        }
        let sent = try #require(harness.server.messages(id: "pending-1").first)
        #expect(sent[attribute: "to"] == Self.bob)
        #expect(sent.child("body")?.text == "Queued")
        #expect(
            sent.child("origin-id", namespace: "urn:xmpp:sid:0")?[attribute: "id"] == "pending-1")

        // Stored but never handed to the connection: waits for a fresh session.
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "pending-2",
                senderJID: SessionServer.account, body: "Later", timestamp: Date()))

        try await harness.drop()
        try await waitUntil("resumed") { await harness.session.progress.resumed == 1 }
        try await harness.barrier()
        #expect(harness.server.messages(id: "pending-1").count == 1)
        #expect(harness.server.messages(id: "pending-2").isEmpty)
        #expect(try harness.message(originID: "pending-1")?.state == .sent)

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("a fresh session") { await harness.session.progress.started == 2 }
        try await waitUntil("pending-2 sent") {
            harness.server.messages(id: "pending-2").count == 1
        }
        try await harness.barrier()
        #expect(harness.server.messages(id: "pending-1").count == 1)
        #expect(harness.server.messages(id: "pending-2").count == 1)
        await harness.stop()
    }

    @Test func acknowledgedMarksSentAndBounceMarksFailed() async throws {
        let harness = try await SessionHarness(options: .init(answersAckRequests: true)) {
            database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        let messageID = try await harness.session.send(text: "Hi", chatID: chatID)

        try await waitUntil("sent") { try harness.database.message(id: messageID)?.state == .sent }
        let stored = try #require(try harness.database.message(id: messageID))
        let originID = try #require(stored.originID)
        let wire = try #require(harness.server.messages(id: originID).first)
        #expect(wire[attribute: "to"] == Self.bob)
        #expect(wire.type == "chat")
        #expect(wire.child("body")?.text == "Hi")

        try harness.deliver(
            "<message from='bob@example.test' to='\(Self.me)' type='error' id='\(originID)'>"
                + "<body>Hi</body><error type='cancel'><service-unavailable"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/><text"
                + " xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Gone fishing</text></error></message>"
        )
        try await waitUntil("failed") {
            try harness.database.message(id: messageID)?.state == .failed
        }
        #expect(try harness.database.message(id: messageID)?.errorText == "Gone fishing")
        await harness.stop()
    }

    // MARK: Roster

    @Test func rosterVersioningUsesStoredVersion() async throws {
        let harness = try await SessionHarness(options: .init(roster: .unchanged)) {
            database, accountID in
            try database.replaceRoster(
                accountID: accountID,
                with: [
                    RosterItem(jid: try JID(Self.bob), subscription: .both).record(
                        accountID: accountID)
                ], version: "v7")
        }
        try await harness.goOnline()

        let get = try #require(
            harness.server.stanzas.first {
                $0.name == "iq" && $0.type == "get"
                    && $0.child("query", namespace: "jabber:iq:roster") != nil
            })
        #expect(get.child("query", namespace: "jabber:iq:roster")?[attribute: "ver"] == "v7")
        #expect(
            try harness.database.rosterItems(accountID: harness.accountID).map(\.jid) == [Self.bob])

        try harness.deliver(
            "<iq type='set' id='push-1'><query xmlns='jabber:iq:roster' ver='v8'>"
                + "<item jid='carol@example.test' name='Carol' subscription='none' ask='subscribe'/>"
                + "</query></iq>")
        try harness.deliver(
            "<iq type='set' id='push-2' from='mallory@evil.test/x'><query xmlns='jabber:iq:roster'"
                + " ver='v666'><item jid='mallory@evil.test' subscription='both'/></query></iq>")
        try await harness.barrier()

        let answers = harness.server.stanzas.filter { $0.name == "iq" }
        #expect(answers.first { $0.id == "push-1" }?.type == "result")
        #expect(answers.first { $0.id == "push-2" }?.type == "error")
        let items = try harness.database.rosterItems(accountID: harness.accountID)
        #expect(Set(items.map(\.jid)) == [Self.bob, "carol@example.test"])
        #expect(items.first { $0.jid == "carol@example.test" }?.ask == "subscribe")
        #expect(try harness.database.account(id: harness.accountID)?.rosterVersion == "v8")
        await harness.stop()
    }

    @Test func fullRosterReplacesStoredItems() async throws {
        let options = SessionServer.Options(
            roster: .items([Self.rosterItem("carol@example.test", "both")], version: "v9"))
        let harness = try await SessionHarness(options: options) { database, accountID in
            try database.replaceRoster(
                accountID: accountID,
                with: [
                    RosterItem(jid: try JID(Self.bob), subscription: .both).record(
                        accountID: accountID)
                ], version: "v7")
        }
        try await harness.goOnline()

        #expect(
            try harness.database.rosterItems(accountID: harness.accountID).map(\.jid) == [
                "carol@example.test"
            ])
        #expect(try harness.database.account(id: harness.accountID)?.rosterVersion == "v9")
        await harness.stop()
    }

    @Test func rosterWithoutVersioningSendsNoVersion() async throws {
        let harness = try await SessionHarness(options: .init(rosterVersioning: false)) {
            database, accountID in
            try database.replaceRoster(accountID: accountID, with: [], version: "v7")
        }
        try await harness.goOnline()

        let get = try #require(
            harness.server.stanzas.first { $0.child("query", namespace: "jabber:iq:roster") != nil }
        )
        #expect(get.child("query", namespace: "jabber:iq:roster")?[attribute: "ver"] == nil)
        await harness.stop()
    }

    // MARK: Routing

    @Test func unknownIQOnTheWireIsAnsweredServiceUnavailable() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()

        try harness.deliver(
            "<iq type='get' id='u1' from='bob@example.test/phone' to='\(Self.me)'>"
                + "<query xmlns='urn:example:unknown'/></iq>")
        try harness.deliver(
            "<iq type='get' id='v1' from='bob@example.test/phone' to='\(Self.me)'>"
                + "<query xmlns='jabber:iq:version'/></iq>")
        try harness.deliver(
            "<iq type='get' id='d1' from='bob@example.test/phone' to='\(Self.me)'>"
                + "<query xmlns='http://jabber.org/protocol/disco#info'/></iq>")
        try harness.deliver(
            "<iq type='result' id='x1' from='bob@example.test/phone' to='\(Self.me)'/>")
        try await harness.barrier()

        let answers = harness.server.stanzas.filter { $0.name == "iq" }
        let unknown = try #require(answers.first { $0.id == "u1" })
        #expect(unknown.type == "error")
        #expect(
            unknown.child("error")?.child(
                "service-unavailable", namespace: "urn:ietf:params:xml:ns:xmpp-stanzas") != nil)
        #expect(answers.first { $0.id == "v1" }?.type == "result")
        let disco = try #require(answers.first { $0.id == "d1" })
        #expect(disco.type == "result")
        let features = disco.child("query")?.children("feature").compactMap { $0[attribute: "var"] }
        #expect(features?.contains("urn:xmpp:receipts") == true)
        #expect(!answers.contains { $0.id == "x1" })
        await harness.stop()
    }

    // MARK: Presence and the status board

    @Test func presenceAnnouncedWithCapsAndTracked() async throws {
        let harness = try await SessionHarness(
            options: .init(roster: .items([Self.rosterItem(Self.bob, "both")], version: "v1")))
        try await harness.goOnline()

        func isInitial(_ stanza: Element) -> Bool {
            stanza.name == "presence" && stanza[attribute: "to"] == nil
        }
        try await waitUntil("initial presence") {
            harness.server.stanzas.contains(where: isInitial)
        }
        let initial = try #require(harness.server.stanzas.first(where: isInitial))
        let caps = try #require(initial.child("c", namespace: "http://jabber.org/protocol/caps"))
        #expect(caps[attribute: "node"] == XippiClient.node)
        #expect(caps[attribute: "ver"] == Caps.verificationString(XippiClient.discoInfo))

        try harness.deliver(
            "<presence from='bob@example.test/phone' to='\(Self.me)'><show>away</show>"
                + "<status>Lunch</status></presence>")
        try await harness.barrier()
        await harness.publisher.flush()
        let key = PresenceKey(accountID: harness.accountID, jid: Self.bob)
        let summary = await MainActor.run { harness.board.presence[key] }
        #expect(summary?.availability == .away)
        #expect(summary?.status == "Lunch")
        let state = await MainActor.run { harness.board.connection[harness.accountID] }
        #expect(state == .online(resumed: false))

        try harness.deliver(
            "<presence from='bob@example.test/phone' to='\(Self.me)' type='unavailable'/>")
        try await harness.barrier()
        await harness.publisher.flush()
        #expect(await MainActor.run { harness.board.presence[key] } == nil)
        await harness.stop()
    }

    @Test func chatStatesShowTyping() async throws {
        let harness = try await SessionHarness(
            options: .init(roster: .items([Self.rosterItem(Self.bob, "both")], version: "v1"))
        ) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        try harness.deliver(
            "<message from='bob@example.test/phone' to='\(Self.me)' type='chat' id='t1'>"
                + "<composing xmlns='http://jabber.org/protocol/chatstates'/></message>")
        try await harness.barrier()
        await harness.publisher.flush()
        #expect(await MainActor.run { harness.board.typing[chatID] } == [Self.bob])
        #expect(try harness.messages().isEmpty)

        try harness.deliver(
            Self.chat(
                Self.bobPhone, id: "t2", body: "Done",
                extra: "<active xmlns='http://jabber.org/protocol/chatstates'/>"))
        try await harness.barrier()
        await harness.publisher.flush()
        #expect(await MainActor.run { harness.board.typing[chatID] ?? [] }.isEmpty)
        await harness.stop()
    }

    @Test func typingEndsAfter30sWithoutANewState() async throws {
        let harness = try await SessionHarness(
            options: .init(roster: .items([Self.rosterItem(Self.bob, "both")], version: "v1"))
        ) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let composing =
            "<message from='bob@example.test/phone' to='\(Self.me)' type='chat' id='t3'>"
            + "<composing xmlns='http://jabber.org/protocol/chatstates'/></message>"

        try harness.deliver(composing)
        try await harness.barrier()
        try await waitUntil("timer armed") { harness.sessionClock.sleeperCount == 1 }
        await harness.sessionClock.advance(by: .seconds(20))
        // A new state starts the 30 s again.
        try harness.deliver(composing)
        try await harness.barrier()
        try await waitUntil("timer armed again") {
            harness.sessionClock.sleeperCount == 1 && harness.sessionClock.completedSleeps == 0
        }
        await harness.sessionClock.advance(by: .seconds(29))
        await harness.publisher.flush()
        #expect(await MainActor.run { harness.board.typing[chatID] } == [Self.bob])

        await harness.sessionClock.advance(by: .seconds(1))
        try await waitUntil("no longer typing") {
            await harness.publisher.flush()
            return await MainActor.run { harness.board.typing[chatID] } == nil
        }
        await harness.stop()
    }

    // MARK: Displayed markers and MDS (XEP-0333, XEP-0490)

    static func markableFromBob(id: String, archiveID: String) -> String {
        chat(
            bobPhone, id: id, body: "Read me",
            extra: "<markable xmlns='urn:xmpp:chat-markers:0'/>"
                + "<stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.test' id='\(archiveID)'/>")
    }

    static func mdsPublishes(_ server: SessionServer) -> [Element] {
        server.stanzas.compactMap { stanza in
            stanza.child("pubsub", namespace: "http://jabber.org/protocol/pubsub")?
                .child("publish", namespace: "http://jabber.org/protocol/pubsub")
        }.filter { $0[attribute: "node"] == "urn:xmpp:mds:displayed:0" }
    }

    @Test func markDisplayedSendsMarkerAndPublishesMDS() async throws {
        let harness = try await SessionHarness(
            options: .init(roster: .items([Self.rosterItem(Self.bob, "both")], version: "v1")))
        try await harness.goOnline()
        try harness.deliver(Self.markableFromBob(id: "m7", archiveID: "arch-7"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let chat = try #require(try harness.chat(Self.bob))
        let chatID = try #require(chat.id)
        #expect(chat.unreadCount == 1)

        try await harness.session.markDisplayed(chatID: chatID)

        try await waitUntil("marker sent") {
            harness.server.stanzas.contains {
                $0.child("displayed", namespace: "urn:xmpp:chat-markers:0")?[attribute: "id"]
                    == "m7"
            }
        }
        try await waitUntil("MDS published") { !Self.mdsPublishes(harness.server).isEmpty }
        let publish = try #require(Self.mdsPublishes(harness.server).first)
        let item = try #require(
            publish.child("item", namespace: "http://jabber.org/protocol/pubsub"))
        #expect(item[attribute: "id"] == Self.bob)
        let stanzaID = item.child("displayed", namespace: "urn:xmpp:mds:displayed:0")?
            .child("stanza-id", namespace: "urn:xmpp:sid:0")
        #expect(stanzaID?[attribute: "id"] == "arch-7")
        #expect(stanzaID?[attribute: "by"] == SessionServer.account)
        let read = try #require(try harness.chat(Self.bob))
        #expect(read.unreadCount == 0)
        #expect(read.lastReadMessageID == (try harness.messages().first?.id))
        await harness.stop()
    }

    @Test func noMDSWithoutPublishOptionsAndNoMarkerToStrangers() async throws {
        let harness = try await SessionHarness(
            options: .init(accountFeatures: ["urn:xmpp:sid:0"], roster: .items([], version: "v1")))
        try await harness.goOnline()
        try harness.deliver(Self.markableFromBob(id: "m8", archiveID: "arch-8"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        try await harness.session.markDisplayed(chatID: chatID)
        try await harness.barrier()

        #expect(try harness.chat(Self.bob)?.unreadCount == 0)
        #expect(Self.mdsPublishes(harness.server).isEmpty)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("displayed", namespace: "urn:xmpp:chat-markers:0") != nil
            })
        await harness.stop()
    }

    @Test func mdsEventMarksTheChatRead() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        try harness.deliver(Self.markableFromBob(id: "m9", archiveID: "arch-9"))
        try await waitUntil("stored") { try harness.messages().count == 1 }
        #expect(try harness.chat(Self.bob)?.unreadCount == 1)

        func event(from: String) -> String {
            "<message from='\(from)' to='\(Self.me)' type='headline'>"
                + "<event xmlns='http://jabber.org/protocol/pubsub#event'>"
                + "<items node='urn:xmpp:mds:displayed:0'><item id='bob@example.test'>"
                + "<displayed xmlns='urn:xmpp:mds:displayed:0'><stanza-id xmlns='urn:xmpp:sid:0'"
                + " by='alice@example.test' id='arch-9'/></displayed></item></items></event>"
                + "</message>"
        }
        try harness.deliver(event(from: "bob@example.test"))
        try await harness.barrier()
        #expect(try harness.chat(Self.bob)?.unreadCount == 1, "only the account's own node counts")

        try harness.deliver(event(from: SessionServer.account))
        try await waitUntil("read") { try harness.chat(Self.bob)?.unreadCount == 0 }
        #expect(try harness.chat(Self.bob)?.lastReadMessageID == (try harness.messages().first?.id))
        await harness.stop()
    }

    // MARK: Calls (ruling R32)

    static func propose(from: String, sid: String) -> String {
        "<message from='\(from)' to='\(me)' type='chat' id='p-\(sid)'>"
            + "<propose xmlns='urn:xmpp:jingle-message:0' id='\(sid)'>"
            + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/></propose>"
            + "<store xmlns='urn:xmpp:hints'/></message>"
    }

    @Test func onlyContactsWithSubscriptionCanRing() async throws {
        let harness = try await SessionHarness(
            options: .init(
                roster: .items(
                    [
                        Self.rosterItem(Self.bob, "both"),
                        Self.rosterItem("carol@example.test", "to"),
                    ],
                    version: "v1")),
            calls: CallServices(engineFactory: { InertMediaEngine() }))
        try await harness.goOnline()

        try harness.deliver(Self.propose(from: "mallory@evil.test/x", sid: "s1"))
        try harness.deliver(Self.propose(from: "carol@example.test/x", sid: "s2"))
        try await harness.barrier()
        #expect(harness.notifications.calls.isEmpty)
        let jmi = harness.server.stanzas.filter {
            $0.elements.contains { $0.namespace == "urn:xmpp:jingle-message:0" }
        }
        #expect(jmi.isEmpty, "no ringing and no busy for strangers")

        // A propose the server kept while the account was offline rings for nothing.
        try harness.deliver(
            "<message from='\(Self.bobPhone)' to='\(Self.me)' type='chat' id='p-old'>"
                + "<propose xmlns='urn:xmpp:jingle-message:0' id='s-old'>"
                + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/></propose>"
                + "<delay xmlns='urn:xmpp:delay' from='example.test' stamp='2026-11-18T10:00:00Z'/>"
                + "</message>")
        try await harness.barrier()
        #expect(harness.notifications.calls.isEmpty)

        try harness.deliver(Self.propose(from: Self.bobPhone, sid: "s3"))
        try await waitUntil("ringing") { harness.notifications.calls.count == 1 }
        let call = try #require(harness.notifications.calls.first)
        #expect(call.accountID == harness.accountID)
        #expect(call.peer == Self.bob)
        #expect(call.video == false)
        try await waitUntil("ringing sent") {
            harness.server.stanzas.contains {
                $0[attribute: "to"] == Self.bobPhone
                    && $0.child("ringing", namespace: "urn:xmpp:jingle-message:0") != nil
            }
        }
        #expect(try harness.messages().isEmpty, "call signalling is no chat message")
        await harness.stop()
    }
}

/// A media engine for calls that never get answered: nothing in it runs.
final class InertMediaEngine: MediaEngine {
    let localCandidates = AsyncStream<(line: String, mid: String)> { $0.finish() }
    let state = AsyncStream<MediaState> { $0.finish() }
    let screenShare = AsyncStream<ScreenShareSource?> { $0.finish() }
    let cameraFailures = AsyncStream<MediaEngineError> { $0.finish() }

    func prepare(iceServers: [ICEServerConfig], audio: Bool, video: Bool) async throws {}
    func createOffer() async throws -> String { "" }
    func createAnswer() async throws -> String { "" }
    func setRemoteDescription(_ sdp: String, isOffer: Bool) async throws {}
    func addRemoteCandidate(sdpLine: String, mid: String) async throws {}
    func setAudioMuted(_ muted: Bool) {}
    func setVideoEnabled(_ enabled: Bool) async {}
    func cameras() -> [CameraDevice] { [] }
    func selectCamera(id: String?) async throws {}
    func currentAudioDevices() -> (input: String?, output: String?) { (nil, nil) }
    func startScreenShare(_ content: ScreenShareContent) async throws {}
    func stopScreenShare() async {}
    func addVideo() async throws -> Bool { false }
    func rollback() async throws {}
    @MainActor func makeLocalVideoView() -> NSView { NSView() }
    @MainActor func makeRemoteVideoView() -> NSView { NSView() }
    func close() {}
}
