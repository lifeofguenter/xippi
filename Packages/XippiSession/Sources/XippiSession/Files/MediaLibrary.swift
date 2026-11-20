import CryptoKit
import Foundation
import Synchronization
import UniformTypeIdentifiers
import XMPPCore
import XippiStore
import os

/// Where files sent and received are kept: `Application Support/Xippi/Media`, one file per
/// content, named by its SHA-256 in hex. The same file sent or received twice is kept once.
///
/// Files arrive under a temporary name in the same directory and are renamed into place once
/// complete, so a file under a hash name is always whole. A file is deleted only when no
/// attachment row names it any more, and only inside this directory: a path from the
/// database never reaches anything else.
public struct MediaLibrary: Sendable {
    public let directory: URL

    static let partialPrefix = ".partial-"
    static let lockName = ".library-lock"
    static let markerName = ".library-id"
    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// The account whose temporary files this instance writes; nil for none in particular.
    public let accountID: Int64?

    public init(directory: URL, accountID: Int64? = nil) {
        self.directory = directory.standardizedFileURL
        self.accountID = accountID
    }

    /// Removes what an account leaves in the library, for when the account is removed: after
    /// its session stopped and before its rows go. The files only its attachments name go,
    /// and its temporary files; a file another account's rows name stays, since the same
    /// content is kept once.
    public func removeAll(accountID: Int64, database: AppDatabase) {
        do {
            for name in try database.attachmentFileNamesOnlyOf(accountID: accountID)
            where Self.hash(named: name) != nil {
                try? FileManager.default.removeItem(at: file(named: name))
            }
        } catch {
            Self.log.error("Account media not read")
        }
        let prefix = Self.partialPrefix(for: accountID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// At launch, before any transfer runs: removes every temporary file, and every file
    /// under a hash name that no attachment row names (left by a crash, or by a removal that
    /// could not delete it). Nothing is left for ever.
    ///
    /// Only for a library this database owns, and only while no other instance has it open
    /// (R50): the two must carry the same id, and this process must hold the library's lock
    /// exclusively. Otherwise nothing is removed. Either way the process keeps a shared hold
    /// on the library afterwards, for as long as it runs, so another instance launched
    /// meanwhile never sweeps under this one's transfers.
    public func sweepOrphans(database: AppDatabase) {
        try? prepare()
        defer { holdShared() }
        guard holdExclusively() else {
            Self.log.notice("Media not swept: library in use")
            return
        }
        guard bind(database: database) == .matched else { return }
        removeOrphans { try database.attachmentFileNames() }
    }

    /// How a library and a database stand to each other.
    enum Binding {
        /// Neither had an id; both have the same new one now. Nothing is swept this time: no
        /// row was written against the id yet.
        case created
        case matched
        /// Different ids, or only one side has one: another database's library, or a test
        /// launch's database. Never swept.
        case unmatched
    }

    /// Ties the library to `database` by an id both keep: the library in `.library-id`, the
    /// database in its settings row. Both are made together, the first time neither has one
    /// and the database has an account, so a test launch's empty database never claims a
    /// library.
    @discardableResult
    func bind(database: AppDatabase) -> Binding {
        let marker = file(named: Self.markerName)
        let stored: String?
        let hasAccounts: Bool
        do {
            stored = try database.mediaLibraryID()
            hasAccounts = try !database.accounts().isEmpty
        } catch {
            Self.log.error("Media not swept: library id not read")
            return .unmatched
        }
        let found: String?
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
                Self.log.error("Media not swept: library id not readable")
                return .unmatched
            }
            found = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            found = nil
        }
        switch (stored, found) {
        case (let stored?, let found?) where stored == found:
            return .matched
        case (_, nil) where hasAccounts:
            // The first launch with an account, or one after the marker could not be
            // written: the database's id, or a new one it keeps, goes into the marker.
            do {
                try prepare()
                let id = try stored ?? database.claimMediaLibraryID(UUID().uuidString)
                try Data(id.utf8).write(to: marker, options: .atomic)
                if stored != nil { Self.log.notice("Media library id written again") }
                return .created
            } catch {
                Self.log.error("Media not swept: library id not written, trying at next launch")
                return .unmatched
            }
        case (nil, nil):
            return .unmatched
        default:
            Self.log.notice("Media not swept: library of another database")
            return .unmatched
        }
    }

    /// Removes every temporary file and every hash-named file whose name `named` does not
    /// return. Rows are matched by file name, never by path, so rows written under another
    /// spelling of the directory (a renamed home folder, a migrated Mac) keep their files.
    /// When `named` throws, nothing is removed.
    func removeOrphans(keeping named: () throws -> Set<String>) {
        let kept: Set<String>
        do {
            kept = try named()
        } catch {
            Self.log.error("Media not swept")
            return
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names
        where name.hasPrefix(Self.partialPrefix)
            || (Self.hash(named: name) != nil && !kept.contains(name))
        {
            try? FileManager.default.removeItem(at: file(named: name))
        }
    }

    // MARK: The process's hold on the library

    /// The open lock file of each library this process holds, by directory. Never closed:
    /// the hold lasts as long as the process.
    private static let holds = Mutex<[String: Int32]>([:])

    /// Takes the library's lock exclusively, without waiting: true only while no other
    /// process holds it in any mode.
    func holdExclusively() -> Bool {
        Self.holds.withLock { holds in
            guard let descriptor = lockDescriptor(&holds) else { return false }
            return flock(descriptor, LOCK_EX | LOCK_NB) == 0
        }
    }

    /// Holds the library's lock shared, for the rest of the process's life. An exclusive hold
    /// becomes shared (a failed attempt at an exclusive one may have dropped it). Waits while
    /// another instance sweeps (holds it exclusively), so an instance launched during a sweep
    /// still holds the library once that sweep is over.
    func holdShared() {
        // Descriptors are never closed, so one is safe to use outside the registry's lock;
        // the wait must not hold that lock.
        guard let descriptor = Self.holds.withLock({ lockDescriptor(&$0) }) else {
            Self.log.notice("Media library not held")
            return
        }
        while flock(descriptor, LOCK_SH) != 0 {
            guard errno == EINTR else {
                Self.log.notice("Media library not held")
                return
            }
        }
    }

    /// The library's lock file, opened once per process.
    private func lockDescriptor(_ holds: inout [String: Int32]) -> Int32? {
        if let descriptor = holds[directory.path] { return descriptor }
        let descriptor = open(file(named: Self.lockName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        holds[directory.path] = descriptor
        return descriptor
    }

    /// The file a row's `localPath` names, where it is now; nil when it is not there. A
    /// library file is found by its hash name in this library, since the home folder or the
    /// container may have moved since the row was written; failing that, and for any other
    /// file, at the path itself.
    public func existingFile(for localPath: String) -> URL? {
        let stored = URL(fileURLWithPath: localPath)
        let name = stored.lastPathComponent
        if Self.hash(named: name) != nil {
            let current = file(named: name)
            if FileManager.default.fileExists(atPath: current.path) { return current }
        }
        return FileManager.default.fileExists(atPath: localPath) ? stored : nil
    }

    /// Removes this instance's account's temporary files.
    func removeTemporaryFiles() {
        guard let accountID else { return }
        let prefix = Self.partialPrefix(for: accountID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Temporary files of an account's transfers start with this.
    static func partialPrefix(for accountID: Int64) -> String {
        partialPrefix + "\(accountID)-"
    }

    /// `Application Support/Xippi/Media` of this user (inside the sandbox container).
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true
        )
        .appending(path: "Xippi", directoryHint: .isDirectory)
        .appending(path: "Media", directoryHint: .isDirectory)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The file for content with this SHA-256.
    func url(forHash hash: Data) -> URL {
        directory.appending(path: Self.hex(hash), directoryHint: .notDirectory)
    }

    /// A new, empty temporary file in the library, for content on its way in.
    func temporaryFile() throws -> URL {
        try prepare()
        let prefix = accountID.map(Self.partialPrefix(for:)) ?? Self.partialPrefix
        let url = directory.appending(
            path: prefix + UUID().uuidString, directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Puts a complete temporary file in place under its hash. When the same content is there
    /// already, the temporary file goes and the existing one stays.
    func adopt(_ temporary: URL, sha256: Data) throws -> URL {
        let target = url(forHash: sha256)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: temporary)
            return target
        }
        do {
            // A rename within one directory: the file appears whole or not at all.
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            guard FileManager.default.fileExists(atPath: target.path) else {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            // Another transfer of the same content got there first.
            try? FileManager.default.removeItem(at: temporary)
        }
        return target
    }

    /// Writes `data` into the library under its hash.
    func store(_ data: Data) throws -> (url: URL, sha256: Data) {
        let hash = Data(SHA256.hash(data: data))
        let temporary = try temporaryFile()
        do {
            try data.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return (try adopt(temporary, sha256: hash), hash)
    }

    /// Copies a file the user picked into the library, hashing it on the way, so the
    /// attachment never points at (and a retraction never deletes) the user's own file.
    func importFile(_ source: URL) throws -> (url: URL, sha256: Data, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let temporary = try temporaryFile()
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 16), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                size += Int64(chunk.count)
            }
            let hash = Data(hasher.finalize())
            try output.close()
            return (try adopt(temporary, sha256: hash), hash, size)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Whether `path` is a file of this library (not the directory, nothing outside it).
    func contains(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return file.deletingLastPathComponent().path == directory.path
            && !file.lastPathComponent.isEmpty
    }

    /// The library file named `name`; only ever inside the library.
    func file(named name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// Deletes the library files `paths` name (by file name, wherever the rows say the
    /// library was) that no attachment row names any more.
    func deleteUnused(_ paths: [String], database: AppDatabase) {
        let names = Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent })
        for name in names where Self.hash(named: name) != nil {
            do {
                guard try !database.isAttachmentFileNameInUse(name) else { continue }
                try FileManager.default.removeItem(at: file(named: name))
            } catch {
                Self.log.notice("Media file not deleted")
            }
        }
    }

    /// Removes temporary files a quit or a crash left behind: those untouched for a day, so
    /// another account's transfer running now keeps its file.
    func removeLeftovers(olderThan age: TimeInterval = 86_400) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for name in names where name.hasPrefix(Self.partialPrefix) {
            let url = directory.appending(path: name)
            let modified =
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date
            if let modified, modified > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Names and types

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 a library file's name spells (64 hex digits); nil for any other name.
    static func hash(named name: String) -> Data? {
        let digits = Array(name.utf8)
        guard digits.count == 64 else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
            default: nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for index in stride(from: 0, to: 64, by: 2) {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        return Data(bytes)
    }

    /// A name a peer sent, safe to show and to use as a file name (XEP-0446 rules: the last
    /// path component, no control, format or line characters, no leading dots, at most 200
    /// characters). Nil without a name.
    static func safeName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return FileMetadata(name: raw).safeName
    }

    /// A declared media type as stored: `type/subtype` in lowercase, parameters dropped; nil
    /// when it is not one.
    static func mediaType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = (raw.split(separator: ";").first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-")
        guard parts.count == 2, value.count <= 127,
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed.contains) })
        else { return nil }
        return value
    }

    /// The media type a file's extension stands for. MPEG-4 audio (voice messages) is the
    /// registered `audio/mp4` (RFC 4337), not UTType's `audio/x-m4a`.
    static func mediaType(forExtension pathExtension: String) -> String? {
        guard !pathExtension.isEmpty else { return nil }
        if ["m4a", "m4b"].contains(pathExtension.lowercased()) { return "audio/mp4" }
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }

    /// The media type the first bytes of a file show. A hint only: what a file is shown as
    /// never depends on it alone.
    static func sniff(_ prefix: Data) -> String? {
        let bytes = [UInt8](prefix.prefix(16))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count
                && Array(bytes[offset..<offset + signature.count]) == signature
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool {
            starts(Array(text.utf8), at: offset)
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if ascii("GIF87a") || ascii("GIF89a") { return "image/gif" }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return "image/webp" }
        if ascii("RIFF"), ascii("WAVE", at: 8) { return "audio/wav" }
        if ascii("%PDF-") { return "application/pdf" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "application/zip" }
        if ascii("OggS") { return "audio/ogg" }
        if ascii("fLaC") { return "audio/flac" }
        if ascii("ID3") || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) { return "audio/mpeg" }
        if ascii("BM") { return "image/bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if ascii("ftyp", at: 4) {
            if ascii("heic", at: 8) || ascii("heix", at: 8) || ascii("mif1", at: 8) {
                return "image/heic"
            }
            if ascii("qt  ", at: 8) { return "video/quicktime" }
            if ascii("M4A ", at: 8) { return "audio/mp4" }
            return "video/mp4"
        }
        return nil
    }
}
