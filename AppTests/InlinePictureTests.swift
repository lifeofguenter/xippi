import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Xippi
@testable import XippiStore

/// Pictures in messages show as themselves, at their own proportions, once they are here.
@MainActor @Suite struct InlinePictureTests {
    /// A PNG of the given size in pixels, in the test's temporary folder.
    static func png(_ width: Int, _ height: Int, name: String) throws -> URL {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    static func attachment(
        path: String?, state: AttachmentState = .local, mime: String = "image/png",
        name: String = "picture.png"
    ) -> AttachmentRecord {
        AttachmentRecord(
            id: 7, messageID: 1, remoteURL: "https://upload.example.org/\(name)", aesgcmKey: nil,
            localPath: path, mimeType: mime, byteSize: 1000, fileName: name, width: nil,
            height: nil, durationSeconds: nil, state: state)
    }

    static func model(_ attachment: AttachmentRecord, picture: CGSize?) -> MessageRowModel {
        let message = MessageRecord(
            id: 1, accountID: 1, chatID: 1, direction: .incoming, senderJID: "alice@example.org",
            senderNick: nil, occupantID: nil, body: nil, archiveID: nil, originID: nil,
            stanzaMessageID: nil, timestamp: Date(), receivedAt: Date(), state: .delivered,
            errorText: nil, encryption: .none, senderDeviceFingerprint: nil,
            replyToMessageID: nil, replyToSenderLabel: nil, replyQuote: nil, editedAt: nil,
            retracted: false, moderatedBy: nil, moderationReason: nil, kind: .file)
        return MessageRowModel(
            item: TranscriptItem(id: 1, message: message, reactions: [], attachments: [attachment]),
            body: nil, startsGroup: false, senderName: "Alice", colorKey: "alice@example.org",
            isRoom: false, highlighted: false, pictureSizes: [picture])
    }

    /// Scaled down to fit 300 by 360, never up, and never so small it cannot be clicked.
    @Test func aPictureFitsWithinItsBounds() {
        func shown(_ width: CGFloat, _ height: CGFloat, in space: CGFloat = 600) -> CGSize {
            InlinePicture.displaySize(pixels: CGSize(width: width, height: height), width: space)
        }
        #expect(shown(1200, 800) == CGSize(width: 300, height: 200))
        #expect(shown(800, 2400) == CGSize(width: 120, height: 360))
        #expect(shown(100, 50) == CGSize(width: 100, height: 50))
        #expect(shown(10, 10) == CGSize(width: 44, height: 44))
        // A narrow window: the picture narrows with the bubble.
        #expect(shown(1200, 800, in: 200) == CGSize(width: 200, height: 133))
    }

    /// Only a picture whose file is here shows as itself; one still to fetch, a missing file
    /// or another kind of file keeps its row.
    @Test func onlyAPictureThatIsHereShowsAsItself() throws {
        let file = try Self.png(160, 120, name: "inline-picture.png")
        #expect(
            InlinePicture.pixelSize(of: Self.attachment(path: file.path), media: nil)
                == CGSize(width: 160, height: 120))
        #expect(
            InlinePicture.pixelSize(of: Self.attachment(path: nil, state: .remote), media: nil)
                == nil)
        let missing = FileManager.default.temporaryDirectory.appending(path: "gone.png").path
        #expect(InlinePicture.pixelSize(of: Self.attachment(path: missing), media: nil) == nil)
        let notes = FileManager.default.temporaryDirectory.appending(path: "inline-notes.txt")
        try Data("Notes".utf8).write(to: notes)
        #expect(
            InlinePicture.pixelSize(
                of: Self.attachment(path: notes.path, mime: "text/plain", name: "notes.txt"),
                media: nil) == nil)
    }

    /// A message of one picture is the picture: no bubble colour or padding around it, at
    /// its own size. Any other file keeps its row inside a bubble.
    @Test func aPictureAloneIsTheBubble() {
        let fonts = TranscriptFonts(size: 14)
        let attachment = Self.attachment(path: "/tmp/picture.png")
        let picture = MessageLayout.make(
            Self.model(attachment, picture: CGSize(width: 1200, height: 800)), width: 800,
            fonts: fonts, measurer: TextMeasurer())
        #expect(!picture.bubbleFilled)
        #expect(picture.pictures == [true])
        #expect(picture.attachments.first?.size == CGSize(width: 300, height: 200))
        #expect(picture.bubble.size == CGSize(width: 300, height: 200))

        let file = MessageLayout.make(
            Self.model(attachment, picture: nil), width: 800, fonts: fonts,
            measurer: TextMeasurer())
        #expect(file.bubbleFilled)
        #expect(file.pictures == [false])
        #expect(file.attachments.first?.height == fonts.attachmentRow)
    }

    /// The rows carry each attachment's picture size, as the transcript reads them.
    @Test func theRowsCarryEachPicturesSize() {
        let model = Self.model(Self.attachment(path: "/tmp/picture.png"), picture: nil)
        let chat = TranscriptChat(id: 1, jid: "alice@example.org", name: "Alice", isRoom: false)
        let rows = TranscriptRowBuilder.rows(
            for: [model.item], styled: { _ in nil }, chat: chat, unreadBefore: nil,
            highlighted: nil, calendar: .current,
            pictureSize: { _ in CGSize(width: 640, height: 480) })
        let sizes = rows.compactMap { row -> [CGSize?]? in
            if case .message(let model) = row { return model.pictureSizes }
            return nil
        }
        #expect(sizes == [[CGSize(width: 640, height: 480)]])
    }

    /// A GIF of `frames` frames, under a name without an extension, as files are stored here.
    static func gif(frames: Int, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let rep = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 90, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            [NSColor.systemRed, .systemGreen, .systemBlue][frame % 3].setFill()
            NSRect(x: 0, y: 0, width: 120, height: 90).fill()
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(
                destination, try #require(rep.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
                    as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The row showing `attachment` as a picture, and the image it shows once read.
    static func shown(_ attachment: AttachmentRecord, size: CGSize) async throws -> (
        AttachmentRowView, NSImage
    ) {
        let row = AttachmentRowView(frame: CGRect(origin: .zero, size: size))
        row.fileURL = attachment.localPath.map { URL(fileURLWithPath: $0) }
        row.pictures = AttachmentThumbnails()
        row.show(attachment, outgoing: true, font: .systemFont(ofSize: 14), picture: size)
        for _ in 0..<100 {
            if let image = row.shownImage { return (row, image) }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the picture never showed")
        throw CancellationError()
    }

    /// Files here are named by their contents, without an extension. Quick Look took such a
    /// file for plain data and made nothing, so the picture stayed an empty grey box.
    @Test func aPictureStoredWithoutAnExtensionShows() async throws {
        let png = try Self.png(160, 120, name: "inline-stored.png")
        let stored = FileManager.default.temporaryDirectory.appending(path: "5d41402abc4b2a76")
        try? FileManager.default.removeItem(at: stored)
        try FileManager.default.copyItem(at: png, to: stored)
        let (_, image) = try await Self.shown(
            Self.attachment(path: stored.path), size: CGSize(width: 160, height: 120))
        #expect(image.size.width > 0)
    }

    /// An animated GIF shows as itself and plays; a still picture does not need to.
    @Test func aGIFPlays() async throws {
        let gif = try Self.gif(frames: 3, name: "7b502c3a1f48c860")
        let (row, image) = try await Self.shown(
            Self.attachment(path: gif.path, mime: "image/gif", name: "dance.gif"),
            size: CGSize(width: 120, height: 90))
        let frames =
            (image.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount)
            as? Int
        #expect(frames == 3)
        #expect(row.playsPicture)
    }

    /// A file row's thumbnail keeps the picture's proportions: made for a square, a 4:3
    /// picture was stretched to fill it.
    @Test func aThumbnailKeepsItsProportions() async throws {
        let file = try Self.png(160, 120, name: "inline-thumbnail.png")
        let thumbnails = AttachmentThumbnails()
        let image: NSImage? = await withCheckedContinuation { done in
            thumbnails.make(for: file, key: "thumbnail", type: .png) { done.resume(returning: $0) }
        }
        let size = try #require(image?.size)
        #expect(abs(size.width / size.height - 4.0 / 3.0) < 0.05, "thumbnail \(size)")
    }
    /// A picture from history shows as a row to click until it is fetched: an incoming message
    /// with a file not here yet asks for it as it shows, as a live one's comes by itself. Only
    /// live messages fetched theirs, so pictures that came while the app was away stayed
    /// "Size unknown" rows.
    @Test func aShownMessageAsksForItsFilesWhenTheyAreNotHere() {
        let remote = Self.attachment(path: nil, state: .remote)
        let here = Self.attachment(path: "/tmp/picture.png", state: .local)
        let incoming = Self.model(remote, picture: nil).message
        #expect(TranscriptController.fetchesWhenShown(incoming, attachments: [remote]))
        #expect(!TranscriptController.fetchesWhenShown(incoming, attachments: [here]))
        #expect(!TranscriptController.fetchesWhenShown(incoming, attachments: []))
        var outgoing = incoming
        outgoing.direction = .outgoing
        #expect(!TranscriptController.fetchesWhenShown(outgoing, attachments: [remote]))
        var retracted = incoming
        retracted.retracted = true
        #expect(!TranscriptController.fetchesWhenShown(retracted, attachments: [remote]))
    }
}
