import Darwin
import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// R50: the launch sweep never touches a library its database does not own, matches files
/// by their hash name only, and runs only while this process holds the library.
@Suite struct LibrarySweepTests {
    /// A library with files, in a directory of its own.
    struct Library {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySweep-\(UUID().uuidString)")
        var library: MediaLibrary { MediaLibrary(directory: directory) }

        func store(_ text: String) throws -> URL {
            try library.store(Data(text.utf8)).url
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }

        var marker: URL { directory.appending(path: MediaLibrary.markerName) }

        func markerText() -> String? {
            try? String(contentsOf: marker, encoding: .utf8)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A database with one account whose attachments name `paths`.
    static func database(naming paths: [String]) throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        let account = try #require(
            try database.addAccount(
                AccountRecord(
                    jid: "alice@example.test", enabled: false, resource: "res",
                    clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
                    directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil,
                    smResume: nil, createdAt: Date())
            ).id)
        let chat = try database.ensureChat(
            accountID: account, jid: "carol@example.test", kind: .direct)
        try database.upsertIncoming(
            IncomingMessage(
                accountID: account, chatID: try #require(chat.id),
                senderJID: "carol@example.test/phone", body: nil, archiveID: "a1",
                timestamp: Date(), kind: .file,
                attachments: paths.map {
                    AttachmentDraft(
                        remoteURL: "https://files.example.test/x", localPath: $0, state: .local)
                }))
        return database
    }

    /// N19: an empty database (a test launch's, in memory) never empties a library.
    @Test func anEmptyDatabaseDeletesNothing() throws {
        let files = Library()
        defer { files.cleanUp() }
        let first = try files.store("sent last year")
        let second = try files.store("received today")

        files.library.sweepOrphans(database: try AppDatabase.inMemory())
        files.library.sweepOrphans(database: try AppDatabase.inMemory())

        #expect(files.exists(first))
        #expect(files.exists(second))
        #expect(!files.exists(files.marker), "an empty database claims no library")
    }

    /// N19: a library bound to another database is not swept by this one.
    @Test func aMismatchedLibraryIDDeletesNothing() throws {
        let files = Library()
        defer { files.cleanUp() }
        let named = try files.store("named by the owner")
        let owner = try Self.database(naming: [named.path])
        #expect(files.library.bind(database: owner) == .created)
        let orphan = try files.store("named by nobody")
        let stranger = try Self.database(naming: [])
        try stranger.claimMediaLibraryID(UUID().uuidString)

        files.library.sweepOrphans(database: stranger)

        #expect(files.exists(named))
        #expect(files.exists(orphan))
    }

    /// N19: bound and matched, the sweep removes only what no row names; the first launch
    /// only binds.
    @Test func aMatchedLibrarySweepsOnlyOrphans() throws {
        let files = Library()
        defer { files.cleanUp() }
        let named = try files.store("kept")
        let database = try Self.database(naming: [named.path])
        let orphan = try files.store("named by nobody")

        files.library.sweepOrphans(database: database)
        #expect(files.exists(orphan), "the first launch binds, it does not sweep")
        files.library.sweepOrphans(database: database)

        #expect(files.exists(named))
        #expect(!files.exists(orphan))
        #expect(try database.mediaLibraryID() != nil)
    }

    /// N20: rows that name a file under another spelling of the directory (a renamed home, a
    /// migrated Mac) still keep it: files are matched by their hash name.
    @Test func rowsMatchByFileNameWhereverTheLibraryWas() throws {
        let files = Library()
        defer { files.cleanUp() }
        let file = try files.store("moved with the home folder")
        let database = try Self.database(
            naming: ["/Users/someone-else/Library/Containers/old/Media/\(file.lastPathComponent)"])
        #expect(files.library.bind(database: database) == .created)

        files.library.sweepOrphans(database: database)

        #expect(files.exists(file))
    }

    /// N21: while another instance runs (it holds the library shared), this one does not
    /// sweep it. An instance holding it exclusively is sweeping: see
    /// `aLaunchDuringAnotherSweepWaitsAndThenHoldsTheLibrary`.
    @Test func anotherRunningInstanceStopsTheSweep() throws {
        let files = Library()
        defer { files.cleanUp() }
        let database = try Self.database(naming: [])
        let orphan = try files.store("in use elsewhere")
        #expect(files.library.bind(database: database) == .created)
        let lock = open(
            files.directory.appending(path: MediaLibrary.lockName).path, O_CREAT | O_RDWR, 0o600)
        #expect(lock >= 0)
        #expect(flock(lock, LOCK_SH | LOCK_NB) == 0)
        defer { close(lock) }

        files.library.sweepOrphans(database: database)

        #expect(files.exists(orphan))
    }

    /// N21: after its sweep, this process keeps the library for its lifetime: another
    /// instance started now finds it held and does not sweep under this one's transfers.
    @Test func aSweptLibraryStaysHeld() throws {
        let files = Library()
        defer { files.cleanUp() }
        let database = try Self.database(naming: [])
        files.library.sweepOrphans(database: database)

        let lock = open(
            files.directory.appending(path: MediaLibrary.lockName).path, O_CREAT | O_RDWR, 0o600)
        #expect(lock >= 0)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) != 0)
    }

    /// N20: deleting a message keeps a file a row written under the old directory still
    /// names.
    @Test func aDeletionKeepsAFileNamedUnderAnotherDirectory() throws {
        let files = Library()
        defer { files.cleanUp() }
        let file = try files.store("sent before the move")
        let database = try Self.database(
            naming: ["/Users/someone-else/Library/Containers/old/Media/\(file.lastPathComponent)"])

        files.library.deleteUnused([file.path], database: database)

        #expect(files.exists(file))
    }

    /// N20: removing an account keeps a file another account's row names under the old
    /// directory.
    @Test func anAccountRemovalKeepsAFileAnotherAccountNamesElsewhere() throws {
        let files = Library()
        defer { files.cleanUp() }
        let file = try files.store("the same photo, both accounts")
        let database = try Self.database(naming: [file.path])
        let other = try #require(
            try database.addAccount(
                AccountMediaRemovalTests.TwoAccounts.account("bob@example.test")
            ).id)
        try AccountMediaRemovalTests.TwoAccounts.file(
            database, accountID: other,
            paths: [URL(fileURLWithPath: "/Users/old/Media/\(file.lastPathComponent)")])
        let first = try #require(try database.accounts().first?.id)

        files.library.removeAll(accountID: first, database: database)

        #expect(files.exists(file))
    }

    /// N22: when what the rows name cannot be read, nothing is deleted.
    @Test func aFailedReadDeletesNothing() throws {
        struct Unreadable: Error {}
        let files = Library()
        defer { files.cleanUp() }
        let file = try files.store("named, perhaps")

        files.library.removeOrphans { throw Unreadable() }

        #expect(files.exists(file))
    }

    /// N19, the whole launch: a manager over an empty database leaves an existing library
    /// alone.
    @Test func aLaunchOverAnEmptyDatabaseLeavesTheLibraryAlone() async throws {
        let files = Library()
        defer { files.cleanUp() }
        let file = try files.store("the user's photo")
        var environment = SessionHarness.environment(
            server: SessionServer(), clock: TestClock(), transports: Locked([]))
        environment.media = MediaEnvironment(
            directory: files.directory, transport: FakeMediaTransport(), bytestreams: nil)
        let board = await MainActor.run { StatusBoard() }
        let manager = SessionManager(
            database: try AppDatabase.inMemory(), credentials: TestCredentials(),
            systemEvents: FakeSystemEvents(), environment: environment, status: board,
            notifications: RecordingSink())

        await manager.start()

        #expect(files.exists(file))
        await manager.stop()
    }
}

// MARK: - Task 13c

/// Holds the launch sweep until opened.
final class SweepHold: Sendable {
    let entered = Locked(false)
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        entered.set(true)
        for await _ in stream { return }
    }

    func open() {
        continuation.finish()
    }
}

extension LibrarySweepTests {
    // MARK: N24

    /// A database that never wrote its rows into a library (a new one, with an account)
    /// never claims a library another database marked, and sweeps nothing in it.
    @Test func aFreshDatabaseNeverClaimsAMarkedLibrary() throws {
        let files = Library()
        defer { files.cleanUp() }
        let owner = try Self.database(naming: [])
        #expect(files.library.bind(database: owner) == .created)
        let marked = files.markerText()
        let orphan = try files.store("the owner's")
        let fresh = try Self.database(naming: [])

        files.library.sweepOrphans(database: fresh)
        files.library.sweepOrphans(database: fresh)

        #expect(files.exists(orphan))
        #expect(try fresh.mediaLibraryID() == nil)
        #expect(files.markerText() == marked)
    }

    // MARK: N25

    /// The database kept its id but the marker was never written (a full disk, a crash in
    /// between): the next launch writes it, and the one after sweeps.
    @Test func aMarkerThatWasNeverWrittenIsWrittenAtTheNextLaunch() throws {
        let files = Library()
        defer { files.cleanUp() }
        let database = try Self.database(naming: [])
        try database.claimMediaLibraryID("kept-by-the-database")
        let orphan = try files.store("left by a crash")

        files.library.sweepOrphans(database: database)
        #expect(files.markerText() == "kept-by-the-database")
        #expect(files.exists(orphan), "the launch that writes the marker sweeps nothing")

        files.library.sweepOrphans(database: database)
        #expect(!files.exists(orphan))
    }

    /// A marker that is there but cannot be read is never replaced.
    @Test func anUnreadableMarkerIsNeverReplaced() throws {
        let files = Library()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: files.marker.path)
            files.cleanUp()
        }
        #expect(files.library.bind(database: try Self.database(naming: [])) == .created)
        let marked = files.markerText()
        let orphan = try files.store("someone's")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: files.marker.path)
        let database = try Self.database(naming: [])

        files.library.sweepOrphans(database: database)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: files.marker.path)
        #expect(files.markerText() == marked)
        #expect(try database.mediaLibraryID() == nil)
        #expect(files.exists(orphan))
    }

    // MARK: N23

    /// An instance launched while another sweeps waits for that sweep, then holds the
    /// library for as long as it runs: a later launch cannot sweep under it.
    @Test func aLaunchDuringAnotherSweepWaitsAndThenHoldsTheLibrary() async throws {
        let files = Library()
        defer { files.cleanUp() }
        try files.library.prepare()
        let other = open(
            files.directory.appending(path: MediaLibrary.lockName).path, O_CREAT | O_RDWR, 0o600)
        #expect(other >= 0)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0, "the other instance sweeps")
        #expect(!files.library.holdExclusively())

        let library = files.library
        let holding = Task.detached { library.holdShared() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(flock(other, LOCK_UN) == 0, "its sweep ends")
        await holding.value

        #expect(flock(other, LOCK_EX | LOCK_NB) != 0, "this instance holds the library now")
    }

    // MARK: F1

    /// A row written before the home folder or the container moved, naming the file under
    /// the old directory.
    static func movedPath(of file: URL) -> String {
        "/Users/someone-else/Library/Containers/old/Data/Library/Application Support/Xippi/"
            + "Media/\(file.lastPathComponent)"
    }

    /// After a move, every reader finds the file by its name in the current library: the
    /// resolver, a download (no request, nothing forgotten) and the sweep.
    @Test func aMovedLibraryStillServesItsRows() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(300)
        let stored = try rig.media.library.store(bytes).url
        let file = try rig.media.incomingFile(DownloadServiceTests.link)
        let moved = Self.movedPath(of: stored)
        #expect(try rig.media.database.beginAttachmentDownload(id: file.attachment))
        try rig.media.database.finishAttachmentDownload(
            id: file.attachment, localPath: moved, byteSize: 300, mimeType: nil,
            sniffedMimeType: nil)

        #expect(rig.media.library.existingFile(for: moved) == stored)
        let downloaded = try await rig.service.download(attachmentID: file.attachment)

        #expect(downloaded == stored)
        #expect(rig.media.transport.requests.isEmpty)
        #expect(try rig.attachment(file.attachment).localPath == moved)
        #expect(try rig.attachment(file.attachment).state == .local)
        #expect(rig.media.library.bind(database: rig.media.database) == .created)
        rig.media.library.sweepOrphans(database: rig.media.database)
        #expect(try Data(contentsOf: stored) == bytes)
    }

    /// A row whose file is gone from the old directory and the current one is fetched again.
    @Test func aMovedRowWhoseFileIsGoneIsFetchedAgain() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(200)
        rig.media.transport.serve(DownloadServiceTests.url, data: bytes)
        let file = try rig.media.incomingFile(DownloadServiceTests.link)
        let hash = MediaRig.sha256Hex(bytes)
        #expect(try rig.media.database.beginAttachmentDownload(id: file.attachment))
        try rig.media.database.finishAttachmentDownload(
            id: file.attachment, localPath: "/Users/someone-else/Media/\(hash)", byteSize: 200,
            mimeType: nil, sniffedMimeType: nil)

        let downloaded = try await rig.service.download(attachmentID: file.attachment)

        #expect(try Data(contentsOf: downloaded) == bytes)
        #expect(rig.media.transport.requests.count == 1)
    }

    /// A file we sent before the move still goes out again with its hash.
    @Test func aMovedSentFileKeepsItsHash() async throws {
        let media = try MediaRig()
        defer { media.cleanUp() }
        let environment = MediaEnvironment(
            directory: media.library.directory, transport: media.transport, bytestreams: nil)
        let harness = try await SessionHarness(media: environment) { database, accountID in
            _ = try database.ensureChat(
                accountID: accountID, jid: SessionFilesTests.bob, kind: .direct)
        }
        let chat = try #require(try harness.chat(SessionFilesTests.bob))
        let bytes = Data("sent before the move".utf8)
        let stored = try media.library.store(bytes)
        let link = "https://files.example.test/up/notes.txt"
        let id = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: chat.accountID, chatID: try #require(chat.id), originID: "o-moved",
                senderJID: SessionServer.fullJID, body: link, timestamp: Date(), kind: .file,
                attachments: [
                    AttachmentDraft(
                        remoteURL: link, localPath: Self.movedPath(of: stored.url),
                        mimeType: "text/plain", byteSize: Int64(bytes.count),
                        fileName: "notes.txt", state: .local)
                ]))
        let record = try #require(try harness.database.message(id: id))

        let element = try #require(await harness.session.rebuiltFileElement(for: record, in: chat))

        let sharing = try #require(
            element.child("file-sharing", namespace: StatelessFileSharing.namespace).flatMap(
                StatelessFileSharing.parse))
        #expect(sharing.file.hashes.map(\.algorithm) == ["sha-256"])
        #expect(sharing.file.hashes.first?.value == stored.sha256)
        await harness.stop()
    }

    // MARK: X1

    enum Ask: CaseIterable, Sendable {
        case add, enable
    }

    /// A manager whose launch sweep waits for `hold`, over a library bound to its database.
    struct HeldLaunch {
        let files = Library()
        let hold = SweepHold()
        let database: AppDatabase
        let manager: SessionManager
        /// The disabled account already there.
        let existing: Int64

        init(existingJID: String) async throws {
            database = try AppDatabase.inMemory()
            var account = ManagerFixture.account(enabled: false)
            account.jid = existingJID
            existing = try #require(try database.addAccount(account).id)
            #expect(files.library.bind(database: database) == .created)
            var environment = SessionHarness.environment(
                server: SessionServer(), clock: TestClock(), transports: Locked([]))
            environment.media = MediaEnvironment(
                directory: files.directory, transport: FakeMediaTransport(), bytestreams: nil)
            let board = await MainActor.run { StatusBoard() }
            manager = SessionManager(
                database: database, credentials: TestCredentials(),
                systemEvents: FakeSystemEvents(), environment: environment, status: board,
                notifications: RecordingSink())
            let hold = hold
            await manager.replaceLaunchSweep { directory, database in
                await hold.wait()
                MediaLibrary(directory: directory).sweepOrphans(database: database)
            }
        }
    }

    /// X1: a session asked for while the launch sweep runs starts after it, so nothing it
    /// begins (a download's temporary file) is swept.
    @Test(arguments: Ask.allCases)
    func aSessionAskedForDuringTheLaunchSweepStartsAfterIt(ask: Ask) async throws {
        let launch = try await HeldLaunch(
            existingJID: ask == .enable ? SessionServer.account : "carol@example.test")
        defer { launch.files.cleanUp() }
        let manager = launch.manager
        let starting = Task { await manager.start() }
        try await waitUntil("sweep running") { launch.hold.entered.value }

        let asked = Task {
            switch ask {
            case .add:
                _ = try await manager.add(account: ManagerFixture.account())
            case .enable:
                try await manager.setEnabled(true, accountID: launch.existing)
            }
        }
        // What the session begins as soon as it exists: a download's temporary file.
        let directory = launch.files.directory
        let begun = Task { () -> URL? in
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if await !manager.activeSessions.isEmpty {
                    return try? MediaLibrary(directory: directory, accountID: nil).temporaryFile()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.activeSessions.isEmpty, "no session while the sweep runs")

        launch.hold.open()
        try await asked.value
        await starting.value

        let temporary = try #require(await begun.value)
        #expect(launch.files.exists(temporary))
        #expect(await manager.activeSessions.count == 1)
        await manager.stop()
    }

    /// X1: a removal and a quit during the launch sweep do not wait for it, and nothing
    /// starts once it ends.
    @Test func aQuitOrARemovalDuringTheLaunchSweepDoesNotWaitForIt() async throws {
        let launch = try await HeldLaunch(existingJID: SessionServer.account)
        defer { launch.files.cleanUp() }
        let manager = launch.manager
        let starting = Task { await manager.start() }
        try await waitUntil("sweep running") { launch.hold.entered.value }

        let removed = Locked(false)
        let removal = Task {
            try await manager.remove(accountID: launch.existing)
            removed.set(true)
        }
        try await waitUntil("removed during the sweep") { removed.value }
        try await removal.value
        let stopped = Locked(false)
        Task {
            await manager.stop()
            stopped.set(true)
        }
        try await waitUntil("stopped during the sweep") { stopped.value }

        launch.hold.open()
        await starting.value
        #expect(await manager.activeSessions.isEmpty)
        #expect(try launch.database.account(id: launch.existing) == nil)
    }
}
