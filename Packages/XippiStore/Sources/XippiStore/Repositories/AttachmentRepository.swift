import Foundation
import GRDB

/// File transfers on attachment rows (Task 13): uploads and downloads write their progress,
/// result and failure here, so the transcript shows them as they go.
///
/// States: an upload is `uploading` until `finishAttachmentUpload` (`local`) or
/// `failAttachment`; a download is `remote`, then `downloading` once claimed, then `local`, or
/// back to `remote` (`resetAttachment`, an automatic download that stopped) or `failed`. A file
/// offered over Jingle is `offered` until accepted (`acceptOfferedAttachment`, then as a
/// download) or declined (`failAttachment`).
extension AppDatabase {
    public func attachment(id: Int64) throws -> AttachmentRecord? {
        try reader.read { db in try AttachmentRecord.fetchOne(db, key: id) }
    }

    /// How far the transfer is, 0...1, clamped. Only a row that is uploading or downloading
    /// takes it, so a late report cannot touch a finished row.
    public func setAttachmentProgress(id: Int64, _ progress: Double) throws {
        let value = progress.isFinite ? min(max(progress, 0), 1) : 0
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET progress = ?
                    WHERE id = ? AND state IN ('uploading', 'downloading')
                    """,
                arguments: [value, id])
        }
    }

    /// The upload is through: the row is `local`, with the address it is fetched from (an
    /// `aesgcm://` link for an encrypted file) and the key that link carries.
    public func finishAttachmentUpload(id: Int64, remoteURL: String, aesgcmKey: Data?) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'local', remoteURL = ?, aesgcmKey = ?,
                        progress = NULL, errorText = NULL
                    WHERE id = ? AND state = 'uploading'
                    """,
                arguments: [remoteURL, aesgcmKey, id])
        }
    }

    /// Claims a `remote` or `failed` row for a download: it becomes `downloading`. False when it
    /// is downloading already, local, or an upload, so two downloads never run for one row.
    public func beginAttachmentDownload(id: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'downloading', progress = 0, errorText = NULL
                    WHERE id = ? AND state IN ('remote', 'failed') AND remoteURL IS NOT NULL
                    """,
                arguments: [id])
            return db.changesCount == 1
        }
    }

    /// The download is through: the row is `local` with the file's path and size, the type it
    /// was declared with and the type its first bytes show.
    public func finishAttachmentDownload(
        id: Int64, localPath: String, byteSize: Int64, mimeType: String?, sniffedMimeType: String?
    ) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'local', localPath = ?, byteSize = ?,
                        mimeType = ?, sniffedMimeType = ?, progress = NULL, errorText = NULL
                    WHERE id = ? AND state = 'downloading'
                    """,
                arguments: [localPath, byteSize, mimeType, sniffedMimeType, id])
        }
    }

    /// The transfer failed, or the offer was declined: `failed`, with a terse reason for the
    /// transcript.
    public func failAttachment(id: Int64, reason: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'failed', progress = NULL, errorText = ?
                    WHERE id = ? AND state IN ('uploading', 'downloading', 'remote', 'offered')
                    """,
                arguments: [reason, id])
        }
    }

    /// Claims an `offered` row for the transfer that brings its file: it becomes `downloading`.
    /// False when it is no longer offered (accepted or declined already), so an offer is taken
    /// once.
    public func acceptOfferedAttachment(id: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'downloading', progress = 0, errorText = NULL
                    WHERE id = ? AND state = 'offered'
                    """,
                arguments: [id])
            return db.changesCount == 1
        }
    }

    /// A failed upload of one of the account's messages starts again (M13): its attachment
    /// back to `uploading`, the message back to `pending`, both in one write and only from
    /// `failed`. False, and nothing changed, for anything else.
    public func restartUpload(messageID: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'uploading', progress = NULL, errorText = NULL
                    WHERE messageID = ? AND state = 'failed' AND localPath IS NOT NULL
                      AND EXISTS (SELECT 1 FROM message WHERE id = ? AND direction = 'outgoing'
                                  AND state = 'failed' AND retracted = 0)
                    """,
                arguments: [messageID, messageID])
            guard db.changesCount > 0 else { return false }
            try db.execute(
                sql: "UPDATE message SET state = 'pending', errorText = NULL WHERE id = ?",
                arguments: [messageID])
            return true
        }
    }

    /// A download stopped without failing (an automatic one at the size limit): back to
    /// `remote`, so the user can still ask for it.
    public func resetAttachment(id: Int64, reason: String? = nil) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'remote', progress = NULL, errorText = ?
                    WHERE id = ? AND state = 'downloading'
                    """,
                arguments: [reason, id])
        }
    }

    /// Whether any attachment row still names the library file `name` (its SHA-256 in hex).
    /// Files are kept once per content, so one may back several rows; it is deleted only when
    /// none is left. Matched by name, never by the whole path, so rows written under another
    /// spelling of the library's directory (a renamed home folder, a migrated Mac) still count.
    /// Any other name answers true: nothing deletes it.
    public func isAttachmentFileNameInUse(_ name: String) throws -> Bool {
        guard Self.isLibraryFileName(name) else { return true }
        return try reader.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM attachment INDEXED BY attachment_fileName
                        WHERE substr(localPath, -65) = ? AND localPath IS NOT NULL)
                    """,
                arguments: ["/" + name]) ?? false
        }
    }

    /// The names of the library files the account's attachments name that no other account's
    /// attachment names: what removing the account frees. Read before its rows go.
    public func attachmentFileNamesOnlyOf(accountID: Int64) throws -> [String] {
        try reader.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT substr(a.localPath, -64) FROM attachment a
                    JOIN message m ON m.id = a.messageID
                    WHERE m.accountID = ? AND a.localPath IS NOT NULL
                        AND substr(a.localPath, -65, 1) = '/'
                        AND NOT EXISTS (
                            SELECT 1 FROM attachment b JOIN message n ON n.id = b.messageID
                            WHERE b.localPath IS NOT NULL
                                AND substr(b.localPath, -65) = substr(a.localPath, -65)
                                AND n.accountID != ?)
                    """,
                arguments: [accountID, accountID]
            ).filter(Self.isLibraryFileName)
        }
    }

    /// The names of every library file an attachment row names.
    public func attachmentFileNames() throws -> Set<String> {
        try reader.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT substr(localPath, -64) FROM attachment
                        WHERE localPath IS NOT NULL AND substr(localPath, -65, 1) = '/'
                        """
                ).filter(Self.isLibraryFileName))
        }
    }

    /// A library file's name: its SHA-256, 64 lower-case hex digits.
    static func isLibraryFileName(_ name: String) -> Bool {
        name.utf8.count == 64
            && name.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    /// A `local` row whose file is gone: back to `remote`, without the path, so it can be
    /// fetched again.
    public func forgetAttachmentFile(id: Int64) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'remote', localPath = NULL, progress = NULL
                    WHERE id = ? AND state = 'local'
                    """,
                arguments: [id])
        }
    }

    /// After a restart nothing is moving any more: uploads of the account that were cut off
    /// fail with `reason`, and so do their messages; downloads go back to `remote`. A Jingle
    /// session does not outlive the app: offers and files coming over Jingle (no link) fail.
    public func settleInterruptedTransfers(accountID: Int64, reason: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE message SET state = 'failed', errorText = ?
                    WHERE accountID = ? AND direction = 'outgoing' AND state = 'pending'
                        AND id IN (SELECT messageID FROM attachment WHERE state = 'uploading')
                    """,
                arguments: [reason, accountID])
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'failed', progress = NULL, errorText = ?
                    WHERE state = 'uploading'
                        AND messageID IN (SELECT id FROM message WHERE accountID = ?)
                    """,
                arguments: [reason, accountID])
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'failed', progress = NULL, errorText = ?
                    WHERE (state = 'offered' OR (state = 'downloading' AND remoteURL IS NULL))
                        AND messageID IN (SELECT id FROM message WHERE accountID = ?)
                    """,
                arguments: [reason, accountID])
            try db.execute(
                sql: """
                    UPDATE attachment SET state = 'remote', progress = NULL
                    WHERE state = 'downloading'
                        AND messageID IN (SELECT id FROM message WHERE accountID = ?)
                    """,
                arguments: [accountID])
        }
    }
}
