import Foundation
import UniformTypeIdentifiers
import XippiStore

/// Downloaded files are kept under their hash, without an extension. Quick Look and other
/// apps tell a file's kind by its extension, so a picture opened as is shows as text. A file
/// is opened through a link named like the attachment, with the extension of what its bytes
/// are.
enum PreviewFile {
    /// What the file is: by its bytes when they were recognised, else as declared, else by its
    /// name. Read on any thread: the Media tab loads off the main thread.
    nonisolated static func type(of attachment: AttachmentRecord) -> UTType {
        if let sniffed = attachment.sniffedMimeType, let type = UTType(mimeType: sniffed) {
            return type
        }
        return declaredType(of: attachment, fileName: attachment.fileName)
    }

    /// By the declared type, else by the name's extension: an encrypted file is declared
    /// `application/octet-stream` (that is what went up), and a link comes with no type, so
    /// the name tells more.
    nonisolated static func declaredType(of attachment: AttachmentRecord, fileName: String?)
        -> UTType
    {
        if let mime = attachment.mimeType, mime.lowercased() != "application/octet-stream",
            let type = UTType(mimeType: mime)
        {
            return type
        }
        if let ext = fileName.map({ ($0 as NSString).pathExtension }), !ext.isEmpty,
            let type = UTType(filenameExtension: ext)
        {
            return type
        }
        return .data
    }

    /// The name to open the file under: the attachment's name, its extension made to match
    /// `type`. A name claiming another kind keeps its words but gets the true extension.
    nonisolated static func name(fileName: String?, type: UTType) -> String {
        let base = component(fileName)
        guard let wanted = type.preferredFilenameExtension else { return base }
        let ext = (base as NSString).pathExtension
        if !ext.isEmpty, let named = UTType(filenameExtension: ext), named.conforms(to: type) {
            return base
        }
        return base + "." + wanted
    }

    /// One plain name: a stored name is a peer's, so whatever it holds, nothing in it may
    /// reach another folder (no separators, no leading dots, no `..`).
    nonisolated static func component(_ fileName: String?) -> String {
        let last = ((fileName ?? "") as NSString).lastPathComponent
        let cleaned = last.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        let trimmed = String(cleaned.drop { $0 == "." })
        return trimmed.isEmpty ? "file" : trimmed
    }

    /// A link to `file` under its proper name in a folder of its own for this attachment,
    /// made again each time; a copy where a link cannot be made.
    nonisolated static func link(to file: URL, attachment: AttachmentRecord, in root: URL) throws
        -> URL
    {
        let folder = root.appending(
            path: String(attachment.id ?? 0), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Self.name(fileName: attachment.fileName, type: type(of: attachment))
        let url = folder.appending(path: name, directoryHint: .notDirectory).standardizedFileURL
        guard
            url.deletingLastPathComponent().standardizedFileURL.path
                == folder.standardizedFileURL.path
        else { throw CocoaError(.fileWriteInvalidFileName) }
        do {
            try FileManager.default.linkItem(at: file, to: url)
        } catch {
            try FileManager.default.copyItem(at: file, to: url)
        }
        return url
    }

    /// Where the links live: the app's temporary folder, emptied by the system.
    static var root: URL {
        FileManager.default.temporaryDirectory.appending(
            path: "Open", directoryHint: .isDirectory)
    }
}
