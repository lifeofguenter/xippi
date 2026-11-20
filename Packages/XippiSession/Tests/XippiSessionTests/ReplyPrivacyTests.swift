import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// R63 (b): a reply's fallback never quotes content that arrived encrypted unless the reply
/// is encrypted too, and never a file's link. I5: a message that is only its file's link
/// keeps no body, so the link shows nowhere as text.
@Suite struct ReplyPrivacyTests {
    static let bob = "bob@example.test"
    static let phone = "bob@example.test/phone"
    static let key = String(repeating: "ab", count: 44)
    static let secretLink = "aesgcm://files.example.test/u/photo.jpg#" + key

    static func origin(_ id: String) -> String {
        "<origin-id xmlns='urn:xmpp:sid:0' id='\(id)'/>"
    }

    /// Bob's chat, in the clear by the user's choice.
    static func harness() async throws -> SessionHarness {
        try await SessionHarness(
            options: .init(
                roster: .items([AccountSessionTests.rosterItem(bob, "both")], version: "v1"))
        ) { database, accountID in
            let chat = try database.ensureChat(accountID: accountID, jid: bob, kind: .direct)
            try database.setEncryptionDefault(chatID: try #require(chat.id), omemo: false)
        }
    }

    static func received(
        _ harness: SessionHarness, body: String?, encryption: EncryptionMode,
        kind: MessageKind = .text, files: [AttachmentDraft] = [], id: String
    ) throws -> Int64 {
        let chatID = try #require(try harness.chat(bob)?.id)
        let outcome = try harness.database.upsertIncoming(
            IncomingMessage(
                accountID: harness.accountID, chatID: chatID, senderJID: phone, body: body,
                originID: id, stanzaMessageID: id, timestamp: Date(), encryption: encryption,
                kind: kind, attachments: files))
        return try #require(outcome.messageID)
    }

    /// Replies "nice" to `target`; the stored reply and the stanza that went out.
    static func reply(_ harness: SessionHarness, to target: Int64) async throws
        -> (MessageRecord, Element)
    {
        let chatID = try #require(try harness.chat(bob)?.id)
        let id = try await harness.session.send(text: "nice", chatID: chatID, replyTo: target)
        let row = try #require(try harness.database.message(id: id))
        let originID = try #require(row.originID)
        return (row, try await OMEMOPipelineTests.sent(originID, by: harness))
    }

    @Test func aPlainReplyToAnEncryptedMessageQuotesNothing() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let target = try Self.received(
            harness, body: "the secret plan", encryption: .omemo, id: "t1")

        let (row, sent) = try await Self.reply(harness, to: target)
        #expect(sent.child("body")?.text == "nice")
        #expect(!sent.xml().contains("secret"))
        #expect(
            sent.child("reply", namespace: ChatMessage.replyNamespace)?[attribute: "id"] == "t1")
        #expect(sent.child("fallback", namespace: ChatMessage.fallbackNamespace) == nil)
        // Here the reply still shows what it answers.
        #expect(row.replyQuote == "the secret plan")
        await harness.stop()
    }

    @Test func aReplyToAnEncryptedFileNeverSendsItsLink() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        // As stored before file links lost their body, and as stored now.
        for (index, body) in [Self.secretLink, nil].enumerated() {
            let target = try Self.received(
                harness, body: body, encryption: .omemo, kind: .file,
                files: [
                    AttachmentDraft(
                        remoteURL: Self.secretLink, fileName: "photo.jpg", state: .remote)
                ], id: "f\(index)")
            let (row, sent) = try await Self.reply(harness, to: target)
            #expect(!sent.xml().contains("aesgcm"))
            #expect(!sent.xml().contains(Self.key))
            #expect(!sent.xml().contains("photo.jpg"))
            #expect(sent.child("body")?.text == "nice")
            #expect(row.replyQuote == "photo.jpg")
        }
        await harness.stop()
    }

    @Test func aReplyToAPlainFileQuotesItsNameNotItsLink() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let link = "https://files.example.test/u/plan.png"
        let target = try Self.received(
            harness, body: link, encryption: .none, kind: .file,
            files: [AttachmentDraft(remoteURL: link, fileName: "plan.png", state: .remote)],
            id: "p1")

        let (row, sent) = try await Self.reply(harness, to: target)
        #expect(sent.child("body")?.text == "> plan.png\nnice")
        #expect(!sent.xml().contains("https://files.example.test"))
        #expect(row.replyQuote == "plan.png")
        await harness.stop()
    }

    @Test func aQueuedPlainReplyQuotesNothingEncryptedEither() async throws {
        let harness = try await Self.harness()
        let target = try Self.received(
            harness, body: "the secret plan", encryption: .omemo, id: "t1")
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        // Written while offline: it goes out with the next session.
        let id = try await harness.session.send(text: "nice", chatID: chatID, replyTo: target)
        let originID = try #require(try harness.database.message(id: id)?.originID)

        try await harness.goOnline()
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        #expect(sent.child("body")?.text == "nice")
        #expect(!sent.xml().contains("secret"))
        await harness.stop()
    }

    @Test func aReplyFlushedAfterAReconnectQuotesNothingEncrypted() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let target = try Self.received(
            harness, body: "the secret plan", encryption: .omemo, id: "t1")
        // Written while the stream was down: stored, with its quote for this Mac, and never
        // handed to the connection.
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "q1",
                senderJID: SessionServer.fullJID, body: "nice", timestamp: Date(),
                replyToMessageID: target, replyToSenderLabel: "bob", replyQuote: "the secret plan"))

        harness.server.update { $0.resumeSucceeds = false }
        try await harness.drop()
        try await waitUntil("a fresh session") { await harness.session.progress.started == 2 }
        let sent = try await OMEMOPipelineTests.sent("q1", by: harness)
        #expect(sent.child("body")?.text == "nice")
        #expect(!sent.xml().contains("secret"))
        #expect(
            sent.child("reply", namespace: ChatMessage.replyNamespace)?[attribute: "id"] == "t1")
        #expect(try harness.message(originID: "q1")?.replyQuote == "the secret plan")
        await harness.stop()
    }

    @Test func aReplyToOurFileShowsItsNameNotTheQuotedLink() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        _ = try harness.database.insertOutgoing(
            OutgoingMessage(
                accountID: harness.accountID, chatID: chatID, originID: "f1",
                senderJID: SessionServer.fullJID, body: nil, timestamp: Date(),
                encryption: .omemo, kind: .file,
                attachments: [
                    AttachmentDraft(
                        remoteURL: Self.secretLink, fileName: "photo.jpg", state: .local)
                ]))
        // Bob's client quotes the link it got.
        var answer = ChatMessage.text(
            "nice", to: try JID(SessionServer.fullJID),
            id: "r1", reply: ChatMessage.Reply(to: nil, id: "f1"),
            quote: Self.secretLink)
        answer[attribute: "from"] = Self.phone
        try harness.deliver(answer.xml())

        try await waitUntil("stored") { try harness.message(originID: "r1") != nil }
        let row = try #require(try harness.message(originID: "r1"))
        #expect(row.body == "nice")
        #expect(row.replyQuote == "photo.jpg")
        await harness.stop()
    }

    @Test func aQuotedLinkToAMessageNotHereIsDropped() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        var answer = ChatMessage.text(
            "nice", to: try JID(SessionServer.fullJID),
            id: "r2", reply: ChatMessage.Reply(to: nil, id: "gone"),
            quote: Self.secretLink)
        answer[attribute: "from"] = Self.phone
        try harness.deliver(answer.xml())

        try await waitUntil("stored") { try harness.message(originID: "r2") != nil }
        let row = try #require(try harness.message(originID: "r2"))
        #expect(row.body == "nice")
        #expect(row.replyQuote == nil)
        await harness.stop()
    }

    // MARK: I5: the link is the attachment's, never the body

    @Test func anIncomingFileLinkKeepsNoBody() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let link = "https://files.example.test/u/plan.png"
        try harness.deliver(
            "<message from='\(Self.phone)' to='\(SessionServer.fullJID)' type='chat' id='a1'>"
                + "<body>\(Self.secretLink)</body>\(Self.origin("a1"))</message>")
        try harness.deliver(
            "<message from='\(Self.phone)' to='\(SessionServer.fullJID)' type='chat' id='a2'>"
                + "<body>\(link)</body><x xmlns='jabber:x:oob'><url>\(link)</url></x>"
                + "\(Self.origin("a2"))</message>")
        // A carbon of one sent from another device of ours.
        try harness.deliver(
            OMEMOPipelineTests.sentCarbon(
                "<message from='\(SessionServer.account)/phone' to='\(Self.bob)' type='chat'"
                    + " id='a3'><body>\(Self.secretLink)</body>\(Self.origin("a3"))</message>"))

        try await waitUntil("stored") {
            try ["a1", "a2", "a3"].allSatisfy { try harness.message(originID: $0) != nil }
        }
        for id in ["a1", "a2", "a3"] {
            let row = try #require(try harness.message(originID: id))
            #expect(row.body == nil, "\(id)")
            #expect(row.kind == .file, "\(id)")
            let file = try #require(try harness.database.attachments(messageID: row.id ?? -1).first)
            #expect(file.remoteURL == (id == "a2" ? link : Self.secretLink), "\(id)")
        }
        #expect(try harness.database.search("aesgcm").isEmpty)
        await harness.stop()
    }

    static func parsed(_ xml: String) throws -> ChatMessage {
        let element = try #require(SessionServer.elements(xml).first)
        return try #require(ChatMessage(element: element))
    }

    @Test func wordsAroundALinkStayTheBody() throws {
        let link = "https://files.example.test/u/plan.png"
        let message = try Self.parsed(
            "<message type='chat'><body>Look \(link)</body>"
                + "<x xmlns='jabber:x:oob'><url>\(link)</url></x></message>")
        #expect(AccountSession.content(of: message)?.body == "Look \(link)")
        // An archived copy goes through the same reading: only the link, no body.
        let archived = try Self.parsed(
            "<message type='chat'><body> \(Self.secretLink)\n</body></message>")
        let file = AccountSession.content(of: archived)
        #expect(file?.body == nil)
        #expect(file?.kind == .file)
        #expect(file?.attachments.first?.remoteURL == Self.secretLink)
    }

    // MARK: The rule

    @Test func onlyAnEncryptedReplyQuotesWhatCameEncrypted() {
        #expect(ReplyQuote.goesOut(targetEncryption: .none, replyEncrypted: false))
        #expect(ReplyQuote.goesOut(targetEncryption: .none, replyEncrypted: true))
        #expect(ReplyQuote.goesOut(targetEncryption: .omemo, replyEncrypted: true))
        #expect(!ReplyQuote.goesOut(targetEncryption: .omemo, replyEncrypted: false))
    }

    @Test func aQuoteIsTheTextOrTheFilesName() {
        #expect(ReplyQuote.text(body: "hello", fileName: nil) == "hello")
        #expect(ReplyQuote.text(body: nil, fileName: "a.png") == "a.png")
        #expect(
            ReplyQuote.text(body: Self.secretLink, fileName: "a.png", link: Self.secretLink)
                == "a.png")
        #expect(ReplyQuote.text(body: nil, fileName: nil) == nil)
        #expect(ReplyQuote.received(Self.secretLink) == nil)
        #expect(ReplyQuote.received(" \(Self.secretLink) ") == nil)
        #expect(ReplyQuote.received("see aesgcm links") == "see aesgcm links")
    }
}
