import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Xippi
@testable import XippiStore

/// Opening a downloaded file: the stored file has no extension, so it is opened through a
/// link named with the extension of what its bytes are. Opened as is, pictures showed as text.
@Suite struct PreviewFileTests {
    static func attachment(name: String?, declared: String?, sniffed: String?) -> AttachmentRecord {
        AttachmentRecord(
            id: 42, messageID: 1, remoteURL: nil, aesgcmKey: nil, localPath: nil,
            mimeType: declared, byteSize: nil, fileName: name, width: nil, height: nil,
            durationSeconds: nil, state: .local, progress: nil, sniffedMimeType: sniffed,
            errorText: nil)
    }

    @Test func theNameGetsTheExtensionOfWhatTheFileIs() {
        #expect(PreviewFile.name(fileName: "holiday.jpg", type: .jpeg) == "holiday.jpg")
        #expect(PreviewFile.name(fileName: "holiday.JPEG", type: .jpeg) == "holiday.JPEG")
        #expect(PreviewFile.name(fileName: "stanza-paste", type: .png) == "stanza-paste.png")
        #expect(PreviewFile.name(fileName: nil, type: .png) == "file.png")
        // A name claiming a picture whose bytes are a web page opens as the web page.
        #expect(PreviewFile.name(fileName: "cat.jpg", type: .html) == "cat.jpg.html")
    }

    /// What the file is: its bytes first, then the declared type, then the name; a link that
    /// came without a type is still a picture by its name.
    @Test func theTypeComesFromTheBytesThenTheClaim() {
        #expect(
            PreviewFile.type(
                of: Self.attachment(name: "a.txt", declared: "text/plain", sniffed: "image/png"))
                == .png)
        #expect(
            PreviewFile.type(of: Self.attachment(name: "photo.jpg", declared: nil, sniffed: nil))
                .conforms(to: .image))
        #expect(
            PreviewFile.type(of: Self.attachment(name: "x", declared: "image/gif", sniffed: nil))
                == .gif)
    }

    /// The link opens the same bytes under the right name, and is made again each time.
    @Test func theLinkOpensTheSameBytesUnderTheRightName() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "preview-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stored = root.appending(path: "0123abcd", directoryHint: .notDirectory)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try bytes.write(to: stored)
        let record = Self.attachment(name: "paste", declared: nil, sniffed: "image/png")
        let first = try PreviewFile.link(to: stored, attachment: record, in: root)
        let again = try PreviewFile.link(to: stored, attachment: record, in: root)
        #expect(again.lastPathComponent == "paste.png")
        #expect(first == again)
        #expect(try Data(contentsOf: again) == bytes)
    }

    /// A stored name is a peer's: whatever it holds, the link stays in its own folder.
    @Test func aNameNeverLeavesItsFolder() throws {
        #expect(PreviewFile.component("../../Library/evil.png") == "evil.png")
        #expect(PreviewFile.component("..") == "file")
        #expect(PreviewFile.component(".hidden") == "hidden")
        #expect(PreviewFile.component("a:b.png") == "a_b.png")
        #expect(PreviewFile.component(nil) == "file")

        let root = FileManager.default.temporaryDirectory.appending(
            path: "preview-escape-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stored = root.appending(path: "0123abcd", directoryHint: .notDirectory)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: stored)
        let link = try PreviewFile.link(
            to: stored,
            attachment: Self.attachment(name: "../../escape", declared: nil, sniffed: "image/png"),
            in: root)
        #expect(
            link.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL)
        #expect(link.lastPathComponent == "escape.png")
    }
}
