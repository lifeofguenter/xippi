import CoreGraphics
import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The account settings against Prosody (Task 26a), with accounts of each test's own: the
/// profile and avatar as a contact sees them, the blocklist across two devices, the archive
/// default, and the password entered again after it changed elsewhere.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .sharesTestServers
)
struct AccountSettingsIntegrationTests {
    /// alice changes her profile and her picture; bob, her contact, sees both.
    @Test func profileAndPictureReachAContact() async throws {
        try await withTeardown { teardown in
            let (alice, bob, aliceJID, bobJID) = try await MessagingIntegrationTests.pair(
                on: .prosody, teardown: teardown)
            try await Self.befriend(alice, aliceJID, bob, bobJID)
            let name = "Alice \(UUID().uuidString.prefix(6))"

            try await alice.session.updateOwnProfile(
                ProfileFields(fullName: name, email: aliceJID, webPage: "https://example.org"),
                visibility: .contacts)
            try await alice.session.publishAvatar(
                imageData: try #require(Self.picture()), visibility: .contacts)

            let own = try #require(try alice.database.ownProfile(accountID: alice.accountID))
            #expect(own.fullName == name)
            let hash = try #require(own.avatarHash)
            try await poll("bob shows alice's picture") {
                try bob.database.rosterItems(accountID: bob.accountID)
                    .first { $0.jid == aliceJID }?.avatarHash == hash
            }
            let seen = try await bob.session.fetchProfile(of: try JID(aliceJID))
            #expect(seen?.fullName == name)
            #expect(seen?.emails.first == aliceJID)

            try await alice.session.removeAvatar()
            try await poll("bob's picture of alice is gone") {
                try bob.database.rosterItems(accountID: bob.accountID)
                    .first { $0.jid == aliceJID }?.avatarHash == nil
            }
            #expect(try alice.database.ownProfile(accountID: alice.accountID)?.avatarHash == nil)
        }
    }

    /// R64, amended (C1): switching Everyone, Contacts, Everyone keeps alice's vCard4 item
    /// and both picture nodes, as she reads them herself; a stranger reads them only while
    /// the setting is Everyone. The nodes themselves are checked, so a deleted profile cannot
    /// pass for a hidden one.
    @Test(arguments: TestServer.allCases)
    func switchingTheAudienceKeepsTheProfileAndOnlyEveryoneReachesAStranger(
        _ server: TestServer
    ) async throws {
        try await withTeardown { teardown in
            let (alice, stranger, aliceJID, _) = try await MessagingIntegrationTests.pair(
                on: server, teardown: teardown)
            let name = "Alice \(UUID().uuidString.prefix(6))"
            let alicePeer = try JID(aliceJID)
            try await alice.session.updateOwnProfile(
                ProfileFields(fullName: name), visibility: .everyone)
            try await alice.session.publishAvatar(
                imageData: try #require(Self.picture()), visibility: .everyone)

            /// What alice's own nodes hold: her vCard4's name, and whether both picture nodes
            /// have an item.
            func own() async throws -> (String?, Bool) {
                let connection = alice.session.connection
                let vcard = try await VCard4.fetch(via: connection)
                var picture = true
                for node in Avatars.nodes {
                    let items = try await PubSub.items(node: node, max: 1, via: connection)
                    picture = picture && !items.isEmpty
                }
                return (vcard?.fullName, picture)
            }
            /// What the stranger reads of the same nodes; nothing where refused.
            func strangerSees() async -> (String?, Bool) {
                let connection = stranger.session.connection
                let vcard = try? await VCard4.fetch(alicePeer, via: connection)
                let items = try? await PubSub.items(
                    node: Avatars.metadataNode, from: alicePeer, max: 1, via: connection)
                return (vcard?.fullName, !(items ?? []).isEmpty)
            }

            /// alice's own vcard-temp as the server gives it to her, raw.
            func ownVCardTemp() async throws -> String? {
                let result = try await alice.session.connection.request(
                    .iq(type: .get, payload: Element("vCard", namespace: VCardTemp.namespace)))
                return result.child("vCard", namespace: VCardTemp.namespace)?.xml()
            }

            for step in [ProfileVisibility.everyone, .contacts, .everyone] {
                let before = try await ownVCardTemp()
                try await alice.session.setProfileVisibility(step)
                // R70: switching never writes, clears or converts the vcard-temp.
                #expect(try await ownVCardTemp() == before, "\(server) \(step): vcard-temp kept")
                let reading = await alice.session.profileAudience()
                #expect(reading?.setting == step, "\(server) \(step)")
                // I5: ejabberd (mod_avatar) copies the picture into its own public vcard-temp
                // whatever the nodes say; Prosody answers vcard-temp from the nodes.
                let photo = try? await VCardTemp.fetch(alicePeer, via: stranger.session.connection)
                switch (server, step) {
                case (.ejabberd, .contacts):
                    #expect(reading?.audience == .everyone, "ejabberd mirrors the picture")
                    #expect(reading?.serverCopy.map(\.name).contains("PHOTO") == true)
                    #expect(reading?.serverCopyCertain == true)
                    #expect(photo?.avatar != nil, "ejabberd shows the stranger the picture")
                case (.prosody, .contacts):
                    #expect(reading?.audience == .contacts)
                    #expect(reading?.serverCopy == [])
                    #expect(photo?.avatar == nil, "Prosody checks the stranger's access")
                default:
                    #expect(reading?.audience == .everyone)
                }
                let kept = try await own()
                #expect(kept.0 == name, "\(server) \(step): vCard4 kept")
                #expect(kept.1, "\(server) \(step): picture nodes kept")
                let seen = await strangerSees()
                #expect(seen.0 == (step == .everyone ? name : nil), "\(server) \(step)")
                #expect(seen.1 == (step == .everyone), "\(server) \(step): picture")
            }
        }
    }

    /// A block on one device reaches the account's other device through the server's push,
    /// and so does the unblock.
    @Test func theBlocklistFollowsTheOtherDevice() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newAccount(on: .prosody, "block")
            let endpoint = TestServer.prosody.directTLS
            let laptop = try await TestClient(jid, resource: "laptop", endpoint: endpoint)
            teardown.stop(laptop)
            let phone = try await TestClient(jid, resource: "phone", endpoint: endpoint)
            teardown.stop(phone)
            try await laptop.comeOnline()
            try await phone.comeOnline()
            let spam = try JID("spam-\(UUID().uuidString.prefix(8).lowercased())@prosody.test")

            try await laptop.session.block(spam)
            try await poll("the phone hears of it") {
                await phone.session.blockedJIDs.contains(spam)
            }
            try await phone.session.unblock(spam)
            try await poll("the laptop hears of it") {
                await !laptop.session.blockedJIDs.contains(spam)
            }
        }
    }

    @Test func theArchiveDefaultIsKeptByTheServer() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newAccount(on: .prosody, "archive")
            let client = try await TestClient(
                jid, resource: "settings", endpoint: TestServer.prosody.directTLS)
            teardown.stop(client)
            try await client.comeOnline()
            let other = try JID("other@prosody.test")

            var preferences = try await client.session.archivePreferences()
            preferences.default = .never
            preferences.always = [other]
            try await client.session.setArchivePreferences(preferences)

            let read = try await client.session.archivePreferences()
            #expect(read.default == .never)
            #expect(read.always == [other])
            preferences.default = .roster
            preferences.always = []
            #expect(try await client.session.setArchivePreferences(preferences).default == .roster)
        }
    }

    /// The password changes on another device; the stored one is refused, the account asks
    /// for it, and once it is entered the account logs in without being added again.
    @Test func thePasswordEnteredAgainLogsIn() async throws {
        try await withTeardown { teardown in
            let jid = try await TestServers.newAccount(on: .prosody, "password")
            let endpoint = TestServer.prosody.directTLS
            let elsewhere = try await TestClient(
                jid, resource: "elsewhere", endpoint: endpoint, credentials: MemoryCredentials())
            teardown.stop(elsewhere)
            try await elsewhere.comeOnline()
            let changed = "changed-\(UUID().uuidString.prefix(8))"
            try await elsewhere.session.changePassword(changed)

            let database = try AppDatabase.inMemory()
            let account = try database.addAccount(
                TestClient.account(jid, resource: "mac", endpoint: endpoint))
            let accountID = try #require(account.id)
            let credentials = MemoryCredentials()
            let board = StatusBoard()
            let manager = SessionManager(
                database: database, credentials: credentials,
                systemEvents: ScriptedSystemEvents(),
                environment: try TestClient.environment(
                    connection: .live(trust: try TestServers.trust()), media: false),
                status: board, notifications: NoNotifications())
            teardown.add { await manager.stop() }
            await manager.start()
            try await poll("login refused") {
                await MainActor.run {
                    AccountStatus(state: board.connection[accountID], enabled: true).needsPassword
                }
            }

            let wrong = await manager.enterPassword("wrong", accountID: accountID)
            guard case .refused(.loginFailed(let condition, _)) = wrong else {
                Issue.record("got \(wrong)")
                return
            }
            #expect(condition == "not-authorized")
            #expect(await manager.enterPassword(changed, accountID: accountID) == .updated)

            #expect(credentials.currentPassword == changed)
            try await poll("online with it") {
                await MainActor.run { board.connection[accountID] == .online(resumed: false) }
            }
        }
    }

    /// Both contacts of each other: alice asks (pre-approving bob where the server allows),
    /// bob approves and asks back, and alice approves when the server asks her.
    static func befriend(
        _ alice: TestClient, _ aliceJID: String, _ bob: TestClient, _ bobJID: String
    ) async throws {
        func subscription(_ client: TestClient, _ jid: String) throws -> String? {
            try client.database.rosterItems(accountID: client.accountID)
                .first { $0.jid == jid }?.subscription
        }
        try await alice.session.addContact(try JID(bobJID))
        try await poll("bob is asked") {
            await bob.session.subscriptionRequests.contains(try JID(aliceJID))
        }
        try await bob.session.approveSubscription(try JID(aliceJID))
        try await poll("both ways") {
            if await alice.session.subscriptionRequests.contains(try JID(bobJID)) {
                try await alice.session.approveSubscription(try JID(bobJID))
            }
            return try subscription(alice, bobJID) == "both"
                && subscription(bob, aliceJID) == "both"
        }
    }

    /// A 300 by 200 picture, as a PNG.
    static func picture() -> Data? {
        guard
            let context = CGContext(
                data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        guard let image = context.makeImage() else { return nil }
        return AvatarCrop.render(
            image, crop: AvatarCrop(imageSize: CGSize(width: 300, height: 200)))
    }
}
