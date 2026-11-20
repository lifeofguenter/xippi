import Foundation
import UniformTypeIdentifiers
import XippiStore

/// Save As for a file in a chat: whether an attachment can be saved now, the name to offer,
/// and the copy written where the user chose.
///
/// What is saved is the file as kept in the media library: a file that came encrypted
/// (`aesgcm`, OMEMO) is kept decrypted, so the copy holds the plaintext.
public enum SaveAs {
    /// Why an attachment cannot be saved now.
    public enum Unavailable: Error, Equatable, Sendable {
        /// Not fetched: never asked for, left by the automatic download (size limit, unknown
        /// sender), or gone from the library since.
        case notDownloaded
        /// On its way in.
        case downloading
        /// The download failed, or the offer was declined or withdrawn.
        case failed
        /// Offered over Jingle and not accepted yet.
        case offered
    }

    /// A file that can be saved: where it is now, and the name the save panel offers.
    public struct Source: Equatable, Sendable {
        public let file: URL
        public let suggestedName: String

        public init(file: URL, suggestedName: String) {
            self.file = file
            self.suggestedName = suggestedName
        }
    }

    /// Why the copy was not written.
    public enum Failure: Error, Equatable, Sendable {
        /// The file is no longer in the library.
        case fileMissing
        /// The chosen place cannot be written (permissions, a read-only volume).
        case noPermission
        case diskFull
        case failed
    }

    /// The file to save for `attachment`, or why there is none. A file of ours can be saved
    /// whatever its upload did; a received one only once it is here, never after its download
    /// failed. `library` finds the file by its name when the container moved since the row
    /// was written; without one, the row's path is taken as it is.
    public static func source(
        of attachment: AttachmentRecord, outgoing: Bool, library: MediaLibrary?
    ) -> Result<Source, Unavailable> {
        switch attachment.state {
        case .remote: return .failure(.notDownloaded)
        case .downloading: return .failure(.downloading)
        case .offered: return .failure(.offered)
        case .failed where !outgoing: return .failure(.failed)
        case .local, .uploading, .failed: break
        }
        guard let path = attachment.localPath, let file = existingFile(path, library: library)
        else { return .failure(.notDownloaded) }
        return .success(Source(file: file, suggestedName: suggestedName(for: attachment)))
    }

    private static func existingFile(_ path: String, library: MediaLibrary?) -> URL? {
        if let library { return library.existingFile(for: path) }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: The name

    /// The longest name, in UTF-8 bytes, most file systems take.
    static let maxNameBytes = 255
    /// Shown for a file whose name says nothing.
    static let fallbackName = "File"

    /// The name the save panel offers: the one the sender gave, else the link's last part,
    /// else "File"; with the type's extension when it has none. A peer chose it, so it cannot
    /// name another folder, start hidden, or carry control or direction characters that make
    /// it read as another type.
    public static func suggestedName(for attachment: AttachmentRecord) -> String {
        let given = [attachment.fileName, attachment.remoteURL.flatMap(linkName)]
            .lazy.compactMap { $0.map(clean) }.first { !$0.isEmpty }
        var name = given ?? fallbackName
        if (name as NSString).pathExtension.isEmpty, let ext = typeExtension(of: attachment) {
            name += "." + ext
        }
        return fitted(name)
    }

    /// The last part of an `https` or `aesgcm` link, unescaped.
    private static func linkName(_ link: String) -> String? {
        guard let url = URL(string: link), url.host?.isEmpty == false else { return nil }
        let last = url.lastPathComponent
        return last == "/" ? nil : last
    }

    /// Characters that would change how the name reads without being seen: bidirectional
    /// marks, embeddings, overrides and isolates.
    private static let directionMarks: Set<Unicode.Scalar> = [
        "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
        "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    /// Without control and direction characters, path separators as "-", no leading dots
    /// and no surrounding white space.
    private static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if scalar.properties.generalCategory != .control,
                !directionMarks.contains(scalar)
            {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The extension of the declared type, else of the type the bytes show; none for
    /// `application/octet-stream` (what an encrypted file is declared as).
    private static func typeExtension(of attachment: AttachmentRecord) -> String? {
        for mime in [attachment.mimeType, attachment.sniffedMimeType].compactMap(\.self) {
            guard mime.lowercased() != "application/octet-stream",
                let ext = UTType(mimeType: mime)?.preferredFilenameExtension
            else { continue }
            return ext
        }
        return nil
    }

    /// Cut to `maxNameBytes` at a character boundary, keeping the extension.
    private static func fitted(_ name: String) -> String {
        guard name.utf8.count > maxNameBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var stem = Substring(suffix.isEmpty ? name : (name as NSString).deletingPathExtension)
        while stem.utf8.count + suffix.utf8.count > maxNameBytes { stem.removeLast() }
        return String(stem) + suffix
    }

    // MARK: The copy

    /// Copies `source` to `destination`, which the user chose (and agreed to replace, if it
    /// exists). An existing file is swapped for the copy only once the copy is whole, so a
    /// failure leaves it as it was. Blocks while it copies: run it off the main thread.
    public static func write(_ source: URL, to destination: URL) throws(Failure) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { throw .fileMissing }
        do {
            guard manager.fileExists(atPath: destination.path) else {
                do {
                    try manager.copyItem(at: source, to: destination)
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
                return
            }
            let staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: destination, create: true)
            defer { try? manager.removeItem(at: staging) }
            let copy = staging.appending(
                path: destination.lastPathComponent, directoryHint: .notDirectory)
            try manager.copyItem(at: source, to: copy)
            _ = try manager.replaceItemAt(destination, withItemAt: copy)
        } catch {
            throw failure(error)
        }
    }

    // MARK: Dragging out

    /// Where dragged files wait for the app they are dropped on: the temporary folder (in the
    /// app, the sandbox container's).
    public static var dragFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Drag", directoryHint: .isDirectory)
    }

    /// How long a dragged copy is kept for the app it was dropped on to copy it.
    static let dragCopyLifetime: TimeInterval = 3600

    /// A copy of the file under the name Save As offers, for dragging out: the drag carries
    /// this copy, never the library's own file, its path or its hash name. Each copy sits in a
    /// folder of its own inside `folder`, so its name is exactly that and two drags never
    /// meet. Copies from earlier drags older than an hour go first. On APFS the copy is a
    /// clone: no bytes are written, however large the file.
    public static func dragCopy(
        _ source: Source, in folder: URL = dragFolder, now: Date = Date()
    ) throws(Failure) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.file.path) else { throw .fileMissing }
        removeDragCopies(in: folder, before: now.addingTimeInterval(-dragCopyLifetime))
        let own = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = own.appending(path: source.suggestedName, directoryHint: .notDirectory)
        do {
            try manager.createDirectory(at: own, withIntermediateDirectories: true)
            try manager.copyItem(at: source.file, to: copy)
        } catch {
            try? manager.removeItem(at: own)
            throw failure(error)
        }
        return copy
    }

    /// Removes the drag copies whose folders were last changed before `cutoff`.
    private static func removeDragCopies(in folder: URL, before cutoff: Date) {
        let manager = FileManager.default
        let folders =
            (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for own in folders {
            let changed = try? own.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let changed, changed < cutoff { try? manager.removeItem(at: own) }
        }
    }

    static func failure(_ error: any Error) -> Failure {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoSuchFile, .fileNoSuchFile: return .fileMissing
            case .fileWriteNoPermission, .fileReadNoPermission, .fileWriteVolumeReadOnly:
                return .noPermission
            case .fileWriteOutOfSpace: return .diskFull
            default: break
            }
        }
        let posix =
            error.domain == NSPOSIXErrorDomain
            ? error.code
            : (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
                $0.domain == NSPOSIXErrorDomain ? $0.code : nil
            }
        switch posix.flatMap({ POSIXErrorCode(rawValue: Int32($0)) }) {
        case .EACCES, .EPERM, .EROFS: return .noPermission
        case .ENOSPC, .EDQUOT: return .diskFull
        case .ENOENT: return .fileMissing
        default: return .failed
        }
    }
}
