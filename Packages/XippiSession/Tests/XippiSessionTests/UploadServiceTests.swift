import CryptoKit
import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// An `UploadService` for alice on a `MediaRig`, asking a `FakeStanzaSender` for the upload
/// service and its slots.
struct UploadRig {
    static let put = "https://upload.example.test/put/abc/photo.png"
    static let get = "https://upload.example.test/get/abc/photo.png"

    let media: MediaRig
    let sender: FakeStanzaSender
    let clock = ManualDate()
    let delivered = Locked<[(Int64, Element)]>([])
    let service: UploadService

    init(maxSize: Int? = 1_000_000, hasService: Bool = true) throws {
        let media = try MediaRig()
        self.media = media
        let sender = FakeStanzaSender(boundJID: try JID("\(MediaRig.account)/res"))
        self.sender = sender
        let items =
            hasService
            ? "<item jid='upload.example.test'/>" : ""
        sender.enqueueResponse(
            try Self.element(
                "<iq type='result'><query xmlns='http://jabber.org/protocol/disco#items'>"
                    + items + "</query></iq>"), for: "query")
        if hasService {
            let size =
                maxSize.map {
                    "<x xmlns='jabber:x:data' type='result'><field var='FORM_TYPE' type='hidden'>"
                        + "<value>urn:xmpp:http:upload:0</value></field>"
                        + "<field var='max-file-size'><value>\($0)</value></field></x>"
                } ?? ""
            sender.enqueueResponse(
                try Self.element(
                    "<iq type='result'><query xmlns='http://jabber.org/protocol/disco#info'>"
                        + "<identity category='store' type='file'/>"
                        + "<feature var='urn:xmpp:http:upload:0'/>\(size)</query></iq>"),
                for: "query")
            sender.enqueueResponse(
                try Self.element(
                    "<iq type='result'><slot xmlns='urn:xmpp:http:upload:0'>"
                        + "<put url='\(Self.put)'><header name='Authorization'>Basic x</header>"
                        + "<header name='Host'>evil</header></put><get url='\(Self.get)'/>"
                        + "</slot></iq>"), for: "request")
        }
        let delivered = self.delivered
        let clock = self.clock
        service = UploadService(
            accountID: media.accountID, account: try JID(MediaRig.account),
            database: media.database, sender: sender, transport: media.transport,
            library: media.library, now: { clock.now },
            deliver: { id, stanza in delivered.withLock { $0.append((id, stanza)) } })
    }

    static func element(_ xml: String) throws -> Element {
        try #require(SessionServer.elements(xml).first)
    }

    var slotRequest: Element? {
        sender.sent.compactMap { $0.child("request", namespace: HTTPUpload.namespace) }.first
    }

    func attachment(_ messageID: Int64) throws -> AttachmentRecord {
        try #require(try media.database.attachments(messageID: messageID).first)
    }

    func message(_ messageID: Int64) throws -> MessageRecord {
        try #require(try media.database.message(id: messageID))
    }
}

@Suite struct UploadServiceTests {
    @Test func uploadWritesProgressAndSendsOOB() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(5000)
        let file = try rig.media.file("photo.png", bytes)
        let seen = Locked<[Double?]>([])
        let database = rig.media.database
        let clock = rig.clock
        rig.media.transport.onUpload.set { progress in
            // Reported faster than the row may be written: only one in each 100 ms gets there.
            for fraction in [0.25, 0.3, 0.35] { progress(fraction) }
            seen.withLock { $0.append(Self.progress(database)) }
            clock.advance(by: 0.2)
            progress(0.5)
            seen.withLock { $0.append(Self.progress(database)) }
        }

        let id = try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)

        let request = try #require(rig.slotRequest)
        #expect(request[attribute: "filename"] == "photo.png")
        #expect(request[attribute: "size"] == "5000")
        #expect(request[attribute: "content-type"] == "image/png")
        let upload = try #require(rig.media.transport.uploads.first)
        #expect(upload.slot.put.absoluteString == UploadRig.put)
        #expect(upload.slot.headers == ["Authorization": "Basic x"])
        #expect(upload.body == bytes)
        #expect(seen.value == [0.25, 0.5])

        let delivered = try #require(rig.delivered.value.first)
        #expect(delivered.0 == id)
        let stanza = delivered.1
        #expect(stanza.to?.description == MediaRig.bob)
        #expect(stanza.child("body")?.text == UploadRig.get)
        #expect(
            stanza.child("x", namespace: OOB.namespace)?.child("url", namespace: OOB.namespace)?
                .text == UploadRig.get)
        let sharing = try #require(
            stanza.child("file-sharing", namespace: StatelessFileSharing.namespace).flatMap(
                StatelessFileSharing.parse))
        #expect(sharing.file.name == "photo.png")
        #expect(sharing.file.size == 5000)
        #expect(sharing.file.mediaType == "image/png")
        #expect(sharing.file.hashes.map(\.algorithm) == ["sha-256"])
        #expect(sharing.file.hashes.first?.value == Data(SHA256.hash(data: bytes)))
        #expect(sharing.urls.map(\.absoluteString) == [UploadRig.get])

        let attachment = try rig.attachment(id)
        #expect(attachment.state == .local)
        #expect(attachment.progress == nil)
        #expect(attachment.remoteURL == UploadRig.get)
        #expect(attachment.aesgcmKey == nil)
        #expect(attachment.fileName == "photo.png")
        #expect(attachment.byteSize == 5000)
        #expect(attachment.localPath?.hasSuffix("/" + MediaRig.sha256Hex(bytes)) == true)
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: try #require(attachment.localPath))) == bytes)
        let message = try rig.message(id)
        #expect(message.kind == .file)
        #expect(message.encryption == EncryptionMode.none)
        #expect(message.originID == stanza.id)
    }

    @Test func encryptedUploadSendsAESGCMURL() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        let bytes = MediaRig.bytes(5000)
        let file = try rig.media.file("photo.png", bytes)

        let id = try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: true)

        let request = try #require(rig.slotRequest)
        #expect(request[attribute: "filename"] != "photo.png")
        #expect(request[attribute: "filename"]?.hasSuffix(".png") == true)
        #expect(request[attribute: "size"] == "5016")
        #expect(request[attribute: "content-type"] == "application/octet-stream")
        let upload = try #require(rig.media.transport.uploads.first)
        #expect(upload.body.count == 5016)
        #expect(upload.body.prefix(100) != bytes.prefix(100))

        let stanza = try #require(rig.delivered.value.first?.1)
        let body = try #require(stanza.child("body")?.text)
        let link = try #require(URL(string: body))
        #expect(link.scheme == "aesgcm")
        #expect(link.host == "upload.example.test")
        let fragment = try #require(
            URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
        #expect(fragment.count == 88)
        #expect(try AESGCMFile.decrypt(data: upload.body, fragment: fragment) == bytes)
        #expect(stanza.child("x", namespace: OOB.namespace) == nil)
        #expect(stanza.child("file-sharing", namespace: StatelessFileSharing.namespace) == nil)

        let attachment = try rig.attachment(id)
        #expect(attachment.remoteURL == body)
        #expect(attachment.aesgcmKey?.count == 44)
        #expect(attachment.state == .local)
        #expect(try rig.message(id).encryption == .omemo)
    }

    @Test func aRefusedPUTMarksTheMessageFailed() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        rig.media.transport.failUploads(with: HTTPUploadError.status(413))
        let file = try rig.media.file("notes.txt", Data("hello".utf8))

        await #expect(throws: UploadError.failed("Upload failed: HTTP 413")) {
            try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)
        }

        let message = try #require(
            try rig.media.database.page(chatID: rig.media.chatID, before: nil, limit: 10).first)
        #expect(message.state == .failed)
        #expect(message.errorText == "Upload failed: HTTP 413")
        let attachment = try rig.attachment(try #require(message.id))
        #expect(attachment.state == .failed)
        #expect(attachment.errorText == "Upload failed: HTTP 413")
        #expect(rig.delivered.value.isEmpty)
    }

    @Test func noUploadServiceMarksTheMessageFailed() async throws {
        let rig = try UploadRig(hasService: false)
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("notes.txt", Data("hello".utf8))

        await #expect(throws: UploadError.failed("No upload service")) {
            try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)
        }
        #expect(rig.slotRequest == nil)
    }

    @Test func aFileTooLargeForTheServerAsksForNoSlot() async throws {
        let rig = try UploadRig(maxSize: 1000)
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("big.bin", MediaRig.bytes(5000))

        await #expect(throws: UploadError.failed("Too large for the server")) {
            try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)
        }
        #expect(rig.slotRequest == nil)
        #expect(rig.media.transport.uploads.isEmpty)
    }

    @Test func aCancelledUploadIsMarkedFailed() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        rig.media.transport.holdUploads()
        let file = try rig.media.file("big.bin", MediaRig.bytes(5000))
        let service = rig.service
        let chatID = rig.media.chatID
        let sending = Task { try await service.send(file: file, chatID: chatID, encrypt: false) }
        try await waitUntil("upload started") { rig.media.transport.uploadStarted }
        let message = try #require(
            try rig.media.database.page(chatID: chatID, before: nil, limit: 10).first?.id)

        await service.cancel(messageID: message)

        await #expect(throws: UploadError.cancelled) { try await sending.value }
        #expect(try rig.message(message).state == .failed)
        #expect(try rig.message(message).errorText == "Cancelled")
        #expect(try rig.attachment(message).state == .failed)
        #expect(rig.delivered.value.isEmpty)
    }

    @Test func theUsersFileIsCopiedIntoTheLibrary() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("photo.png", MediaRig.bytes(100))

        let id = try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)

        let path = try #require(try rig.attachment(id).localPath)
        #expect(path != file.path)
        #expect(rig.media.library.contains(path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func progressIsWrittenAtMostTenTimesASecond() {
        let clock = ManualDate()
        let throttle = ProgressThrottle(now: { clock.now })
        #expect(throttle.shouldWrite(0.1))
        #expect(!throttle.shouldWrite(0.2))
        clock.advance(by: 0.05)
        #expect(!throttle.shouldWrite(0.3))
        clock.advance(by: 0.05)
        #expect(throttle.shouldWrite(0.4))
        #expect(!throttle.shouldWrite(0.4))
        #expect(throttle.shouldWrite(1))
    }

    static func progress(_ database: AppDatabase) -> Double? {
        guard let chat = try? database.chats(accountID: 1).first?.id,
            let message = try? database.page(chatID: chat, before: nil, limit: 1).first?.id
        else { return nil }
        return (try? database.attachments(messageID: message).first)?.progress
    }
}
