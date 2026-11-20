import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The power tools and channels against the test servers: the XML console's ring on a real
/// login, service discovery of Prosody, Prosody's admin commands, and a MIX channel on
/// ejabberd with nicks, not participant ids.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .sharesTestServers
)
struct PowerToolsIntegrationTests {
    /// The console's ring on a login: the presence the session sends and the server's copy
    /// of it back to the same resource are there, the SASL exchange shows "hidden", and the
    /// password is nowhere.
    @Test func xmlConsoleShowsOwnPresenceAndHidesTheLogin() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newProsodyAccount("console")
            let client = try await TestClient(
                jid, resource: "console", endpoint: TestServers.prosodyDirectTLS)
            teardown.stop(client)
            let tap = StreamTap()
            await client.session.setStreamTap(tap.sink)
            try await client.session.start()
            try await poll("session started") { await client.session.progress.started >= 1 }

            let full = "\(jid)/console"
            try await poll("own presence back") {
                tap.records.contains {
                    $0.direction == .incoming && $0.xml.hasPrefix("<presence")
                        && $0.xml.contains("from='\(full)'")
                }
            }
            let records = tap.records
            #expect(records.contains { $0.direction == .outgoing && $0.xml.hasPrefix("<presence") })
            let sasl = records.filter {
                $0.xml.contains("urn:ietf:params:xml:ns:xmpp-sasl")
                    && ["<auth ", "<challenge", "<response", "<success"].contains(
                        where: $0.xml.hasPrefix)
            }
            #expect(sasl.count >= 3, "\(records.map(\.xml))")
            for record in sasl {
                #expect(record.xml.contains(">hidden</"), "\(record.xml)")
            }
            let base64 = Data(TestServers.password.utf8).base64EncodedString()
            for record in records {
                #expect(!record.xml.contains(TestServers.password))
                #expect(!record.xml.contains(base64))
            }

            // What the console's send box sends goes out as the user and comes back.
            try await client.session.sendConsoleStanza(
                "<presence><status>from the console</status></presence>")
            try await poll("console presence back") {
                tap.records.contains {
                    $0.direction == .incoming && $0.xml.contains("from the console")
                        && $0.xml.contains("from='\(full)'")
                }
            }
        }
    }

    /// Prosody's items and their info, as the discovery browser reads them.
    @Test func discoBrowsesProsody() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newProsodyAccount("disco")
            let client = try await TestClient(
                jid, resource: "disco", endpoint: TestServers.prosodyDirectTLS)
            teardown.stop(client)
            try await client.comeOnline()
            let sender = client.session.toolRequests
            let server = try JID(TestServer.prosody.domain)

            let items = try await Disco.items(server, via: sender).map(\.jid.description)
            #expect(items.contains(TestServer.prosody.conference))
            #expect(items.contains("upload.prosody.test"))
            let conference = try await Disco.info(
                try JID(TestServer.prosody.conference), via: sender)
            #expect(conference.features.contains(MUC.namespace))
            #expect(conference.identities.contains { $0.category == "conference" })
            let info = try await Disco.info(server, via: sender)
            #expect(info.identities.contains { $0.category == "server" })
            #expect(info.features.contains(AdHoc.namespace))
            // Prosody has no MIX: no channel service.
            #expect(try await client.session.channelServices().isEmpty)
        }
    }

    /// Prosody's admin commands for its admin, run to their form and cancelled.
    @Test func adHocListsProsodysAdminCommands() async throws {
        try await withTeardown { teardown in
            let client = try await TestClient(
                "admin@\(TestServer.prosody.domain)",
                resource: "adhoc-\(UUID().uuidString.prefix(8))",
                endpoint: TestServers.prosodyDirectTLS)
            teardown.stop(client)
            try await client.comeOnline()
            let sender = client.session.toolRequests
            let server = try JID(TestServer.prosody.domain)

            let commands = try await AdHoc.list(server, via: sender)
            let addUser = "http://jabber.org/protocol/admin#add-user"
            #expect(commands.contains { $0.node == addUser }, "\(commands.map(\.node))")

            let step = try await AdHoc.execute(server, node: addUser, via: sender)
            #expect(step.status == .executing)
            #expect(step.form?.type == .form)
            #expect(step.primaryAction != nil)
            let cancelled = try await AdHoc.perform(
                .cancel, after: step, at: server, form: nil, via: sender)
            #expect(cancelled.status == .canceled)
        }
    }

    /// A channel on ejabberd: the service is found, creation is refused by ejabberd 26.09's
    /// bug (then made by the server's admin command), and the members and a live message
    /// show nicks, never participant ids.
    @Test func channelOnEjabberdShowsNicks() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await MessagingIntegrationTests.pair(
                on: .ejabberd, teardown: teardown)
            let service = try JID("mix.\(TestServer.ejabberd.domain)")
            #expect(try await alice.session.channelServices() == [service])

            let name = "tools-\(UUID().uuidString.lowercased().prefix(12))"
            var created: Int64?
            try await withKnownIssue("ejabberd 26.09 refuses every MIX channel creation") {
                created = try await alice.session.createChannel(
                    on: service, name: name, nick: "Alice")
            } matching: { issue in
                guard case .refused(let error) = issue.error as? SessionError else {
                    return false
                }
                return error.condition == .internalServerError
            }
            let channel: JID
            let aliceChat: Int64
            if let created {
                aliceChat = created
                channel = try JID(#require(try alice.database.chat(id: created)).jid)
            } else {
                #expect(
                    try alice.database.chat(
                        accountID: alice.accountID, jid: "\(name)@\(service)") == nil,
                    "a refused creation stores nothing")
                channel = try await TestServers.ejabberdMakesChannel(name, creator: aliceJID)
                aliceChat = try await alice.session.joinChannel(jid: channel, nick: "Alice")
            }
            try await alice.joined(aliceChat)
            let bobChat = try await bob.session.joinChannel(jid: channel, nick: "Bob")
            try await bob.joined(bobChat)

            try await poll("both members listed") {
                try await alice.session.channelMembers(chatID: aliceChat).count == 2
            }
            let members = try await alice.session.channelMembers(chatID: aliceChat)
            #expect(members.map(\.name) == ["Alice", "Bob"])
            #expect(members.map(\.isSelf) == [true, false])
            #expect(members.map { $0.jid?.description } == [aliceJID, bobJID])

            let text = "bob in the tools channel \(UUID().uuidString)"
            try await bob.session.send(text: text, chatID: bobChat)
            let atAlice = try await alice.message(text)
            #expect(atAlice.senderNick == "Bob")
            #expect(atAlice.direction == .incoming)
        }
    }
}
