import CryptoKit
import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// History and files through a running session: the router, the message pipeline and the
/// outbox, on the scripted server.
@Suite struct SessionFilesTests {
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"

    static func mamQuery(_ server: SessionServer) -> Element? {
        server.stanzas.last {
            $0.name == "iq" && $0.child("query", namespace: MAM.namespace) != nil
        }
    }

    static func archived(
        _ id: String, queryID: String, body: String, messageID: String, seconds: Int
    ) -> String {
        "<message to='\(me)'><result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(id)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'>"
            + "<delay xmlns='urn:xmpp:delay' stamp='2026-11-19T08:00:\(String(format: "%02d", seconds))Z'/>"
            + "<message xmlns='jabber:client' from='\(bob)/phone' to='\(me)' type='chat'"
            + " id='\(messageID)'><body>\(body)</body>"
            + "<origin-id xmlns='urn:xmpp:sid:0' id='\(messageID)'/></message>"
            + "</forwarded></result></message>"
    }

    @Test func liveMessagesAreNotDelayedByTheCatchUp() async throws {
        let harness = try await SessionHarness()
        // The archive takes its time: its answer is held until the test gives it.
        harness.server.setResponder { iq in
            iq.child("query", namespace: MAM.namespace) != nil ? [] : nil
        }
        try await harness.goOnline()
        try await waitUntil("archive asked") { Self.mamQuery(harness.server) != nil }
        let query = try #require(Self.mamQuery(harness.server))
        let queryID = try #require(
            query.child("query", namespace: MAM.namespace)?[attribute: "queryid"])
        #expect(
            query.child("query", namespace: MAM.namespace)?.child("set", namespace: RSM.namespace)?
                .child("before", namespace: RSM.namespace) != nil)

        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='m3'>"
                + "<body>live</body><origin-id xmlns='urn:xmpp:sid:0' id='m3'/>"
                + "<stanza-id xmlns='urn:xmpp:sid:0' by='alice@example.test' id='a3'/></message>")
        try await waitUntil("live message stored") {
            try harness.messages().contains { $0.body == "live" }
        }

        try harness.deliver(
            Self.archived("a1", queryID: queryID, body: "one", messageID: "m1", seconds: 1)
                + Self.archived("a2", queryID: queryID, body: "two", messageID: "m2", seconds: 2)
                + Self.archived("a3", queryID: queryID, body: "live", messageID: "m3", seconds: 3)
                + "<iq type='result' id='\(query.id ?? "")'><fin xmlns='urn:xmpp:mam:2' complete='true'>"
                + "<set xmlns='http://jabber.org/protocol/rsm'><first>a1</first><last>a3</last></set>"
                + "</fin></iq>")
        try await waitUntil("archive stored") {
            try harness.database.lastKnownArchiveID(
                accountID: harness.accountID, archive: "alice@example.test") == "a3"
        }

        let rows = try harness.messages()
        #expect(rows.map(\.body) == ["one", "two", "live"])
        #expect(rows.map(\.archiveID) == ["a1", "a2", "a3"])
        await harness.stop()
    }

    @Test func archiveResultsFromOthersAreNeverStoredAsLive() async throws {
        let harness = try await SessionHarness()
        harness.server.setResponder { iq in
            iq.child("query", namespace: MAM.namespace) != nil ? [] : nil
        }
        try await harness.goOnline()
        try await waitUntil("archive asked") { Self.mamQuery(harness.server) != nil }
        let queryID = try #require(
            Self.mamQuery(harness.server)?.child("query", namespace: MAM.namespace)?[
                attribute: "queryid"])

        try harness.deliver(
            Self.archived("x1", queryID: queryID, body: "forged", messageID: "f1", seconds: 1)
                .replacingOccurrences(
                    of: "<message to=", with: "<message from='mallory@evil.test' to="))
        try harness.deliver(
            Self.archived("x2", queryID: "unknown", body: "stray", messageID: "f2", seconds: 2))
        try await harness.barrier()

        #expect(try harness.messages().isEmpty)
        await harness.stop()
    }

    // MARK: Files

    static func mediaRig() throws -> (MediaRig, MediaEnvironment) {
        let rig = try MediaRig()
        return (
            rig,
            MediaEnvironment(
                directory: rig.library.directory, transport: rig.transport, bytestreams: nil)
        )
    }

    @Test func filesFromContactsComeByThemselvesAndFromStrangersNot() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        var options = SessionServer.Options()
        options.roster = .items(
            ["<item jid='\(Self.bob)' subscription='both'/>"], version: "v2")
        let harness = try await SessionHarness(options: options, media: environment)
        let bytes = MediaRig.bytes(2048)
        let fromBob = MediaRig.url("https://files.example.test/bob/photo.png")
        let fromStranger = MediaRig.url("https://files.example.test/mallory/x.png")
        media.transport.serve(fromBob, data: bytes, contentType: "image/png")
        media.transport.serve(fromStranger, data: bytes, contentType: "image/png")
        try await harness.goOnline()

        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='f1'>"
                + "<body>\(fromBob)</body>"
                + "<x xmlns='jabber:x:oob'><url>\(fromBob)</url></x>"
                + "<file-sharing xmlns='urn:xmpp:sfs:0'>"
                + "<file xmlns='urn:xmpp:file:metadata:0'><media-type>image/png</media-type>"
                + "<name>../../.hidden\u{202E}gnp.exe</name><size>2048</size></file>"
                + "<sources><url-data xmlns='http://jabber.org/protocol/url-data' target='\(fromBob)'/>"
                + "</sources></file-sharing></message>")
        try harness.deliver(
            "<message from='mallory@evil.test/x' to='\(Self.me)' type='chat' id='f2'>"
                + "<body>\(fromStranger)</body>"
                + "<x xmlns='jabber:x:oob'><url>\(fromStranger)</url></x></message>")
        try await harness.barrier()

        let bobChat = try #require(try harness.chat(Self.bob)?.id)
        let bobMessage = try #require(
            try harness.database.page(chatID: bobChat, before: nil, limit: 10).first?.id)
        try await waitUntil("downloaded") {
            try harness.database.attachments(messageID: bobMessage).first?.state == .local
        }
        let attachment = try #require(try harness.database.attachments(messageID: bobMessage).first)
        #expect(attachment.fileName == "hiddengnp.exe")
        #expect(attachment.byteSize == 2048)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.localPath?.hasSuffix(MediaRig.sha256Hex(bytes)) == true)
        #expect(try harness.database.attachments(messageID: bobMessage).count == 1)

        let strangerChat = try #require(try harness.chat("mallory@evil.test")?.id)
        let strangerMessage = try #require(
            try harness.database.page(chatID: strangerChat, before: nil, limit: 10).first?.id)
        #expect(
            try harness.database.attachments(messageID: strangerMessage).first?.state == .remote)
        #expect(!media.transport.requests.contains(fromStranger))
        await harness.stop()
    }

    static let put = "https://upload.example.test/put/1/notes.txt"
    static let get = "https://upload.example.test/get/1/notes.txt"

    /// Answers the upload service's discovery and slot requests.
    static func uploadResponder(_ iq: Element) -> [String]? {
        let id = iq.id ?? ""
        let to = iq[attribute: "to"] ?? ""
        switch (iq.elements.first?.name, iq.elements.first?.namespace, to) {
        case ("query", "http://jabber.org/protocol/disco#items", "example.test"):
            return [
                "<iq type='result' id='\(id)' from='example.test'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#items'>"
                    + "<item jid='upload.example.test'/></query></iq>"
            ]
        case ("query", "http://jabber.org/protocol/disco#info", "upload.example.test"):
            return [
                "<iq type='result' id='\(id)' from='upload.example.test'>"
                    + "<query xmlns='http://jabber.org/protocol/disco#info'>"
                    + "<feature var='urn:xmpp:http:upload:0'/></query></iq>"
            ]
        case ("request", HTTPUpload.namespace, "upload.example.test"):
            return [
                "<iq type='result' id='\(id)' from='upload.example.test'>"
                    + "<slot xmlns='urn:xmpp:http:upload:0'><put url='\(put)'/><get url='\(get)'/>"
                    + "</slot></iq>"
            ]
        default:
            return nil
        }
    }

    @Test func sendFileUploadsThenSendsTheMessage() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await SessionHarness(media: environment) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        harness.server.setResponder(Self.uploadResponder)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("hello".utf8))

        let id = try await harness.session.sendFile(url: file, chatID: chatID)

        let record = try #require(try harness.database.message(id: id))
        let originID = try #require(record.originID)
        try await waitUntil("sent") { !harness.server.messages(id: originID).isEmpty }
        let sent = try #require(harness.server.messages(id: originID).first)
        #expect(sent.child("body")?.text == Self.get)
        #expect(sent.child("x", namespace: OOB.namespace) != nil)
        #expect(sent.child("file-sharing", namespace: StatelessFileSharing.namespace) != nil)
        #expect(media.transport.uploads.first?.body == Data("hello".utf8))
        #expect(try harness.database.attachments(messageID: id).first?.state == .local)
        await harness.stop()
    }

    @Test func anEncryptedChatsFileNeverGoesOutInTheClear() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await SessionHarness(media: environment) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        harness.server.setResponder(Self.uploadResponder)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("secret".utf8))

        let id = try await harness.session.sendFile(url: file, chatID: chatID)
        try await harness.barrier()

        let record = try #require(try harness.database.message(id: id))
        #expect(record.encryption == .omemo)
        // This server keeps no OMEMO keys: OMEMO (Task 17) keeps the message pending or marks
        // it failed; either way it never goes out as it is.
        #expect(record.state == .pending || record.state == .failed)
        #expect(harness.server.messages(id: try #require(record.originID)).isEmpty)
        let upload = try #require(media.transport.uploads.first)
        #expect(upload.body.count == 6 + 16)
        #expect(
            try harness.database.attachments(messageID: id).first?.remoteURL?.hasPrefix("aesgcm://")
                == true)
        await harness.stop()
    }

    @Test func withoutMediaThereIsNoFileSending() async throws {
        let harness = try await SessionHarness { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)

        await #expect(throws: SessionError.unavailable) {
            try await harness.session.sendFile(
                url: URL(fileURLWithPath: "/dev/null"), chatID: chatID)
        }
        await harness.stop()
    }
}

// MARK: - Fix round 1

extension SessionFilesTests {
    static func harnessWithBob(
        _ environment: MediaEnvironment, encryption: EncryptionMode = .none
    ) async throws -> SessionHarness {
        let harness = try await SessionHarness(media: environment) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            chat.encryption = encryption
            try database.updateChat(chat)
            // A chat that holds files was settled before its first one went up (R63).
            try database.setEncryptionDefault(
                chatID: try #require(chat.id), omemo: encryption == .omemo)
        }
        harness.server.setResponder(Self.uploadResponder)
        try await harness.goOnline()
        return harness
    }

    static func sentMessages(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.filter { $0.name == "message" }
    }

    /// C2: a file taken back while it goes up reaches no one, and no retraction is sent for a
    /// message nobody has.
    @Test func aFileRetractedWhileItUploadsIsNeverSent() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        media.transport.holdUploads()
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("take it back".utf8))
        let session = harness.session
        let stopped = Locked(false)
        let sending = Task {
            defer { stopped.set(true) }
            return try await session.sendFile(url: file, chatID: chatID)
        }
        defer { sending.cancel() }
        try await waitUntil("uploading") { media.transport.uploadStarted }
        let id = try #require(
            try harness.database.page(chatID: chatID, before: nil, limit: 10).first?.id)

        try await session.retract(messageID: id)

        try await waitUntil("upload stopped") { stopped.value }
        await #expect(throws: SessionError.transferFailed("Cancelled")) {
            try await sending.value
        }
        try await harness.barrier()
        #expect(Self.sentMessages(harness).isEmpty)
        #expect(media.transport.uploads.isEmpty)
        let row = try #require(try harness.database.message(id: id))
        #expect(row.retracted)
        #expect(try harness.database.attachments(messageID: id).isEmpty)
        await harness.stop()
    }

    /// C2: a file whose text is corrected while it goes up goes out once, with the new text,
    /// and no correction for a message nobody has.
    @Test func aFileCorrectedWhileItUploadsGoesOutOnceWithTheNewText() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        media.transport.closeGate()
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let file = try media.file("notes.txt", Data("hello".utf8))
        let session = harness.session
        let sending = Task { try await session.sendFile(url: file, chatID: chatID) }
        try await waitUntil("uploading") { media.transport.uploadStarted }
        let id = try #require(
            try harness.database.page(chatID: chatID, before: nil, limit: 10).first?.id)

        try await session.correct(messageID: id, newText: "the notes")
        media.transport.openGate()
        _ = try await sending.value
        try await waitUntil("sent") { !Self.sentMessages(harness).isEmpty }
        try await harness.barrier()

        let sent = Self.sentMessages(harness)
        #expect(sent.count == 1)
        #expect(sent.first?.child("body")?.text == "the notes")
        #expect(sent.first?.child("replace", namespace: ChatMessage.correctionNamespace) == nil)
        #expect(sent.first?.child("x", namespace: OOB.namespace) != nil)
        await harness.stop()
    }

    /// I5: with OMEMO on in the contact's chat, a file for one of its devices is uploaded
    /// encrypted into the chat; nothing goes over Jingle in the clear.
    @Test func aFileForAnOMEMOContactNeverGoesOverJingle() async throws {
        let (media, _) = try Self.mediaRig()
        defer { media.cleanUp() }
        let environment = MediaEnvironment(
            directory: media.library.directory, transport: media.transport,
            bytestreams: FakeBytestreamNetwork())
        let harness = try await Self.harnessWithBob(environment, encryption: .omemo)
        let file = try media.file("notes.txt", Data("secret".utf8))

        let sent = try await harness.session.sendFile(
            url: file, to: try JID("\(Self.bob)/phone"))

        guard case .message(let id) = sent else {
            Issue.record("sent over Jingle: \(sent)")
            return
        }
        #expect(try harness.database.message(id: id)?.encryption == .omemo)
        #expect(media.transport.uploads.first?.body.count == 6 + 16)
        #expect(
            !harness.server.stanzas.contains {
                $0.child("jingle", namespace: "urn:xmpp:jingle:1") != nil
            })
        await harness.stop()
    }

    /// Without OMEMO the same call offers the file over Jingle.
    @Test func aFileForAContactsDeviceIsOfferedOverJingle() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await Self.harnessWithBob(environment)
        let file = try media.file("notes.txt", Data("plain".utf8))

        _ = try? await harness.session.sendFile(url: file, to: try JID("\(Self.bob)/phone"))

        #expect(
            harness.server.stanzas.contains {
                $0.child("jingle", namespace: "urn:xmpp:jingle:1")?[attribute: "action"]
                    == "session-initiate"
            })
        #expect(media.transport.uploads.isEmpty)
        await harness.stop()
    }

    /// Our room rows carry the nick the room gave this join (here "alice_" after a conflict),
    /// which the archive's copy is matched by.
    @Test func roomRowsRecordTheNickTheRoomGaveUs() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let room = "room@conference.example.test"
        let harness = try await SessionHarness(media: environment) { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: room, kind: .room)
            chat.nick = "alice"
            try database.updateChat(chat)
        }
        await harness.session.setRoomLifecycle(
            FakeRoomLifecycle(
                state: .joined, own: RoomOccupant(jid: try JID("\(room)/alice_"), occupantID: nil)))
        harness.server.setResponder(Self.uploadResponder)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(room)?.id)

        let text = try await harness.session.send(text: "hi", chatID: chatID)
        let file = try await harness.session.sendFile(
            url: try media.file("notes.txt", Data("x".utf8)), chatID: chatID)

        #expect(try harness.database.message(id: text)?.senderNick == "alice_")
        #expect(try harness.database.message(id: file)?.senderNick == "alice_")
        await harness.stop()
    }
}

extension SessionFilesTests {
    /// The size limit set in the app reaches a running session: "always ask" (0) stops
    /// automatic downloads from then on.
    @Test func aChangedSizeLimitReachesTheRunningSession() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        var options = SessionServer.Options()
        options.roster = .items(["<item jid='\(Self.bob)' subscription='both'/>"], version: "v2")
        let harness = try await SessionHarness(options: options, media: environment)
        let link = MediaRig.url("https://files.example.test/bob/a.png")
        media.transport.serve(link, data: MediaRig.bytes(10))
        try await harness.goOnline()

        await harness.session.update(
            settings: SessionSettings(media: MediaPolicy(automaticDownloadLimit: 0)))
        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='f1'>"
                + "<body>\(link)</body><x xmlns='jabber:x:oob'><url>\(link)</url></x></message>")
        try await harness.barrier()
        try await Task.sleep(for: .milliseconds(20))

        #expect(media.transport.requests.isEmpty)
        await harness.stop()
    }
}

// MARK: - Fix round 1b (M5, R43)

extension SessionFilesTests {
    /// A file row as the upload service leaves it: pending, its attachment uploading.
    static func uploadingRow(_ harness: SessionHarness, chatID: Int64, originID: String) throws
        -> Int64
    {
        try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: originID,
                senderJID: Self.me, body: nil, timestamp: Date(), kind: .file,
                attachments: [AttachmentDraft(localPath: "/nowhere", state: .uploading)]))
    }

    static func fileStanza(originID: String) throws -> Element {
        var stanza = ChatMessage.text(Self.get, to: try JID(Self.bob), type: .chat, id: originID)
        stanza.append(OOB.element(url: MediaRig.url(Self.get)))
        return stanza
    }

    /// The upload finished while the session was down; the reconnect flush sends the message,
    /// and then the upload hands it over too: one message on the wire, not two.
    @Test func aReconnectFlushRacingTheEndOfAnUploadSendsOnce() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try Self.uploadingRow(harness, chatID: chatID, originID: "file-1")
        let attachment = try #require(try harness.database.attachments(messageID: id).first?.id)

        // The session drops for good and comes back while the upload ends.
        harness.server.update { $0.resumeSucceeds = false }
        try harness.database.finishAttachmentUpload(
            id: attachment, remoteURL: Self.get, aesgcmKey: nil)
        try await harness.drop()
        try await waitUntil("fresh session") { await harness.session.progress.started == 2 }
        await harness.session.deliverFile(
            messageID: id, stanza: try Self.fileStanza(originID: "file-1"))
        try await harness.barrier()

        #expect(harness.server.messages(id: "file-1").count == 1)
        await harness.stop()
    }

    /// A flush never sends a file that is still going up; the end of the upload sends it,
    /// once.
    @Test func aFlushSkipsAFileStillUploadingAndItsEndSendsItOnce() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try Self.uploadingRow(harness, chatID: chatID, originID: "file-2")
        let attachment = try #require(try harness.database.attachments(messageID: id).first?.id)

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("fresh session") { await harness.session.progress.started == 2 }
        try await harness.barrier()
        #expect(harness.server.messages(id: "file-2").isEmpty)

        try harness.database.finishAttachmentUpload(
            id: attachment, remoteURL: Self.get, aesgcmKey: nil)
        await harness.session.deliverFile(
            messageID: id, stanza: try Self.fileStanza(originID: "file-2"))
        await harness.session.deliverFile(
            messageID: id, stanza: try Self.fileStanza(originID: "file-2"))
        try await harness.barrier()

        let sent = harness.server.messages(id: "file-2")
        #expect(sent.count == 1)
        #expect(sent.first?.child("x", namespace: OOB.namespace) != nil)
        await harness.stop()
    }
}

// MARK: - Fix round 2

extension SessionFilesTests {
    /// N4: a file for a contact's device goes over Jingle only when the chat is known not to
    /// have OMEMO on; when the chat cannot be read, nothing is sent.
    @Test func theRouteOfAFileForADeviceFailsClosed() throws {
        struct Broken: Error {}
        #expect(throws: SessionError.storage("Broken")) {
            try AccountSession.fileRoute { throw Broken() }
        }
        var chat = ChatRecord(
            id: 7, accountID: 1, jid: Self.bob, kind: .direct, name: nil, pinned: false,
            muted: false, notify: .all, draft: nil, encryption: .omemo, nick: nil,
            password: nil, autojoin: false, lastActivity: nil, unreadCount: 0, mentionCount: 0,
            lastReadMessageID: nil, avatarHash: nil)
        #expect(try AccountSession.fileRoute { chat } == .upload(chatID: 7))
        chat.encryption = .none
        #expect(try AccountSession.fileRoute { chat } == .jingle)
        #expect(try AccountSession.fileRoute { nil } == .jingle)
    }

    /// M5 review: a file row whose attachment is gone cannot be sent: it fails instead of
    /// waiting for ever.
    @Test func aFileRowWithoutItsFileIsMarkedFailed() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let id = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "file-3",
                senderJID: Self.me, body: nil, timestamp: Date(), kind: .file))

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("fresh session") { await harness.session.progress.started == 2 }
        try await harness.barrier()

        #expect(try harness.database.message(id: id)?.state == .failed)
        #expect(harness.server.messages(id: "file-3").isEmpty)
        await harness.stop()
    }

    /// M5 review: a file message sent again after a restart (the upload's stanza is gone)
    /// still carries its file sharing metadata.
    @Test func aFileSentAfterARestartKeepsItsFileSharing() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        let harness = try await Self.harnessWithBob(environment)
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        let bytes = Data("the notes".utf8)
        let (path, hash) = try media.library.store(bytes)
        let id = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "file-4",
                senderJID: Self.me, body: nil, timestamp: Date(), kind: .file,
                attachments: [
                    AttachmentDraft(
                        remoteURL: Self.get, localPath: path.path, mimeType: "text/plain",
                        byteSize: Int64(bytes.count), fileName: "notes.txt", state: .local)
                ]))
        _ = id

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("sent") { !harness.server.messages(id: "file-4").isEmpty }

        let sent = try #require(harness.server.messages(id: "file-4").first)
        #expect(sent.child("x", namespace: OOB.namespace) != nil)
        let sharing = try #require(
            sent.child("file-sharing", namespace: StatelessFileSharing.namespace).flatMap(
                StatelessFileSharing.parse))
        #expect(sharing.file.name == "notes.txt")
        #expect(sharing.file.size == Int64(bytes.count))
        #expect(sharing.file.mediaType == "text/plain")
        #expect(sharing.file.hashes.first?.value == hash)
        #expect(sharing.urls.map(\.absoluteString) == [Self.get])
        await harness.stop()
    }
}

extension SessionFilesTests {
    /// N7: when the server takes one of our messages, the time it went out is kept.
    @Test func anAcknowledgedMessageKeepsWhenItWentOut() async throws {
        var options = SessionServer.Options()
        options.answersAckRequests = true
        let written = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = try await SessionHarness(options: options) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
            _ = try database.insertOutgoing(
                OutgoingMessage(
                    accountID: accountID, chatID: try #require(chat.id), originID: "late-1",
                    senderJID: Self.me, body: "written offline", timestamp: written))
        }

        try await harness.goOnline()
        try await waitUntil("acknowledged") {
            try harness.message(originID: "late-1")?.state == .sent
        }

        let row = try #require(try harness.message(originID: "late-1"))
        #expect(row.timestamp == written)
        #expect(row.receivedAt.timeIntervalSince(written) > 3600)
        await harness.stop()
    }
}

extension SessionFilesTests {
    /// N13: a stopped session (an account removed or disabled) leaves no download running:
    /// once `stop()` returns, no file of it appears.
    @Test func aStoppedSessionLeavesNoDownloadBehind() async throws {
        let (media, environment) = try Self.mediaRig()
        defer { media.cleanUp() }
        var options = SessionServer.Options()
        options.roster = .items(["<item jid='\(Self.bob)' subscription='both'/>"], version: "v2")
        let harness = try await SessionHarness(options: options, media: environment)
        let link = MediaRig.url("https://files.example.test/bob/big.bin")
        media.transport.serve(link, data: MediaRig.bytes(3000), chunk: 1000)
        media.transport.closeDownloadGate()
        try await harness.goOnline()
        try harness.deliver(
            "<message from='\(Self.bob)/phone' to='\(Self.me)' type='chat' id='f9'>"
                + "<body>\(link)</body><x xmlns='jabber:x:oob'><url>\(link)</url></x></message>")
        try await waitUntil("downloading") { media.transport.chunksRead(link) == 1 }

        await harness.session.stop()

        #expect(media.libraryFiles().isEmpty)
        media.transport.openDownloadGate()
        try await Task.sleep(for: .milliseconds(30))
        #expect(media.libraryFiles().isEmpty)
        await harness.stop()
    }
}
