import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Save As for a file in a chat: which attachments can be saved, the name the save panel
/// offers, and the copy written where the user chose.
@Suite struct SaveAsTests {
    static let link = "https://files.example.test/a/photo.png"

    /// An attachment row as the transcript has it.
    static func attachment(
        state: AttachmentState, localPath: String? = nil, fileName: String? = "photo.png",
        remoteURL: String? = link, mimeType: String? = "image/png", sniffed: String? = nil,
        errorText: String? = nil
    ) -> AttachmentRecord {
        AttachmentRecord(
            id: 1, messageID: 1, remoteURL: remoteURL, aesgcmKey: nil, localPath: localPath,
            mimeType: mimeType, byteSize: 4, fileName: fileName, width: nil, height: nil,
            durationSeconds: nil, state: state, sniffedMimeType: sniffed, errorText: errorText)
    }

    /// A file in the rig's library, as a finished download leaves it.
    static func libraryFile(_ rig: MediaRig, _ data: Data) throws -> URL {
        try rig.library.store(data).url
    }

    // MARK: Which attachments can be saved

    @Test func aDownloadedFileCanBeSavedUnderItsName() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("png".utf8))

        let result = SaveAs.source(
            of: Self.attachment(state: .local, localPath: file.path), outgoing: false,
            library: rig.library)

        #expect(result == .success(SaveAs.Source(file: file, suggestedName: "photo.png")))
    }

    @Test func aFileOfOursCanBeSavedWhileItGoesUpAndAfterItFailedToGoUp() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("ours".utf8))

        for state in [AttachmentState.uploading, .failed, .local] {
            let result = SaveAs.source(
                of: Self.attachment(state: state, localPath: file.path), outgoing: true,
                library: rig.library)
            #expect(result == .success(SaveAs.Source(file: file, suggestedName: "photo.png")))
        }
    }

    @Test func aFileNotDownloadedCannotBeSaved() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }

        #expect(
            SaveAs.source(
                of: Self.attachment(state: .remote), outgoing: false, library: rig.library)
                == .failure(.notDownloaded))
        // Left for the user by the automatic download (over the size limit).
        #expect(
            SaveAs.source(
                of: Self.attachment(state: .remote, errorText: "Over the size limit"),
                outgoing: false, library: rig.library) == .failure(.notDownloaded))
        #expect(
            SaveAs.source(
                of: Self.attachment(state: .downloading), outgoing: false, library: rig.library)
                == .failure(.downloading))
        #expect(
            SaveAs.source(
                of: Self.attachment(state: .offered), outgoing: false, library: rig.library)
                == .failure(.offered))
    }

    @Test func aFailedOrDeclinedDownloadCannotBeSaved() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let stray = try Self.libraryFile(rig, Data("partial".utf8))

        for reason in ["Download failed: HTTP 500", "Declined", "Cannot decrypt"] {
            #expect(
                SaveAs.source(
                    of: Self.attachment(state: .failed, errorText: reason), outgoing: false,
                    library: rig.library) == .failure(.failed))
        }
        // Even with a file under its path: a failed download is never offered for saving.
        #expect(
            SaveAs.source(
                of: Self.attachment(state: .failed, localPath: stray.path), outgoing: false,
                library: rig.library) == .failure(.failed))
    }

    @Test func aDownloadedFileThatIsGoneCannotBeSaved() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("gone".utf8))
        try FileManager.default.removeItem(at: file)

        #expect(
            SaveAs.source(
                of: Self.attachment(state: .local, localPath: file.path), outgoing: false,
                library: rig.library) == .failure(.notDownloaded))
    }

    @Test func aFileIsFoundInTheCurrentLibraryWhenTheContainerMoved() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("moved".utf8))
        let oldPath = "/Users/someone-else/Library/Media/" + file.lastPathComponent

        let result = SaveAs.source(
            of: Self.attachment(state: .local, localPath: oldPath), outgoing: false,
            library: rig.library)

        #expect(result == .success(SaveAs.Source(file: file, suggestedName: "photo.png")))
    }

    @Test func withoutALibraryTheRowsPathIsUsed() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try rig.file("picked.png", Data("x".utf8))

        #expect(
            SaveAs.source(
                of: Self.attachment(state: .local, localPath: file.path), outgoing: false,
                library: nil) == .success(SaveAs.Source(file: file, suggestedName: "photo.png")))
    }

    // MARK: The name the save panel offers

    @Test func theNameComesFromTheMessageElseFromTheLink() {
        #expect(SaveAs.suggestedName(for: Self.attachment(state: .local)) == "photo.png")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: nil,
                    remoteURL: "https://upload.example/x/Report%20Q3.pdf",
                    mimeType: "application/pdf")) == "Report Q3.pdf")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: "  ",
                    remoteURL: "aesgcm://upload.example/x/clip.mp4#00112233",
                    mimeType: nil)) == "clip.mp4")
    }

    @Test func aNameWithoutOneGetsFileAndTheTypesExtension() {
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: nil, remoteURL: nil, mimeType: "image/png"))
                == "File.png")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(state: .local, fileName: nil, remoteURL: nil, mimeType: nil))
                == "File")
    }

    @Test func aNameWithoutExtensionGetsTheTypes() {
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(state: .local, fileName: "scan", mimeType: "application/pdf"))
                == "scan.pdf")
        // An encrypted file is declared as octet-stream: the bytes tell the type.
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: "scan", mimeType: "application/octet-stream",
                    sniffed: "image/png")) == "scan.png")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: "notes", mimeType: "application/octet-stream"))
                == "notes")
    }

    @Test func aPeersNameCannotNameAnotherFolderOrHideItsType() {
        #expect(
            SaveAs.suggestedName(for: Self.attachment(state: .local, fileName: "../a/b:c.txt"))
                == "-a-b-c.txt")
        // A right-to-left override would make "invoice<RLO>fdp.exe" read as "invoiceexe.pdf".
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(state: .local, fileName: "invoice\u{202E}fdp.exe"))
                == "invoicefdp.exe")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(state: .local, fileName: ".profile", mimeType: nil))
                == "profile")
        #expect(
            SaveAs.suggestedName(for: Self.attachment(state: .local, fileName: "line\nbreak.txt"))
                == "linebreak.txt")
        // Nothing left of the name: the link's, else "File".
        #expect(
            SaveAs.suggestedName(for: Self.attachment(state: .local, fileName: "..."))
                == "photo.png")
        #expect(
            SaveAs.suggestedName(
                for: Self.attachment(
                    state: .local, fileName: "...", remoteURL: nil, mimeType: "image/png"))
                == "File.png")
    }

    @Test func emojiSequencesInANameStayWhole() {
        let name = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} trip.jpg"
        #expect(SaveAs.suggestedName(for: Self.attachment(state: .local, fileName: name)) == name)
    }

    @Test func aLongNameIsCutToWhatTheDiskTakesKeepingItsExtension() {
        let long = String(repeating: "\u{00E9}", count: 300) + ".pdf"

        let name = SaveAs.suggestedName(for: Self.attachment(state: .local, fileName: long))

        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".pdf"))
        #expect(name.hasPrefix("\u{00E9}\u{00E9}\u{00E9}"))
    }

    // MARK: Writing the copy

    @Test func theCopyHoldsTheFilesBytes() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let bytes = MediaRig.bytes(70_000)
        let file = try Self.libraryFile(rig, bytes)
        let destination = rig.directory.appendingPathComponent("Saved photo.png")

        try SaveAs.write(file, to: destination)

        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func aFileTheUserChoseToReplaceIsReplaced() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("new".utf8))
        let destination = try rig.file("photo.png", Data("old and longer".utf8))

        try SaveAs.write(file, to: destination)

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func aFileGoneSinceLeavesTheChosenPlaceAlone() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("gone".utf8))
        try FileManager.default.removeItem(at: file)
        let destination = try rig.file("photo.png", Data("kept".utf8))

        #expect(throws: SaveAs.Failure.fileMissing) {
            try SaveAs.write(file, to: destination)
        }
        #expect(try Data(contentsOf: destination) == Data("kept".utf8))
    }

    @Test func aFolderThatCannotBeWrittenIsReported() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("x".utf8))
        let folder = rig.directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        let destination = folder.appendingPathComponent("photo.png")

        #expect(throws: SaveAs.Failure.noPermission) {
            try SaveAs.write(file, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Dragging out

    @Test func aDraggedFileIsACopyUnderItsOwnName() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let bytes = MediaRig.bytes(3000)
        let file = try Self.libraryFile(rig, bytes)
        let source = SaveAs.Source(file: file, suggestedName: "Site plan.png")
        let folder = rig.directory.appendingPathComponent("Drag")

        let copy = try SaveAs.dragCopy(source, in: folder)

        #expect(copy.lastPathComponent == "Site plan.png")
        #expect(try Data(contentsOf: copy) == bytes)
        // Nothing of the library shows: neither its folder nor the file's hash name.
        #expect(!copy.path.hasPrefix(rig.library.directory.path))
        #expect(!copy.path.contains(file.lastPathComponent))
        #expect(copy.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func twoDragsOfTheSameNameDoNotMeet() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let first = try Self.libraryFile(rig, Data("first".utf8))
        let second = try Self.libraryFile(rig, Data("second".utf8))
        let folder = rig.directory.appendingPathComponent("Drag")

        let a = try SaveAs.dragCopy(
            SaveAs.Source(file: first, suggestedName: "photo.png"), in: folder)
        let b = try SaveAs.dragCopy(
            SaveAs.Source(file: second, suggestedName: "photo.png"), in: folder)

        #expect(a != b)
        #expect(a.lastPathComponent == "photo.png")
        #expect(b.lastPathComponent == "photo.png")
        #expect(try Data(contentsOf: a) == Data("first".utf8))
        #expect(try Data(contentsOf: b) == Data("second".utf8))
    }

    @Test func olderDragCopiesGoWhenTheNextDragStarts() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("x".utf8))
        let folder = rig.directory.appendingPathComponent("Drag")
        let source = SaveAs.Source(file: file, suggestedName: "photo.png")
        let now = Date()
        let old = try SaveAs.dragCopy(source, in: folder, now: now)
        let recent = try SaveAs.dragCopy(source, in: folder, now: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 3600)],
            ofItemAtPath: old.deletingLastPathComponent().path)

        let next = try SaveAs.dragCopy(source, in: folder, now: now)

        #expect(!FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: next.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileGoneSinceGivesNoDragAndLeavesNothing() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("gone".utf8))
        try FileManager.default.removeItem(at: file)
        let folder = rig.directory.appendingPathComponent("Drag")

        #expect(throws: SaveAs.Failure.fileMissing) {
            try SaveAs.dragCopy(SaveAs.Source(file: file, suggestedName: "photo.png"), in: folder)
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test func aDraggedFileOfAPeerHasTheNameSaveAsOffers() throws {
        let rig = try MediaRig()
        defer { rig.cleanUp() }
        let file = try Self.libraryFile(rig, Data("pdf".utf8))
        let row = Self.attachment(
            state: .local, localPath: file.path, fileName: "../Report\u{202E}fdp.exe",
            mimeType: "application/pdf")
        let source = try SaveAs.source(of: row, outgoing: false, library: rig.library).get()

        let copy = try SaveAs.dragCopy(
            source, in: rig.directory.appendingPathComponent("Drag"))

        #expect(copy.lastPathComponent == "-Reportfdp.exe")
        #expect(copy.lastPathComponent == SaveAs.suggestedName(for: row))
    }

    @Test func anEncryptedFileIsSavedDecrypted() async throws {
        let rig = try DownloadRig()
        defer { rig.media.cleanUp() }
        var plain = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        plain.append(MediaRig.bytes(4000))
        let picked = try rig.media.file("secret.png", plain)
        let (cipherFile, key, iv) = try AESGCMFile.encrypt(file: picked)
        defer { try? FileManager.default.removeItem(at: cipherFile) }
        let cipher = try Data(contentsOf: cipherFile)
        let get = MediaRig.url(Self.link)
        rig.media.transport.serve(get, data: cipher)
        let link = try AESGCMFile.url(get: get, key: key, iv: iv)
        let file = try rig.media.incomingFile(
            link.absoluteString, mimeType: "application/octet-stream", fileName: "secret")
        try await rig.service.download(attachmentID: file.attachment)
        let row = try rig.attachment(file.attachment)

        let source = try SaveAs.source(of: row, outgoing: false, library: rig.media.library).get()
        let destination = rig.media.directory.appendingPathComponent(source.suggestedName)
        try SaveAs.write(source.file, to: destination)

        #expect(source.suggestedName == "secret.png")
        #expect(try Data(contentsOf: destination) == plain)
        #expect(try Data(contentsOf: destination) != cipher)
    }
}
