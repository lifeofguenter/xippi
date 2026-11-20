import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// Removing an account removes what it left in the media library, and nothing another
/// account still shows.
@Suite struct AccountMediaRemovalTests {
    /// Two accounts on one database and one library: both show the shared file, only the
    /// first shows its own.
    struct TwoAccounts {
        let database: AppDatabase
        let first: Int64
        let second: Int64
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountMedia-\(UUID().uuidString)")
        let shared: URL
        let own: URL

        var library: MediaLibrary { MediaLibrary(directory: directory) }

        init(database: AppDatabase) throws {
            self.database = database
            let first = try #require(try database.addAccount(Self.account("alice@example.test")).id)
            let second = try #require(try database.addAccount(Self.account("bob@example.test")).id)
            self.first = first
            self.second = second
            let library = MediaLibrary(directory: directory)
            shared = try library.store(Data("the same photo".utf8)).url
            own = try library.store(Data("only alice has this".utf8)).url
            try Self.file(database, accountID: first, paths: [shared, own])
            try Self.file(database, accountID: second, paths: [shared])
        }

        static func account(_ jid: String) -> AccountRecord {
            AccountRecord(
                jid: jid, enabled: false, resource: "res", clientID: UUID().uuidString,
                hostOverride: nil, portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                rosterVersion: nil, smResume: nil, createdAt: Date())
        }

        static func file(_ database: AppDatabase, accountID: Int64, paths: [URL]) throws {
            let chat = try database.ensureChat(
                accountID: accountID, jid: "carol@example.test", kind: .direct)
            try database.upsertIncoming(
                IncomingMessage(
                    accountID: accountID, chatID: try #require(chat.id),
                    senderJID: "carol@example.test/phone", body: nil,
                    archiveID: UUID().uuidString, timestamp: Date(), kind: .file,
                    attachments: paths.map {
                        AttachmentDraft(
                            remoteURL: "https://files.example.test/\($0.lastPathComponent)",
                            localPath: $0.path, state: .local)
                    }))
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func removingAnAccountsMediaKeepsWhatAnotherAccountShows() throws {
        let accounts = try TwoAccounts(database: try AppDatabase.inMemory())
        defer { accounts.cleanUp() }
        let firstTemporary = try MediaLibrary(
            directory: accounts.directory, accountID: accounts.first
        ).temporaryFile()
        let secondTemporary = try MediaLibrary(
            directory: accounts.directory, accountID: accounts.second
        ).temporaryFile()

        accounts.library.removeAll(accountID: accounts.first, database: accounts.database)

        #expect(!accounts.exists(accounts.own))
        #expect(accounts.exists(accounts.shared))
        #expect(!accounts.exists(firstTemporary))
        #expect(accounts.exists(secondTemporary))
    }

    @Test func removingAnAccountThroughTheManagerClearsItsMedia() async throws {
        let database = try AppDatabase.inMemory()
        let accounts = try TwoAccounts(database: database)
        defer { accounts.cleanUp() }
        var environment = SessionHarness.environment(
            server: SessionServer(), clock: TestClock(), transports: Locked([]))
        environment.media = MediaEnvironment(
            directory: accounts.directory, transport: FakeMediaTransport(), bytestreams: nil)
        let board = await MainActor.run { StatusBoard() }
        let manager = SessionManager(
            database: database, credentials: TestCredentials(), systemEvents: FakeSystemEvents(),
            environment: environment, status: board, notifications: RecordingSink())

        try await manager.remove(accountID: accounts.first)

        #expect(!accounts.exists(accounts.own))
        #expect(accounts.exists(accounts.shared))
        #expect(try database.accounts().map(\.id) == [accounts.second])
    }
}

// MARK: - Fix round 4 (N16)

extension AccountMediaRemovalTests {
    /// At launch, nothing is moving: a library file no row names goes, and so does every
    /// temporary file; a file a row names stays. The library was bound to its database at an
    /// earlier launch (R50).
    @Test func theLaunchSweepRemovesFilesNoRowNames() throws {
        let accounts = try TwoAccounts(database: try AppDatabase.inMemory())
        defer { accounts.cleanUp() }
        #expect(accounts.library.bind(database: accounts.database) == .created)
        let orphan = try accounts.library.store(Data("nobody shows this".utf8)).url
        let temporary = try MediaLibrary(
            directory: accounts.directory, accountID: accounts.second
        ).temporaryFile()

        accounts.library.sweepOrphans(database: accounts.database)

        #expect(!accounts.exists(orphan))
        #expect(!accounts.exists(temporary))
        #expect(accounts.exists(accounts.shared))
        #expect(accounts.exists(accounts.own))
    }

    /// A file the removal could not delete is not left for ever: the next launch takes it.
    @Test func aFileTheRemovalCouldNotDeleteGoesAtTheNextLaunch() throws {
        let accounts = try TwoAccounts(database: try AppDatabase.inMemory())
        #expect(accounts.library.bind(database: accounts.database) == .created)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: accounts.directory.path)
            accounts.cleanUp()
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: accounts.directory.path)

        accounts.library.removeAll(accountID: accounts.first, database: accounts.database)
        try accounts.database.removeAccount(id: accounts.first)
        #expect(accounts.exists(accounts.own))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: accounts.directory.path)
        accounts.library.sweepOrphans(database: accounts.database)

        #expect(!accounts.exists(accounts.own))
        #expect(accounts.exists(accounts.shared))
    }

    /// The sweep runs when the app starts its sessions, on the library its database owns.
    @Test func startingTheManagerSweepsTheLibrary() async throws {
        let database = try AppDatabase.inMemory()
        let accounts = try TwoAccounts(database: database)
        defer { accounts.cleanUp() }
        #expect(accounts.library.bind(database: database) == .created)
        let orphan = try accounts.library.store(Data("left by a crash".utf8)).url
        var environment = SessionHarness.environment(
            server: SessionServer(), clock: TestClock(), transports: Locked([]))
        environment.media = MediaEnvironment(
            directory: accounts.directory, transport: FakeMediaTransport(), bytestreams: nil)
        let board = await MainActor.run { StatusBoard() }
        let manager = SessionManager(
            database: database, credentials: TestCredentials(), systemEvents: FakeSystemEvents(),
            environment: environment, status: board, notifications: RecordingSink())

        await manager.start()

        #expect(!accounts.exists(orphan))
        #expect(accounts.exists(accounts.shared))
        await manager.stop()
    }
}
