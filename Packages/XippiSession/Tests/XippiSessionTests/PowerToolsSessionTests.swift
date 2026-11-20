import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// What the power tools ask of the sessions: the console's tap on every session of its
/// account from its first byte, the console's send that takes stanzas only, requests that
/// cannot send, and channel nicks that are never participant ids, live or archived.
@Suite struct PowerToolsSessionTests {
    // MARK: The console's tap

    /// Reconnect, Enable and the password sheet all make a new session: the console sees its
    /// login, masked.
    @Test func theConsoleSeesEveryNewSessionsLogin() async throws {
        let f = try await ManagerFixture()
        let accountID = try f.accountID
        await f.manager.start()
        _ = try await f.onlineSession()
        let tap = StreamTap()
        await f.manager.setStreamTap(tap, accountID: accountID)

        for change in ["restart", "enable"] {
            tap.clear()
            let before = await f.manager.session(for: accountID)
            if change == "restart" {
                try await f.manager.restart(accountID: accountID)
            } else {
                try await f.manager.setEnabled(false, accountID: accountID)
                try await f.manager.setEnabled(true, accountID: accountID)
            }
            let session = try #require(await f.manager.session(for: accountID))
            #expect(session !== before)
            try await waitUntil("\(change): online") { await session.progress.started >= 1 }
            let auth = tap.records.filter {
                $0.direction == .outgoing && $0.xml.hasPrefix("<auth ")
            }
            #expect(auth.count == 1, "\(change): \(tap.records.map(\.xml))")
            #expect(auth.first?.xml.contains(">hidden</") == true)
            #expect(tap.records.contains { $0.xml.hasPrefix("<stream:stream") })
        }
        await f.stop()
    }

    /// The console's own tap comes off when it closes; one that closed earlier takes off
    /// nothing a newer console set.
    @Test func onlyTheConsoleThatSetTheTapTakesItOff() async throws {
        let f = try await ManagerFixture()
        let accountID = try f.accountID
        await f.manager.start()
        _ = try await f.onlineSession()
        let old = StreamTap()
        let new = StreamTap()
        await f.manager.setStreamTap(old, accountID: accountID)
        await f.manager.setStreamTap(new, accountID: accountID)
        await f.manager.removeStreamTap(old, accountID: accountID)
        old.clear()
        new.clear()
        try await f.manager.restart(accountID: accountID)
        let session = try #require(await f.manager.session(for: accountID))
        try await waitUntil("online") { await session.progress.started >= 1 }
        #expect(new.records.contains { $0.xml.hasPrefix("<auth ") })
        #expect(old.records.isEmpty)

        await f.manager.removeStreamTap(new, accountID: accountID)
        new.clear()
        try await f.manager.restart(accountID: accountID)
        let next = try #require(await f.manager.session(for: accountID))
        try await waitUntil("online again") { await next.progress.started >= 1 }
        #expect(new.records.isEmpty)
        await f.stop()
    }

    // MARK: Sending

    @Test func theConsoleSendsStanzasOnly() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        await #expect(throws: ConsoleSendError.invalid(.notAStanza)) {
            try await harness.session.sendConsoleStanza("<inactive xmlns='urn:xmpp:csi:0'/>")
        }
        await #expect(throws: ConsoleSendError.invalid(.notWellFormed)) {
            try await harness.session.sendConsoleStanza("<presence>")
        }
        try await harness.session.sendConsoleStanza(
            "<presence><status>from the console</status></presence>")
        try await waitUntil("presence written") {
            harness.server.stanzas.contains {
                $0.name == "presence" && $0.child("status")?.text == "from the console"
            }
        }
        #expect(!harness.server.received.contains { $0.element.name == "inactive" })
        await harness.stop()
    }

    /// The tools' sender asks; it never writes a stanza of its own.
    @Test func toolRequestsCannotSend() async throws {
        let harness = try await SessionHarness()
        try await harness.goOnline()
        let sender = harness.session.toolRequests
        await #expect(throws: SendError.self) {
            try await sender.send(Element("presence"))
        }
        let info = try await Disco.info(try JID(SessionServer.domain), via: sender)
        #expect(info.identities.contains { $0.category == "server" })
        await harness.stop()
    }

    // MARK: Channel nicks

    /// From the archive: the stamped nick, else the stamped address, else no nick at all.
    @Test func archivedChannelMessagesNeverShowParticipantIDs() async throws {
        let f = try CatchUpFixture()
        let channel = "chan@mix.example.test"
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: channel, kind: .channel).id)
        func message(_ participant: String, _ body: String, stamp: String) throws -> Element {
            let header =
                "<stream:stream xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>"
            var parser = XMLStreamParser()
            for case .stanza(let element) in parser.feed(
                Array(
                    (header + "<message from='\(channel)/\(participant)' type='groupchat'"
                        + " id='\(participant)'><body>\(body)</body>\(stamp)</message>").utf8))
            {
                return element
            }
            throw TestFailure()
        }
        f.archive.set(
            channel,
            [
                FakeArchive.Entry(
                    id: "m1",
                    message: try message(
                        "pid-carol", "address only",
                        stamp:
                            "<mix xmlns='urn:xmpp:mix:core:1'><jid>carol@example.test</jid></mix>"),
                    stamp: CatchUpFixture.base),
                FakeArchive.Entry(
                    id: "m2",
                    message: try message(
                        "pid-eve", "two stamps",
                        stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>Eve</nick></mix>"
                            + "<mix xmlns='urn:xmpp:mix:core:0'><nick>alice</nick></mix>"),
                    stamp: CatchUpFixture.base.addingTimeInterval(1)),
                FakeArchive.Entry(
                    id: "m3",
                    message: try message(
                        "pid-bob", "nick",
                        stamp: "<mix xmlns='urn:xmpp:mix:core:0'><nick>Bob</nick></mix>"),
                    stamp: CatchUpFixture.base.addingTimeInterval(2)),
            ])
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(channel),
                ownOccupant: RoomOccupant(jid: try JID("\(channel)/pid-me"), occupantID: nil),
                trust: RoomTrust(), nick: "alice"))
        try await waitUntil("channel caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: channel) == "m3"
        }
        let rows = try f.rows(channel)
        #expect(rows.map(\.body) == ["address only", "two stamps", "nick"])
        #expect(rows.map(\.senderNick) == ["carol@example.test", "", "Bob"])
        for row in rows {
            #expect(row.senderNick?.hasPrefix("pid-") != true)
        }
    }

    /// Archived senders without a name stay apart: each nameless participant by its id, and
    /// a copy naming no participant (a bare channel `from` with no stamp, or two stamps) is
    /// unknown and its own group.
    @Test func archivedNamelessSendersStayApart() async throws {
        let f = try CatchUpFixture()
        let channel = "chan@mix.example.test"
        let chatID = try #require(
            try f.database.ensureChat(accountID: f.accountID, jid: channel, kind: .channel).id)
        func message(_ from: String, _ body: String, stamp: String = "") throws -> Element {
            let header =
                "<stream:stream xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>"
            var parser = XMLStreamParser()
            for case .stanza(let element) in parser.feed(
                Array(
                    (header + "<message from='\(from)' type='groupchat' id='\(body)'>"
                        + "<body>\(body)</body>\(stamp)</message>").utf8))
            {
                return element
            }
            throw TestFailure()
        }
        let two =
            "<mix xmlns='urn:xmpp:mix:core:1'><nick>Bob</nick></mix>"
            + "<mix xmlns='urn:xmpp:mix:core:1'><nick>Eve</nick></mix>"
        let entries = try [
            ("m1", "\(channel)/pid-a", ""), ("m2", "\(channel)/pid-b", ""),
            ("m3", channel, ""), ("m4", channel, ""), ("m5", "\(channel)/pid-c", two),
        ].enumerated().map { offset, entry in
            FakeArchive.Entry(
                id: entry.0, message: try message(entry.1, entry.0, stamp: entry.2),
                stamp: CatchUpFixture.base.addingTimeInterval(Double(offset)))
        }
        f.archive.set(channel, entries)
        await f.catchUp.roomJoined(
            RoomArchive(
                chatID: chatID, room: try JID(channel),
                ownOccupant: RoomOccupant(jid: try JID("\(channel)/pid-me"), occupantID: nil),
                trust: RoomTrust(), nick: "alice"))
        try await waitUntil("channel caught up") {
            try f.database.lastKnownArchiveID(accountID: f.accountID, archive: channel) == "m5"
        }
        let items = try f.database.transcriptItems(for: try f.rows(channel))
        #expect(items.map(\.message.body) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(
            items.map(\.message.roomSender) == [
                .nameless(participantID: "pid-a"), .nameless(participantID: "pid-b"), .unknown,
                .unknown, .unknown,
            ])
        #expect(Set(items.map { $0.senderKey(inRoom: true) }).count == 5)
        #expect(Set(items.map(\.message.roomColorKey)).count == 5)
    }

    /// In a channel that hides addresses the account is found by the participant id the
    /// join gave it.
    @Test func theAccountIsFoundByItsParticipantID() async throws {
        let channel = ChannelToolsTests.channel
        let harness = try await SessionHarness { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: channel, kind: .channel)
        }
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(
                state: .joined,
                own: RoomOccupant(jid: try JID("\(channel)/pid-me"), occupantID: nil)))
        harness.server.setResponder { iq in
            guard iq[attribute: "to"] == channel,
                iq.child("pubsub", namespace: MIX.pubsubNamespace) != nil
            else { return nil }
            return ChannelToolsTests.reply(
                iq,
                "<pubsub xmlns='http://jabber.org/protocol/pubsub'>"
                    + "<items node='urn:xmpp:mix:nodes:participants'>"
                    + "<item id='pid-zed'><participant xmlns='urn:xmpp:mix:core:1'>"
                    + "<nick>Zed</nick></participant></item>"
                    + "<item id='pid-me'><participant xmlns='urn:xmpp:mix:core:1'>"
                    + "<nick>me</nick></participant></item>"
                    + "</items></pubsub>")
        }
        try await harness.goOnline()
        let chatID = try #require(
            try harness.database.chat(accountID: harness.accountID, jid: channel)?.id)
        let members = try await harness.session.channelMembers(chatID: chatID)
        #expect(members.map(\.name) == ["me", "Zed"])
        #expect(members.map(\.isSelf) == [true, false])
        await harness.stop()
    }
}

private struct TestFailure: Error {}
