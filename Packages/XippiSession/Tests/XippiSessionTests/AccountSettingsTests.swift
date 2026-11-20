import CoreGraphics
import Foundation
import ImageIO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A manager whose server takes one password only (PLAIN), the rest answered as by
/// `SessionServer`.
private struct PasswordFixture {
    let server = SessionServer()
    let clock = TestClock()
    let database: AppDatabase
    let store: TokenStore
    let board: StatusBoard
    let manager: SessionManager
    let transports = Locked<[FakeTransport]>([])
    /// The password the server takes.
    let accepted = Locked("new")
    let accountID: Int64

    init(store: TokenStore = TokenStore()) async throws {
        database = try AppDatabase.inMemory()
        self.store = store
        let account = try database.addAccount(ManagerFixture.account())
        accountID = try #require(account.id)
        try? store.setPassword("old", for: try JID(SessionServer.account))
        board = await MainActor.run { StatusBoard() }
        var environment = SessionHarness.environment(
            server: server, clock: clock, transports: transports)
        let server = self.server
        let made = transports
        let accepted = self.accepted
        let clock = self.clock
        let resolver = FakeResolver([SessionHarness.endpoint])
        environment.connection = { _ in
            ConnectionEnvironment(
                clock: clock, resolver: resolver, trust: SystemTrustEvaluator(pinnedSHA256: []),
                makeTransport: { _, _ in
                    let transport = FakeTransport()
                    let index = made.withLock { list in
                        list.append(transport)
                        return list.count - 1
                    }
                    transport.setResponder { text in
                        if let auth = SessionServer.elements(text).first(where: {
                            $0.name == "auth"
                        }), Self.password(in: auth) != accepted.value {
                            return [
                                "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                                    + "<not-authorized/></failure>"
                            ]
                        }
                        return server.respond(connection: index, text: text)
                    }
                    return transport
                },
                jitter: { $0 })
        }
        manager = SessionManager(
            database: database, credentials: store, systemEvents: FakeSystemEvents(),
            environment: environment, status: board, notifications: RecordingSink())
    }

    /// The password of a PLAIN `<auth/>`.
    static func password(in auth: Element) -> String? {
        guard let data = Data(base64Encoded: auth.text),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.split(separator: "\0", omittingEmptySubsequences: false).last.map(String.init)
    }

    func state() async -> ConnectionState? {
        await MainActor.run { board.connection[accountID] }
    }

    func stop() async {
        await manager.stop()
        for transport in transports.value { transport.close() }
    }
}

@Suite("PasswordEntry")
struct PasswordEntryTests {
    @Test(.timeLimit(.minutes(1)))
    func theNewPasswordIsKeptAndTheAccountLogsIn() async throws {
        let fixture = try await PasswordFixture()
        await fixture.manager.start()
        try await waitUntil("login refused") {
            if case .authFailed = await fixture.state() { true } else { false }
        }
        let status = AccountStatus(state: await fixture.state(), enabled: true)
        #expect(status.needsPassword)

        let outcome = await fixture.manager.enterPassword("new", accountID: fixture.accountID)

        #expect(outcome == .updated)
        #expect(fixture.store.passwords.value[SessionServer.account] == "new")
        try await waitUntil("online with the new password") {
            guard let session = await fixture.manager.session(for: fixture.accountID) else {
                return false
            }
            return await session.progress.started >= 1
        }
        await fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedPasswordKeepsTheStoredOne() async throws {
        let fixture = try await PasswordFixture()
        let outcome = await fixture.manager.enterPassword("wrong", accountID: fixture.accountID)
        #expect(outcome == .refused(.loginFailed(condition: "not-authorized", text: nil)))
        #expect(fixture.store.passwords.value[SessionServer.account] == "old")
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnusablePasswordIsRefusedBeforeConnecting() async throws {
        let fixture = try await PasswordFixture()
        let outcome = await fixture.manager.enterPassword("\u{AD}", accountID: fixture.accountID)
        #expect(outcome == .unusablePassword)
        #expect(fixture.transports.value.isEmpty)
        #expect(await fixture.manager.enterPassword("x", accountID: 999) == .accountNotFound)
    }

    /// An existing password with an emoji (unassigned in Unicode 3.2) is one this client logs
    /// in with: entered again, it is checked and kept like any other.
    @Test(.timeLimit(.minutes(1)))
    func anExistingPasswordWithAnEmojiCanBeEnteredAgain() async throws {
        let fixture = try await PasswordFixture()
        fixture.accepted.set("pw\u{1F511}")
        let outcome = await fixture.manager.enterPassword(
            "pw\u{1F511}", accountID: fixture.accountID)
        #expect(outcome == .updated)
        #expect(fixture.store.passwords.value[SessionServer.account] == "pw\u{1F511}")
    }

    /// G1 (XEP-0474): once SCRAM worked for the account, the password entered again is never
    /// sent with PLAIN, not even to a server that offers nothing else. Someone who refuses the
    /// account's SCRAM login to make the user type the password gets nothing.
    @Test(.timeLimit(.minutes(1)))
    func aPasswordEnteredAfterSCRAMWorkedIsNeverSentWithPlain() async throws {
        let fixture = try await PasswordFixture()
        await fixture.store.refusePlain(for: try JID(SessionServer.account))
        let outcome = await fixture.manager.enterPassword("new", accountID: fixture.accountID)
        guard case .refused = outcome else {
            Issue.record("entered with PLAIN refused: \(outcome)")
            return
        }
        #expect(fixture.store.passwords.value[SessionServer.account] == "old")
        let written = fixture.transports.value.flatMap(\.sent).joined()
        #expect(!written.contains("PLAIN"))
        #expect(!written.contains("<auth"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPasswordThatCannotBeKeptIsReported() async throws {
        let fixture = try await PasswordFixture(store: TokenStore(failsWrites: true))
        let outcome = await fixture.manager.enterPassword("new", accountID: fixture.accountID)
        #expect(outcome == .passwordNotStored)
    }

    /// m1: the token minted under the old password is not kept.
    @Test(.timeLimit(.minutes(1)))
    func anEnteredPasswordDropsTheStoredToken() async throws {
        let fixture = try await PasswordFixture()
        let jid = try JID(SessionServer.account)
        await fixture.store.store(TokenStore.staleToken, for: jid)
        #expect(
            await fixture.manager.enterPassword("new", accountID: fixture.accountID) == .updated)
        #expect(fixture.store.tokens.value[SessionServer.account] == nil)
    }

    @Test func onlyCredentialFailuresAskForAPassword() {
        for condition in ["not-authorized", "credentials-expired", "unusable-password"] {
            #expect(AccountStatus.loginFailed(condition: condition).needsPassword)
        }
        for condition in ["account-disabled", "server-signature-mismatch", "aborted"] {
            #expect(!AccountStatus.loginFailed(condition: condition).needsPassword)
        }
        #expect(!AccountStatus.online.needsPassword)
        #expect(!AccountStatus.offline.needsPassword)
    }
}

@Suite("AccountSettings")
struct AccountSettingsTests {
    // MARK: Connection options

    @Test(.timeLimit(.minutes(1)))
    func aPriorityChangeIsSentWithoutReconnecting() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        let id = try fixture.accountID

        try await fixture.manager.setConnectionOptions(
            resource: SessionServer.resource, priority: 7, server: nil, accountID: id)

        try await waitUntil("presence with priority 7") {
            fixture.server.stanzas.contains {
                $0.name == "presence" && $0.child("priority")?.text == "7"
            }
        }
        #expect(fixture.transports.value.count == 1)
        #expect(try fixture.database.account(id: id)?.priority == 7)
        await fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aResourceChangeReconnectsWithIt() async throws {
        let fixture = try await ManagerFixture()
        await fixture.manager.start()
        _ = try await fixture.onlineSession()
        let id = try fixture.accountID

        // The fake transports take direct TLS only: the server named is the test server's.
        try await fixture.manager.setConnectionOptions(
            resource: "desk", priority: 0,
            server: ServerAddress(host: SessionServer.domain, port: 5223), accountID: id)

        let account = try #require(try fixture.database.account(id: id))
        #expect(account.resource == "desk")
        #expect(account.hostOverride == SessionServer.domain)
        #expect(account.portOverride == 5223)
        #expect(account.directTLSOverride == true)
        try await waitUntil("bound as desk") {
            fixture.server.stanzas.contains {
                $0.child("bind")?.child("resource")?.text == "desk"
            }
        }
        await fixture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidConnectionOptionsChangeNothing() async throws {
        let fixture = try await ManagerFixture()
        let id = try fixture.accountID
        await #expect(throws: ConnectionOptionsError.invalidPriority) {
            try await fixture.manager.setConnectionOptions(
                resource: "", priority: 128, server: nil, accountID: id)
        }
        await #expect(throws: ConnectionOptionsError.invalidResource) {
            try await fixture.manager.setConnectionOptions(
                resource: String(repeating: "r", count: 1100), priority: 0, server: nil,
                accountID: id)
        }
        await #expect(throws: ConnectionOptionsError.accountNotFound) {
            try await fixture.manager.setConnectionOptions(
                resource: "", priority: 0, server: nil, accountID: 999)
        }
        #expect(try fixture.database.account(id: id)?.resource == SessionServer.resource)
    }

    @Test(.timeLimit(.minutes(1)))
    func removingAPinReconnectsWithoutIt() async throws {
        let fixture = try await ManagerFixture()
        let id = try fixture.accountID
        var account = try #require(try fixture.database.account(id: id))
        account.pinnedCertSHA256 = ["AA", "BB"]
        try fixture.database.updateAccount(account)
        await fixture.manager.start()
        _ = try await fixture.onlineSession()

        try await fixture.manager.removePin("AA", accountID: id)

        #expect(try fixture.database.account(id: id)?.pinnedCertSHA256 == ["BB"])
        try await waitUntil("a new connection") { fixture.transports.value.count == 2 }
        await fixture.stop()
    }

    // MARK: Blocklist

    @Test(.timeLimit(.minutes(1)))
    func theBlocklistReachesTheBoardAndFollowsPushes() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            guard iq.type == "get", iq.child("blocklist", namespace: Blocking.namespace) != nil
            else { return nil }
            return [
                "<iq type='result' id='\(iq.id ?? "")'><blocklist xmlns='urn:xmpp:blocking'>"
                    + "<item jid='spam@x.test'/></blocklist></iq>"
            ]
        }
        try await harness.goOnline()
        let id = harness.accountID
        func shown() async -> Set<String>? {
            await MainActor.run { harness.board.blocklists[id] }
        }
        try await waitUntil("fetched") { await shown() == ["spam@x.test"] }

        try harness.deliver(
            "<iq type='set' id='p1'><block xmlns='urn:xmpp:blocking'>"
                + "<item jid='troll@x.test'/></block></iq>")
        try await waitUntil("pushed") { await shown() == ["spam@x.test", "troll@x.test"] }

        try await harness.session.unblock(try JID("spam@x.test"))
        try await waitUntil("unblocked") { await shown() == ["troll@x.test"] }

        try harness.deliver("<iq type='set' id='p2'><unblock xmlns='urn:xmpp:blocking'/></iq>")
        try await waitUntil("all unblocked") { await shown() == [] }
        await harness.stop()
    }

    // MARK: Archive preferences

    @Test(.timeLimit(.minutes(1)))
    func archivePreferencesAreReadAndSet() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            guard let prefs = iq.child("prefs", namespace: MAM.namespace) else { return nil }
            let result = "<iq type='result' id='\(iq.id ?? "")'>"
            if iq.type == "get" {
                return [
                    result + "<prefs xmlns='urn:xmpp:mam:2' default='roster'>"
                        + "<always><jid>a@x.test</jid></always><never/></prefs></iq>"
                ]
            }
            return [result + prefs.xml() + "</iq>"]
        }
        try await harness.goOnline()

        let read = try await harness.session.archivePreferences()
        #expect(read.default == .roster)
        #expect(read.always == [try JID("a@x.test")])

        let set = try await harness.session.setArchivePreferences(
            MAMPreferences(default: .never, always: [], never: [try JID("b@x.test")]))
        #expect(set.default == .never)
        #expect(set.never == [try JID("b@x.test")])
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func archivePreferencesNeedTheServersArchive() async throws {
        var options = SessionServer.Options()
        options.accountFeatures = []
        let harness = try await SessionHarness(options: options)
        try await harness.goOnline()
        await #expect(throws: SessionError.unavailable) {
            _ = try await harness.session.archivePreferences()
        }
        await harness.stop()
    }

    // MARK: Profile

    @Test(.timeLimit(.minutes(1)))
    func theOwnProfileIsPublishedKeptAndKeepsWhatItDoesNotShow() async throws {
        let harness = try await SessionHarness()
        let published = Locked<[Element]>([])
        harness.server.setResponder { iq in
            let pubsub = "http://jabber.org/protocol/pubsub"
            guard let request = iq.child("pubsub", namespace: pubsub) else { return nil }
            let result = "<iq type='result' id='\(iq.id ?? "")'"
            if iq.type == "get" {
                return [
                    result + "><pubsub xmlns='\(pubsub)'><items node='urn:xmpp:vcard4'>"
                        + "<item id='current'><vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>"
                        + "<fn><text>Alice</text></fn><org><text>ACME</text></org></vcard>"
                        + "</item></items></pubsub></iq>"
                ]
            }
            if let vcard = request.child("publish")?.child("item")?.elements.first {
                published.withLock { $0.append(vcard) }
            }
            return [result + "/>"]
        }
        try await harness.goOnline()

        let fields = try await harness.session.ownProfileFields()
        #expect(fields?.fullName == "Alice")
        var edited = try #require(fields)
        edited.fullName = "Alice Liddell"
        edited.email = "alice@example.test"
        edited.webPage = "https://example.test"
        try await harness.session.updateOwnProfile(edited, visibility: .contacts)

        let vcard = try #require(published.value.last)
        #expect(vcard.child("fn")?.child("text")?.text == "Alice Liddell")
        #expect(vcard.child("org")?.child("text")?.text == "ACME")
        #expect(vcard.child("email")?.child("text")?.text == "alice@example.test")
        let stored = try #require(try harness.database.ownProfile(accountID: harness.accountID))
        #expect(stored.fullName == "Alice Liddell")
        #expect(ProfileFields(stored: stored.data)?.webPage == "https://example.test")
        await harness.stop()
    }

    @Test func profileFieldsAreCheckedBeforeAnythingIsSent() {
        var fields = ProfileFields()
        fields.fullName = "  Alice  "
        fields.email = "not an address"
        fields.webPage = "javascript:alert(1)"
        fields.note = String(repeating: "n", count: ProfileFields.maxNote + 1)
        #expect(fields.normalized.fullName == "Alice")
        #expect(
            Set(fields.problems)
                == [.invalidEmail, .invalidWebPage, .tooLong(.note)])
        fields.email = "alice@example.test"
        fields.webPage = "https://example.test/~alice"
        fields.note = ""
        #expect(fields.problems.isEmpty)
    }
}

@Suite("AvatarCleanup")
struct AvatarCleanupTests {
    /// An avatar directory bound to `database` the way the media library is (R50).
    private struct Avatars {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AvatarCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)

        init() throws {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        static func hash(_ seed: String) -> String {
            XMPPCore.Avatars.sha1(Data(seed.utf8))
        }

        @discardableResult
        func file(_ hash: String, record database: AppDatabase? = nil) throws -> URL {
            let url = directory.appending(path: hash + ".png")
            try Data(hash.utf8).write(to: url)
            try database?.storeAvatar(
                AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: 40))
            return url
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func bind(_ database: AppDatabase) {
            MediaLibrary(directory: directory).bind(database: database)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func database() throws -> (AppDatabase, Int64) {
        let database = try AppDatabase.inMemory()
        let account = try database.addAccount(ManagerFixture.account())
        return (database, try #require(account.id))
    }

    @Test func aMatchedSweepRemovesOnlyFilesNothingNames() throws {
        let avatars = try Avatars()
        defer { avatars.cleanUp() }
        let (database, id) = try Self.database()
        let chat = Avatars.hash("chat")
        let roster = Avatars.hash("roster")
        let own = Avatars.hash("own")
        let unnamed = Avatars.hash("unnamed")
        let stray = Avatars.hash("stray")
        _ = try database.ensureChat(accountID: id, jid: "bob@example.test", kind: .direct)
        try database.replaceRoster(
            accountID: id,
            with: [
                RosterItemRecord(
                    accountID: id, jid: "carol@example.test", name: nil, subscription: "both",
                    ask: nil, approved: false, groups: [])
            ], version: nil)
        try database.showAvatar(accountID: id, jid: "bob@example.test", hash: chat, own: false)
        try database.showAvatar(
            accountID: id, jid: "carol@example.test", hash: roster, own: false)
        try database.showAvatar(accountID: id, jid: SessionServer.account, hash: own, own: true)
        let kept = try [chat, roster, own].map { try avatars.file($0, record: database) }
        let unnamedFile = try avatars.file(unnamed, record: database)
        let strayFile = try avatars.file(stray)
        let other = avatars.directory.appending(path: "notes.txt")
        try Data("x".utf8).write(to: other)
        avatars.bind(database)

        #expect(AvatarCleanup(directory: avatars.directory).sweep(database: database))

        #expect(kept.allSatisfy(avatars.exists))
        #expect(!avatars.exists(unnamedFile))
        #expect(!avatars.exists(strayFile))
        #expect(avatars.exists(other))
        #expect(try database.avatar(hash: unnamed) == nil)
    }

    @Test func anotherDatabasesDirectoryIsNeverSwept() throws {
        let avatars = try Avatars()
        defer { avatars.cleanUp() }
        let (database, _) = try Self.database()
        let (stranger, _) = try Self.database()
        let orphan = try avatars.file(Avatars.hash("orphan"))
        avatars.bind(database)

        #expect(!AvatarCleanup(directory: avatars.directory).sweep(database: stranger))
        #expect(avatars.exists(orphan))
        // A database that never had an account claims nothing either.
        let empty = try AppDatabase.inMemory()
        #expect(!AvatarCleanup(directory: avatars.directory).sweep(database: empty))
        #expect(avatars.exists(orphan))
    }

    @Test func anotherInstanceStopsTheSweep() throws {
        let avatars = try Avatars()
        defer { avatars.cleanUp() }
        let (database, _) = try Self.database()
        let orphan = try avatars.file(Avatars.hash("orphan"))
        avatars.bind(database)
        let lock = open(
            avatars.directory.appending(path: MediaLibrary.lockName).path, O_CREAT | O_RDWR,
            0o600)
        #expect(flock(lock, LOCK_SH | LOCK_NB) == 0)
        defer { close(lock) }

        #expect(!AvatarCleanup(directory: avatars.directory).sweep(database: database))
        #expect(avatars.exists(orphan))
    }

    @Test(.timeLimit(.minutes(1)))
    func removingAnAccountRemovesTheAvatarsOnlyItShowed() async throws {
        let fixture = try await ManagerFixture()
        let database = fixture.database
        let removed = try fixture.accountID
        let other = try #require(
            try database.addAccount(
                AccountRecord(
                    jid: "other@example.test", enabled: false, resource: "", clientID: "c",
                    hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                    pinnedCertSHA256: [], rosterVersion: nil, smResume: nil, createdAt: Date())
            ).id)
        let directory = fixture.manager.avatarDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let avatars = AvatarFiles(directory: directory)
        for (account, jid) in [
            (removed, "bob@example.test"), (removed, "dave@example.test"),
            (other, "bob@example.test"),
        ] {
            _ = try database.ensureChat(accountID: account, jid: jid, kind: .direct)
        }
        _ = try database.ensureChat(accountID: other, jid: "carol@example.test", kind: .direct)
        let onlyRemoved = Avatars.hash("only removed")
        let ownRemoved = Avatars.hash("own removed")
        let shared = Avatars.hash("shared")
        let otherOnly = Avatars.hash("other only")
        try database.showAvatar(
            accountID: removed, jid: "bob@example.test", hash: onlyRemoved, own: false)
        try database.showAvatar(
            accountID: removed, jid: SessionServer.account, hash: ownRemoved, own: true)
        try database.showAvatar(
            accountID: removed, jid: "dave@example.test", hash: shared, own: false)
        try database.showAvatar(accountID: other, jid: "bob@example.test", hash: shared, own: false)
        try database.showAvatar(
            accountID: other, jid: "carol@example.test", hash: otherOnly, own: false)
        let files = try [onlyRemoved, ownRemoved, shared, otherOnly].map {
            try avatars.write($0, database: database)
        }
        MediaLibrary(directory: directory).bind(database: database)

        try await fixture.manager.remove(accountID: removed)

        #expect(
            files.map { FileManager.default.fileExists(atPath: $0.path) } == [
                false, false, true, true,
            ])
    }

    @Test(.timeLimit(.minutes(1)))
    func theLaunchSweepsAvatarsBeforeAnySessionStarts() async throws {
        let fixture = try await ManagerFixture()
        let directory = fixture.manager.avatarDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = try AvatarFiles(directory: directory).write(
            Avatars.hash("orphan"), database: fixture.database)
        MediaLibrary(directory: directory).bind(database: fixture.database)

        await fixture.manager.start()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        await fixture.stop()
    }

    /// A cleanup that runs after an image's file is written and before its record names it
    /// takes the file; the store writes it again once it is named, so it is never lost.
    @Test func aCleanupBetweenWriteAndNameDoesNotLoseTheImage() async throws {
        let avatars = try Avatars()
        defer { avatars.cleanUp() }
        let (database, id) = try Self.database()
        avatars.bind(database)
        let cleanup = AvatarCleanup(directory: avatars.directory)
        let sync = AvatarSync(
            accountID: id, database: database, sender: FakeStanzaSender(),
            directory: avatars.directory, budget: 1_048_576,
            ownJID: try JID(SessionServer.account))
        let swept = Locked(false)
        await sync.setAfterFileWrite {
            swept.set(cleanup.sweep(database: database))
        }
        let image = Data("own avatar".utf8)
        let hash = XMPPCore.Avatars.sha1(image)

        try await sync.storeOwn(image, type: "image/png")

        #expect(swept.value)
        #expect(avatars.exists(avatars.directory.appending(path: hash + ".png")))
        #expect(try database.avatar(hash: hash) != nil)
        #expect(try database.ownProfile(accountID: id)?.avatarHash == hash)
    }
}

/// Avatar files written as `AvatarSync` names them, with their records.
private struct AvatarFiles {
    let directory: URL

    func write(_ hash: String, database: AppDatabase) throws -> URL {
        let url = directory.appending(path: hash + ".png")
        try Data(hash.utf8).write(to: url)
        try database.storeAvatar(AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: 40))
        return url
    }
}

@Suite("AvatarCrop")
struct AvatarCropTests {
    @Test func theCropIsTheLargestCentredSquareAtFirst() {
        let crop = AvatarCrop(imageSize: CGSize(width: 400, height: 300))
        #expect(crop.rect == CGRect(x: 50, y: 0, width: 300, height: 300))
    }

    @Test func zoomShrinksTheSquareAroundItsCentre() {
        var crop = AvatarCrop(imageSize: CGSize(width: 400, height: 300))
        crop.zoom = 2
        #expect(crop.rect == CGRect(x: 125, y: 75, width: 150, height: 150))
        crop.zoom = 99
        #expect(crop.zoom == AvatarCrop.maxZoom)
        crop.zoom = 0.1
        #expect(crop.zoom == 1)
    }

    @Test func panningStopsAtTheImagesEdges() {
        var crop = AvatarCrop(imageSize: CGSize(width: 400, height: 300))
        crop.zoom = 2
        // Dragging the picture right by a whole viewport moves the square left past the edge.
        crop.pan(byViewportPoints: CGSize(width: 200, height: 0), viewportSide: 200)
        #expect(crop.rect.minX == 0)
        crop.pan(byViewportPoints: CGSize(width: -10_000, height: -10_000), viewportSide: 200)
        #expect(crop.rect.maxX == 400)
        #expect(crop.rect.maxY == 300)
    }

    @Test func theRenderedCropIsASquarePNG() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        var crop = AvatarCrop(imageSize: CGSize(width: 400, height: 300))
        crop.zoom = 1.5

        let png = try #require(AvatarCrop.render(image, crop: crop))

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(rendered.width == rendered.height)
        #expect(rendered.width == 200)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}
