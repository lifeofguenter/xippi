import Foundation
import XippiStore
import os

/// Removes the avatar images nothing shows any more: files named `<SHA-1>.<extension>` whose
/// hash no chat, roster row or own profile row names (any account), with their records. At
/// launch, before any session starts, and after an account was removed.
///
/// The rules of the media library's sweep (ruling R50) apply, on the avatar directory's own
/// marker and lock (`MediaLibrary`'s, reused): it runs only while the directory's id matches
/// the database's library id, so a test launch's database or another installation's never
/// empties it, and only while this process holds the directory exclusively, so another
/// instance never loses files under its sessions. Files are matched by their hash name, never
/// by path. Anything else in the directory stays.
///
/// Running sessions are safe: the cleanup decides and deletes inside one store write, and
/// `AvatarSync` names an image in the same write that records it and writes its file again
/// when a cleanup took it in between.
struct AvatarCleanup: Sendable {
    let directory: URL

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    /// Returns whether it ran.
    @discardableResult
    func sweep(database: AppDatabase) -> Bool {
        // No directory yet: nothing to remove, and nothing is made for it.
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let library = MediaLibrary(directory: directory)
        try? library.prepare()
        // The process holds the directory shared afterwards, as the media library.
        defer { library.holdShared() }
        guard library.holdExclusively() else {
            Self.log.notice("Avatars not swept: directory in use")
            return false
        }
        guard library.bind(database: database) == .matched else { return false }
        do {
            try database.sweepAvatars { named in removeFiles(keeping: named) }
        } catch {
            Self.log.error("Avatars not swept")
            return false
        }
        return true
    }

    /// Removes every avatar file whose hash `named` does not hold.
    private func removeFiles(keeping named: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let hash = Self.hash(named: name), !named.contains(hash) else { continue }
            try? FileManager.default.removeItem(
                at: directory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// The SHA-1 an avatar file is named by: 40 lowercase hex digits, a dot and an extension
    /// of letters and digits (`AvatarSync` names them so). Nil for any other name.
    static func hash(named name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 40,
            parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            (1...8).contains(parts[1].count),
            parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return String(parts[0])
    }
}
