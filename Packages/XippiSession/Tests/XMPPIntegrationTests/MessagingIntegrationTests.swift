import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Messages, carbons, files and MIX between our own clients, with accounts of each test's own.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .sharesTestServers
)
struct MessagingIntegrationTests {
    /// How a direct chat is encrypted.
    enum ChatEncryption: String, CaseIterable, CustomTestStringConvertible, Sendable {
        /// The user chose no encryption for the chat.
        case chosenPlain
        /// A new chat with a contact who publishes OMEMO devices: OMEMO by default (R63).
        case omemoDefault

        var testDescription: String { rawValue }
    }

    /// alice writes to bob. The message arrives live, and then comes back from each one's
    /// archive (the newest page, which holds it): one row on each side (spec 7.5, Review
    /// Focus 3), and each catch-up ends at the newest item of the archive.
    ///
    /// In an OMEMO chat the newest item is not the message: bob's client answers alice's key
    /// exchange with an empty OMEMO message that completes the session (XEP-0384), stored by
    /// the server after the text. The catch-up passes it and makes no row for it.
    @Test(arguments: ChatEncryption.allCases)
    func messageAliceToBobDedup(_ encryption: ChatEncryption) async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await Self.pair(
                on: .prosody, teardown: teardown)
            let text = "Hello bob \(UUID().uuidString)"
            let aliceChat = try alice.chat(with: bobJID)
            if encryption == .chosenPlain {
                try alice.database.chooseEncryption(chatID: aliceChat, .none)
            }
            let expected: EncryptionMode = encryption == .chosenPlain ? .none : .omemo

            try await alice.session.send(text: text, chatID: aliceChat)
            let live = try await bob.message(text)
            #expect(live.direction == .incoming)
            #expect(live.encryption == expected)
            let archiveID = try #require(live.archiveID)
            try await poll("alice's message acknowledged") {
                try alice.rows(text).first?.state == .sent
            }
            #expect(try alice.database.chat(id: aliceChat)?.encryption == expected)
            #expect(try bob.database.chat(id: try bob.chat(with: aliceJID))?.encryption == expected)
            try await alice.quiet(for: .seconds(1))
            try await bob.quiet(for: .seconds(1))

            // Each account has its own archive, with its own ids for the message.
            for client in [alice, bob] {
                let catchUp = try #require(await client.session.archive as? MAMCatchUp)
                let started = ContinuousClock.now
                await catchUp.run(archive: nil, since: nil)
                let rows = try client.rows(text)
                #expect(rows.count == 1)
                // The page with the message came back from the archive and was stored on the
                // row the live copy made.
                let stored = try #require(rows.first?.archiveID)
                // The archive's own order of the page the catch-up asked for: the position it
                // recorded is the page's newest item, at or after the message.
                let page = Self.archivePage(in: client.log, since: started)
                let known = try client.database.lastKnownArchiveID(
                    accountID: client.accountID, archive: client.session.jid.description)
                #expect(known == page.last?.id)
                let messageIndex = try #require(page.firstIndex { $0.id == stored })
                let knownIndex = try #require(page.firstIndex { $0.id == known })
                #expect(messageIndex <= knownIndex)
                // What follows the message in the archive is OMEMO without content (the
                // session's completion), and none of it became a row.
                for later in page[(messageIndex + 1)...] {
                    #expect(later.xml.contains("<encrypted "), "\(later.xml)")
                    #expect(!later.xml.contains("<payload>"), "\(later.xml)")
                    #expect(try client.rows(archiveID: later.id).isEmpty)
                }
                #expect(try client.allRows().count == 1)
            }
            #expect(try bob.rows(text).first?.archiveID == archiveID)
            #expect(try alice.rows(text).first?.direction == .outgoing)
        }
    }

    /// The results of the archive query sent since `instant`, in the order the archive gave
    /// them: each one's archive id and XML.
    static func archivePage(in log: StreamLog, since instant: ContinuousClock.Instant)
        -> [(id: String, xml: String)]
    {
        guard
            let query = log.first(.outgoing, since: instant, containing: "urn:xmpp:mam:2"),
            let queryID = query.xml.firstMatch(of: /queryid='([^']+)'/)?.output.1
        else { return [] }
        return log.entries(
            .incoming, since: instant, containing: ["<result ", "queryid='\(queryID)'"]
        ).compactMap { entry in
            guard let id = ConnectionLossIntegrationTests.resultID(in: entry.xml) else {
                return nil
            }
            return (id, entry.xml)
        }
    }

    /// alice on two Macs (Message Carbons, XEP-0280): what one of them sends shows on the other
    /// as hers, and what bob sends to one of them shows on the other too; one row each.
    @Test func carbonsAcrossTwoResources() async throws {
        try await withTeardown { teardown in
            let aliceJID = try await TestServers.newAccount(on: .prosody, "alice")
            let bobJID = try await TestServers.newAccount(on: .prosody, "bob")
            let endpoint = TestServer.prosody.directTLS
            let laptop = try await TestClient(aliceJID, resource: "laptop", endpoint: endpoint)
            teardown.stop(laptop)
            let desktop = try await TestClient(aliceJID, resource: "desktop", endpoint: endpoint)
            teardown.stop(desktop)
            let bob = try await TestClient(bobJID, resource: "carbons", endpoint: endpoint)
            teardown.stop(bob)
            for client in [laptop, desktop, bob] { try await client.comeOnline() }

            // Sent on the laptop: the desktop has it as sent by alice.
            let sent = "From alice's laptop \(UUID().uuidString)"
            try await laptop.session.send(text: sent, chatID: try laptop.chat(with: bobJID))
            #expect(try await bob.message(sent).direction == .incoming)
            let copy = try await desktop.message(sent)
            #expect(copy.direction == .outgoing)

            // To the laptop only: the desktop has it as received.
            let laptopJID = try #require(await laptop.session.connection.boundJID)
            let received = "To alice's laptop \(UUID().uuidString)"
            try await bob.session.connection.send(.message(to: laptopJID, body: received))
            #expect(try await laptop.message(received).direction == .incoming)
            #expect(try await desktop.message(received).direction == .incoming)

            // Each one once, wherever it arrived.
            // Duplicates would come on alice's streams: both quiet first.
            try await laptop.quiet(for: .seconds(1))
            try await desktop.quiet(for: .seconds(1))
            for client in [laptop, desktop] {
                #expect(try client.rows(sent).count == 1)
                #expect(try client.rows(received).count == 1)
            }
            #expect(try bob.rows(sent).count == 1)
        }
    }

    /// alice sends bob a file through Prosody's HTTP File Upload (http_file_share) in a chat
    /// she set to no encryption: the link is the server's https address, and bob fetches the
    /// same bytes.
    @Test func plainFileUploadRoundTrip() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await Self.pair(
                on: .prosody, media: true, teardown: teardown)
            let bytes = try Self.randomFile(teardown: teardown)
            let aliceChat = try alice.chat(with: bobJID)
            try alice.database.chooseEncryption(chatID: aliceChat, .none)

            let messageID = try await alice.session.sendFile(url: bytes.file, chatID: aliceChat)
            try await poll("upload sent") {
                try alice.database.message(id: messageID)?.state == .sent
            }
            let (message, received) = try await Self.fileMessage(at: bob, from: aliceJID)
            #expect(message.encryption == .none)
            let link = try #require(received.remoteURL)
            #expect(link.hasPrefix("https://localhost:5281/"))
            let local = try await bob.session.downloadAttachment(try #require(received.id))
            #expect(try Data(contentsOf: local) == bytes.data)
        }
    }

    /// The same in a new chat, which is OMEMO by default (R63) since bob publishes OMEMO
    /// devices: the file goes up encrypted (XEP-0454), the link is `aesgcm://` with the key in
    /// its fragment and travels inside the OMEMO message, and bob decrypts the same bytes. The
    /// upload service only ever had the ciphertext.
    @Test func encryptedFileUploadRoundTrip() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await Self.pair(
                on: .prosody, media: true, teardown: teardown)
            let bytes = try Self.randomFile(teardown: teardown)
            let aliceChat = try alice.chat(with: bobJID)

            let messageID = try await alice.session.sendFile(url: bytes.file, chatID: aliceChat)
            #expect(try alice.database.chat(id: aliceChat)?.encryption == .omemo)
            try await poll("upload sent") {
                try alice.database.message(id: messageID)?.state == .sent
            }
            let (message, received) = try await Self.fileMessage(at: bob, from: aliceJID)
            #expect(message.encryption == .omemo)
            let link = try #require(received.remoteURL)
            #expect(link.hasPrefix("aesgcm://localhost:5281/"))
            // The key never went over the wire in the clear: only inside OMEMO payloads.
            let fragment = try #require(link.split(separator: "#").last.map(String.init))
            #expect(!alice.log.outgoing.contains { $0.contains(fragment) })

            let local = try await bob.session.downloadAttachment(try #require(received.id))
            #expect(try Data(contentsOf: local) == bytes.data)
            // What the service keeps is ciphertext: the bytes and a 16-byte tag.
            let stored = try #require(URL(string: "https" + link.dropFirst("aesgcm".count)))
            var plainURL = URLComponents(url: stored, resolvingAgainstBaseURL: false)
            plainURL?.fragment = nil
            // The transport cancels what it still runs when it goes: kept until the body is in.
            let transport = URLSessionMediaTransport(trust: try TestServers.trust())
            let response = try await transport.download(
                try #require(plainURL?.url), limit: 1_000_000)
            var held = Data()
            for try await chunk in response.body { held.append(chunk) }
            withExtendedLifetime(transport) {}
            #expect(response.status == 200)
            #expect(held.count == bytes.data.count + 16)
            #expect(held.prefix(1_000) != bytes.data.prefix(1_000))
        }
    }

    /// 150 KB of random bytes in a file that is removed when the test ends.
    static func randomFile(teardown: Teardown) throws -> (file: URL, data: Data) {
        let data = Data((0..<150_000).map { _ in UInt8.random(in: 0...255) })
        let file = FileManager.default.temporaryDirectory.appending(
            path: "upload-\(UUID().uuidString).bin")
        try data.write(to: file)
        teardown.add { try? FileManager.default.removeItem(at: file) }
        return (file, data)
    }

    /// The first message with a file in `client`'s chat with `peer`, once there is one.
    static func fileMessage(
        at client: TestClient, from peer: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (MessageRecord, AttachmentRecord) {
        let chat = try client.chat(with: peer)
        var found: (MessageRecord, AttachmentRecord)?
        try await poll("file message", sourceLocation: sourceLocation) {
            let messages = try client.database.page(chatID: chat, before: nil, limit: 50)
            found = try messages.lazy.compactMap { message -> (MessageRecord, AttachmentRecord)? in
                guard let id = message.id,
                    let attachment = try client.database.attachments(messageID: id).first
                else { return nil }
                return (message, attachment)
            }.first
            return found != nil
        }
        return try #require(found, sourceLocation: sourceLocation)
    }

    /// A MIX channel on ejabberd (XEP-0369 through the account's server, XEP-0405): alice makes
    /// it, both join, and each one's messages reach the other, once.
    ///
    /// ejabberd 26.09 answers every `<create/>` with internal-server-error: its
    /// `mod_mix:process_mix_create` reads `access_create` with the channel service's host
    /// instead of the server's (mod_mix.erl:358), and mod_mix is loaded only for the server.
    /// That is recorded as a known issue, and the server's admin command makes the channel
    /// instead. Once ejabberd creates channels again, the known issue is missing and this test
    /// fails: drop the admin command then.
    @Test func mixJoinAndMessage() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, _) = try await Self.pair(on: .ejabberd, teardown: teardown)
            let service = try JID("mix.\(TestServer.ejabberd.domain)")
            let name = "channel-\(UUID().uuidString.lowercased().prefix(12))"
            var created: JID?
            // Only the server's internal-server-error is the known issue: any other refusal
            // of our `<create/>` (bad-request, a timeout) fails the test.
            try await withKnownIssue("ejabberd 26.09 refuses every MIX channel creation") {
                created = try await MIX.create(
                    service: service, channel: name, via: alice.session.connection)
            } matching: { issue in
                guard case .error(let error) = issue.error as? IQError else { return false }
                return error.condition == .internalServerError
            }
            let channel: JID
            if let created {
                channel = created
            } else {
                channel = try await TestServers.ejabberdMakesChannel(name, creator: aliceJID)
            }

            let aliceChat = try await alice.session.joinChannel(jid: channel, nick: "alice")
            try await alice.joined(aliceChat)
            let bobChat = try await bob.session.joinChannel(jid: channel, nick: "bob")
            try await bob.joined(bobChat)

            let fromAlice = "alice in the channel \(UUID().uuidString)"
            try await alice.session.send(text: fromAlice, chatID: aliceChat)
            let atBob = try await bob.message(fromAlice)
            #expect(atBob.direction == .incoming)
            #expect(atBob.chatID == bobChat)
            let fromBob = "bob in the channel \(UUID().uuidString)"
            try await bob.session.send(text: fromBob, chatID: bobChat)
            let atAlice = try await alice.message(fromBob)
            #expect(atAlice.direction == .incoming)
            #expect(atAlice.chatID == aliceChat)

            // Our own messages come back from the channel: matched to the row, not stored again.
            try await alice.quiet(for: .seconds(2))
            #expect(try alice.rows(fromAlice).count == 1)
            #expect(try alice.rows(fromAlice).first?.direction == .outgoing)
            #expect(try bob.rows(fromAlice).count == 1)
            #expect(try alice.rows(fromBob).count == 1)
        }
    }

    /// alice and bob on `server`, straight to it, online, with accounts of their own; and
    /// their bare JIDs.
    static func pair(on server: TestServer, media: Bool = false, teardown: Teardown)
        async throws -> (TestClient, TestClient, String, String)
    {
        let aliceJID = try await TestServers.newAccount(on: server, "alice")
        let bobJID = try await TestServers.newAccount(on: server, "bob")
        let alice = try await TestClient(
            aliceJID, resource: "messages", endpoint: server.directTLS, media: media)
        teardown.stop(alice)
        let bob = try await TestClient(
            bobJID, resource: "messages", endpoint: server.directTLS, media: media)
        teardown.stop(bob)
        try await alice.comeOnline()
        try await bob.comeOnline()
        return (alice, bob, aliceJID, bobJID)
    }
}
