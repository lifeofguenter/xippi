import Foundation
import Testing

@testable import XMPPCore

@Suite struct ChatMessageTests {
    static func message(_ file: String, _ name: String) throws -> ChatMessage {
        try #require(ChatMessage(element: try ModuleFixtures.stanza(file, name)))
    }

    /// The message inside the first `<forwarded/>` of a MAM result fixture.
    static func archived(_ file: String, _ name: String) throws -> ChatMessage {
        let outer = try ModuleFixtures.stanza(file, name)
        let forwarded = try #require(outer.child("result")?.child("forwarded"))
        let (inner, _) = try #require(Forwarded.parse(forwarded))
        return try #require(ChatMessage(element: inner))
    }

    static func withFallback(body: String, start: String, end: String) -> Element {
        Element.message(
            to: try? JID("juliet@capulet.lit"), body: body,
            children: [
                Element(
                    "reply", namespace: ChatMessage.replyNamespace,
                    attributes: ["to": "romeo@montague.lit/orchard", "id": "m1"]),
                Element(
                    "fallback", namespace: ChatMessage.fallbackNamespace,
                    attributes: ["for": ChatMessage.replyNamespace],
                    children: [
                        .element(
                            Element(
                                "body", namespace: ChatMessage.fallbackNamespace,
                                attributes: ["start": start, "end": end]))
                    ]),
            ])
    }

    // MARK: Basics

    @Test func plainMessage() throws {
        let message = try Self.message("xep-0308-1.2.1", "original")
        #expect(message.id == "bad1")
        #expect(message.to == (try JID("juliet@capulet.net/balcony")))
        #expect(message.type == .normal)
        #expect(message.body == "But soft, what light through yonder airlock breaks?")
        #expect(message.correctionOf == nil)
        #expect(message.fallbacks.isEmpty)
        #expect(message.stanzaIDs.isEmpty)
        #expect(!message.receiptRequest)
        #expect(!message.markable)
    }

    @Test func typeDefaultsToNormal() throws {
        var element = Element.message(type: nil, body: "x")
        #expect(ChatMessage(element: element)?.type == .normal)
        element[attribute: "type"] = "bogus"
        #expect(ChatMessage(element: element)?.type == .normal)
        element[attribute: "type"] = "groupchat"
        #expect(ChatMessage(element: element)?.type == .groupchat)
    }

    @Test func refusesWhatIsNotAMessage() {
        #expect(ChatMessage(element: Element("presence")) == nil)
        var element = Element.message(body: "x")
        element[attribute: "from"] = "@bad"
        #expect(ChatMessage(element: element) == nil)
        element[attribute: "from"] = nil
        element[attribute: "to"] = "a@b/"
        #expect(ChatMessage(element: element) == nil)
    }

    @Test func errorMessage() throws {
        var element = Element.message(type: "error", body: "x")
        element.append(StanzaError(type: .cancel, condition: .serviceUnavailable).element)
        let message = try #require(ChatMessage(element: element))
        #expect(message.type == .error)
        #expect(message.isError)
        #expect(message.error == StanzaError(type: .cancel, condition: .serviceUnavailable))
        #expect(message.body == nil)
    }

    // MARK: Error bounces (RFC 6120 8.3.1: our own payload comes back with the peer as `from`)

    static let romeo = "romeo@capulet.net/orchard"

    static func bounce(_ sent: Element) throws -> ChatMessage {
        let bounce = sent.errorResponse(StanzaError(type: .cancel, condition: .serviceUnavailable))
        let message = try #require(ChatMessage(element: bounce))
        #expect(message.isError)
        #expect(message.from == (try JID(romeo)))
        #expect(message.error == StanzaError(type: .cancel, condition: .serviceUnavailable))
        return message
    }

    @Test func bouncedReactionIsNoReaction() throws {
        let sent = ChatMessage.reaction(
            ["👋"], toMessage: "m1", to: try JID(Self.romeo), id: "r1")
        let message = try Self.bounce(sent)
        #expect(message.reactions == nil)
        #expect(!message.store)
        // Enough is kept to tie the bounce to what was sent.
        #expect(message.id == "r1")
        #expect(message.originID == "r1")
    }

    @Test func bouncedCorrectionIsNoCorrection() throws {
        let sent = ChatMessage.correction(
            "fixed", replacing: "bad1", to: try JID(Self.romeo), id: "good1")
        let message = try Self.bounce(sent)
        #expect(message.correctionOf == nil)
        #expect(message.body == nil)
        #expect(!message.receiptRequest)
        #expect(!message.markable)
        #expect(message.originID == "good1")
    }

    @Test func bouncedTextAndMarkersCarryNoContent() throws {
        let romeo = try JID(Self.romeo)
        let text = try Self.bounce(
            ChatMessage.text(
                "reply", to: romeo, thread: "t1", reply: ChatMessage.Reply(to: romeo, id: "m0"),
                quote: "hello"))
        #expect(text.body == nil)
        #expect(text.reply == nil)
        #expect(text.fallbacks.isEmpty)
        #expect(text.chatState == nil)
        #expect(text.thread == "t1")
        #expect(try Self.bounce(ChatMessage.retraction(of: "m0", to: romeo)).retraction == nil)
        #expect(try Self.bounce(ChatMessage.displayed("m0", to: romeo)).displayedFor == nil)
        var request = try #require(
            ChatMessage(element: try ModuleFixtures.stanza("xep-0184-1.4.0", "request")))
        request.from = romeo
        let receipt = try #require(ChatMessage.receipt(for: request))
        #expect(try Self.bounce(receipt).receiptFor == nil)
        #expect(try Self.bounce(ChatStates.message(.composing, to: romeo)).chatState == nil)
    }

    @Test func bouncedExtensionsAreIgnored() throws {
        let sent = Element.message(
            to: try JID(Self.romeo), body: "x",
            children: [
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "capulet.net", "id": "s1"]),
                Delay.element(stamp: try xmppDate("2002-09-10T23:08:25Z")),
                Element("encrypted", namespace: "urn:xmpp:omemo:2"),
                Element(
                    "x", namespace: ChatMessage.oobNamespace,
                    children: [
                        .element(
                            Element(
                                "url", namespace: ChatMessage.oobNamespace,
                                children: [.text("https://example.com/a.png")]))
                    ]),
                Element(
                    "occupant-id", namespace: MUCPresence.occupantIDNamespace,
                    attributes: ["id": "o1"]),
                Element("file-sharing", namespace: ChatMessage.sfsNamespace),
                Element("nick", namespace: ChatMessage.nickNamespace, children: [.text("Romeo")]),
            ])
        let message = try Self.bounce(sent)
        #expect(message.stanzaIDs.isEmpty)
        #expect(message.delays.isEmpty)
        #expect(message.encrypted == nil)
        #expect(message.oob.isEmpty)
        #expect(message.occupantID == nil)
        #expect(message.sfs == nil)
        #expect(message.nick == nil)
    }

    // MARK: Delays (XEP-0203)

    @Test func offlineDelayFromTheServer() throws {
        let offline = try Self.message("xep-0203-2.0", "offline-message")
        let server = try JID("capulet.com")
        let stamp = try xmppDate("2002-09-10T23:08:25Z")
        #expect(offline.delays == [Delay.Stamp(stamp: stamp, from: server)])
        #expect(offline.delay(trusting: [server]) == stamp)
        #expect(offline.delay(trusting: []) == nil)
        #expect(offline.delay(trusting: [try JID("romeo@montague.net")]) == nil)
    }

    /// Room history: the room appends its delay after whatever the occupant put in the message,
    /// including one that names the room. Only the room's own, the last, counts.
    @Test func roomHistoryUsesTheRoomsDelay() throws {
        var element = try ModuleFixtures.stanza("xep-0203-2.0", "room-history")
        let forged = [
            Element(
                "delay", namespace: Delay.namespace, attributes: ["stamp": "1990-01-01T00:00:00Z"]),
            Element(
                "delay", namespace: Delay.namespace,
                attributes: [
                    "stamp": "1991-01-01T00:00:00Z",
                    "from": "coven@macbeth.shakespeare.lit/secondwitch",
                ]),
            Element(
                "delay", namespace: Delay.namespace,
                attributes: [
                    "stamp": "2099-01-01T00:00:00Z", "from": "coven@macbeth.shakespeare.lit",
                ]),
        ]
        element.children = forged.map { .element($0) } + element.children
        let message = try #require(ChatMessage(element: element))
        let room = try JID("coven@macbeth.shakespeare.lit")
        #expect(message.delays.count == 4)
        #expect(message.delays.first == Delay.Stamp(stamp: try xmppDate("1990-01-01T00:00:00Z")))
        #expect(message.delay(trusting: [room]) == (try xmppDate("2002-09-10T23:05:37Z")))
        #expect(message.delay(trusting: [try JID("macbeth@shakespeare.lit")]) == nil)
    }

    @Test func threadAndNick() throws {
        #expect(try Self.message("xep-0333-1.0.0", "muc-markable").thread == "Act IV, Scene I")
        #expect(try Self.message("xep-0172-1.1", "message-with-nick").nick == "Ishmael")
    }

    // MARK: Corrections, stanza IDs

    @Test func correction() throws {
        #expect(try Self.message("xep-0308-1.2.1", "correction").correctionOf == "bad1")
        let element = Element.message(
            body: "fixed",
            children: [
                Element(
                    "replace", namespace: ChatMessage.correctionNamespace, attributes: ["id": "a"])
            ])
        #expect(ChatMessage(element: element)?.correctionOf == "a")
    }

    @Test func originAndStanzaIDs() throws {
        let origin = try Self.message("xep-0359-0.7.0", "origin-id")
        #expect(origin.originID == "de305d54-75b4-431b-adb2-eb6b9e546013")
        let message = try Self.message("xep-0359-0.7.0", "stanza-id")
        #expect(
            message.stanzaIDs == [
                try JID("room@muc.example.com"): "5f3dbc5e-e1d3-4077-a492-693f3769c7ad"
            ])
        #expect(
            message.stanzaID(by: try JID("room@muc.example.com"))
                == "5f3dbc5e-e1d3-4077-a492-693f3769c7ad")
    }

    @Test func stanzaIDsAreFilteredByTheCaller() throws {
        let room = try JID("room@muc.example.com")
        let server = try JID("juliet@capulet.lit")
        let element = Element.message(
            type: "groupchat", body: "x",
            children: [
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "room@muc.example.com", "id": "r1"]),
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "juliet@capulet.lit", "id": "s1"]),
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "mallory@evil", "id": "m1"]),
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "@bad", "id": "b1"]),
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "nobody@example.com"]),
            ])
        let message = try #require(ChatMessage(element: element))
        #expect(message.stanzaIDs.count == 3)
        #expect(message.stanzaIDs(trusting: [room]) == [room: "r1"])
        #expect(message.stanzaIDs(trusting: [room, server]) == [room: "r1", server: "s1"])
        #expect(message.stanzaIDs(trusting: []) == [:])
        #expect(message.stanzaID(by: try JID("other@example.com")) == nil)
    }

    /// Two different ids from one archive cannot both be right: neither is trusted.
    @Test func conflictingStanzaIDsFromOneArchiveAreDropped() throws {
        let element = Element.message(
            body: "x",
            children: [
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "juliet@capulet.lit", "id": "a"]),
                Element(
                    "stanza-id", namespace: ChatMessage.stanzaIDNamespace,
                    attributes: ["by": "juliet@capulet.lit", "id": "b"]),
            ])
        #expect(ChatMessage(element: element)?.stanzaIDs == [:])
    }

    // MARK: Receipts, markers, chat states, hints

    @Test func receiptsMarkersAndChatStates() throws {
        let request = try Self.message("xep-0184-1.4.0", "request")
        #expect(request.receiptRequest)
        #expect(request.id == "richard2-4.1.247")
        #expect(try Self.message("xep-0184-1.4.0", "receipt").receiptFor == "richard2-4.1.247")

        let markable = try Self.message("xep-0333-1.0.0", "markable")
        #expect(markable.markable)
        #expect(markable.receiptRequest)
        #expect(try Self.message("xep-0333-1.0.0", "displayed").displayedFor == "the-msg-1")
        let mucDisplayed = try Self.message("xep-0333-1.0.0", "muc-displayed")
        #expect(mucDisplayed.displayedFor == "39K7ZYIp")
        #expect(mucDisplayed.type == .groupchat)

        #expect(try Self.message("xep-0085-2.1", "active-with-body").chatState == .active)
        #expect(try Self.message("xep-0085-2.1", "standalone-composing").chatState == .composing)
    }

    @Test func hints() throws {
        let message = try Self.message("xep-0334-1.0.0", "no-copy-no-store")
        #expect(message.noCopy)
        #expect(message.noStore)
        #expect(!message.store)
        #expect(!message.noPermanentStore)
    }

    // MARK: Retraction and moderation

    @Test func retraction() throws {
        let message = try Self.message("xep-0424-0.5.0", "retraction")
        #expect(message.retraction == "wrong-recipient-1")
        #expect(message.moderation == nil)
        #expect(message.store)
        #expect(
            message.fallbacks
                == [
                    ChatMessage.Fallback(
                        namespace: ChatMessage.retractionNamespace, body: [.whole],
                        subject: [.whole])
                ])
        #expect(message.bodyWithoutFallback(for: ChatMessage.retractionNamespace) == "")
    }

    @Test func retractionTombstone() throws {
        let message = try Self.archived("xep-0424-0.5.0", "tombstone")
        #expect(message.retraction == nil)
        #expect(
            message.tombstone
                == ChatMessage.Tombstone(
                    stamp: try xmppDate("2019-09-20T23:09:32Z"), retractionID: "retract-message-1"))
    }

    @Test func moderation() throws {
        let message = try Self.message("xep-0425-0.3.1", "moderation")
        #expect(message.retraction == "stanza-id-1")
        #expect(
            message.moderation
                == ChatMessage.Moderation(
                    by: try JID("room@muc.example.com/macbeth"),
                    occupantID: "dd72603deec90a38ba552f7c68cbcc61bca202cd",
                    reason: "This message contains inappropriate content for this forum"))
    }

    /// Only the room itself moderates; an occupant's message carrying a moderation is dropped.
    @Test func moderationFromAnOccupantIsDropped() throws {
        var element = try ModuleFixtures.stanza("xep-0425-0.3.1", "moderation")
        element[attribute: "from"] = "room@muc.example.com/oldhag"
        let message = try #require(ChatMessage(element: element))
        #expect(message.retraction == nil)
        #expect(message.moderation == nil)
    }

    @Test func moderationTombstones() throws {
        let message = try Self.archived("xep-0425-0.3.1", "tombstone")
        #expect(message.occupantID == "ef73b09de9c90a38ba552f7c68cbeef1dca24429")
        #expect(
            message.tombstone
                == ChatMessage.Tombstone(
                    stamp: try xmppDate("2019-09-20T23:19:12Z"),
                    moderation: ChatMessage.Moderation(
                        by: try JID("witch@shakespeare.example"),
                        occupantID: "dd72603deec90a38ba552f7c68cbcc61bca202cd",
                        reason: "This message contains inappropriate content for this forum")))
        let correction = try Self.archived("xep-0425-0.3.1", "correction-tombstone")
        #expect(correction.correctionOf == "message-id-1")
        #expect(correction.tombstone?.moderation?.by == (try JID("witch@shakespeare.example")))
    }

    // MARK: Reactions, replies, fallbacks

    @Test func reactions() throws {
        let file = "xep-0444-0.2.1"
        let first = try Self.message(file, "reaction")
        #expect(
            first.reactions
                == ChatMessage.Reactions(
                    messageID: "744f6e18-a57a-11e9-a656-4889e7820c76", reactions: ["👋"]))
        #expect(first.store)
        #expect(try Self.message(file, "update").reactions?.reactions == ["👋", "🐢"])
        let removed = try Self.message(file, "remove-all")
        #expect(
            removed.reactions
                == ChatMessage.Reactions(
                    messageID: "744f6e18-a57a-11e9-a656-4889e7820c76", reactions: []))
    }

    /// Duplicates are dropped; anything else is kept for the store to judge.
    @Test func reactionsKeepArbitraryTextWithoutDuplicates() throws {
        let element = Element.message(children: [
            Element(
                "reactions", namespace: ChatMessage.reactionsNamespace, attributes: ["id": "m1"],
                children: ["👍", "x", "👍", "", "❤️"].map {
                    .element(
                        Element(
                            "reaction", namespace: ChatMessage.reactionsNamespace,
                            children: [.text($0)]))
                })
        ])
        #expect(ChatMessage(element: element)?.reactions?.reactions == ["👍", "x", "❤️"])
        let noID = Element.message(children: [
            Element("reactions", namespace: ChatMessage.reactionsNamespace)
        ])
        #expect(ChatMessage(element: noID)?.reactions == nil)
    }

    @Test func replies() throws {
        // The example's second stanza is the reply.
        let reply = try #require(
            ChatMessage(element: try ModuleFixtures.stanzas("xep-0461-0.2.1", "reply")[1]))
        #expect(
            reply.reply
                == ChatMessage.Reply(to: try JID("anna@example.com/tablet"), id: "message-id1"))
        #expect(reply.body == "Great idea!")
        let withFallback = try Self.message("xep-0461-0.2.1", "reply-with-fallback")
        #expect(
            withFallback.fallbacks
                == [
                    ChatMessage.Fallback(
                        namespace: ChatMessage.replyNamespace, body: [.range(0..<38)], subject: [])
                ])
        let indication = try Self.message("xep-0428-0.2.1", "reply-fallback")
        #expect(
            indication.fallbacks
                == [
                    ChatMessage.Fallback(
                        namespace: ChatMessage.replyNamespace, body: [.range(0..<33)], subject: [])
                ])
    }

    @Test func bodyWithoutTheQuotedReply() throws {
        let element = Self.withFallback(body: "> hello\nreply", start: "0", end: "8")
        let message = try #require(ChatMessage(element: element))
        #expect(message.bodyWithoutFallback(for: ChatMessage.replyNamespace) == "reply")
        #expect(
            message.bodyWithoutFallback(for: ChatMessage.retractionNamespace) == "> hello\nreply")
    }

    /// XEP-0428 counts Unicode code points: a flag is two, not one character or four UTF-16 units.
    @Test func rangesCountCodePoints() throws {
        let element = Self.withFallback(body: "🇩🇪> hi\nyes", start: "2", end: "7")
        let message = try #require(ChatMessage(element: element))
        #expect(message.bodyWithoutFallback(for: ChatMessage.replyNamespace) == "🇩🇪yes")

        let skinTone = Self.withFallback(body: "👍🏽 > ok\nfine", start: "3", end: "8")
        #expect(
            ChatMessage(element: skinTone)?.bodyWithoutFallback(for: ChatMessage.replyNamespace)
                == "👍🏽 fine")
    }

    @Test(arguments: [
        ("0", "100", ""), ("5", "3", "> hello reply"), ("50", "60", "> hello reply"),
        ("-1", "8", "> hello reply"), ("a", "8", "> hello reply"), ("0", "", "> hello reply"),
        ("8", "8", "> hello reply"), ("2", "7", ">  reply"),
    ])
    func rangesOutsideTheBodyAreSafe(_ start: String, _ end: String, _ expected: String) throws {
        let message = try #require(
            ChatMessage(element: Self.withFallback(body: "> hello reply", start: start, end: end)))
        #expect(message.bodyWithoutFallback(for: ChatMessage.replyNamespace) == expected)
    }

    /// Many ranges over a long body: the cost follows the message size, not ranges times length.
    @Test func manyLargeRanges() throws {
        let body = String(repeating: "x", count: 200_000) + "kept"
        var fallback = Element(
            "fallback", namespace: ChatMessage.fallbackNamespace,
            attributes: ["for": ChatMessage.replyNamespace])
        for _ in 0..<5_000 {
            fallback.append(
                Element(
                    "body", namespace: ChatMessage.fallbackNamespace,
                    attributes: ["start": "0", "end": "200000"]))
        }
        let message = try #require(
            ChatMessage(element: Element.message(body: body, children: [fallback])))
        let start = ContinuousClock.now
        #expect(message.bodyWithoutFallback(for: ChatMessage.replyNamespace) == "kept")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func overlappingRangesAndAWholeBody() throws {
        var element = Element.message(body: "abcdef")
        element.append(
            Element(
                "fallback", namespace: ChatMessage.fallbackNamespace,
                attributes: ["for": "urn:example"],
                children: [
                    .element(
                        Element(
                            "body", namespace: ChatMessage.fallbackNamespace,
                            attributes: ["start": "0", "end": "3"])),
                    .element(
                        Element(
                            "body", namespace: ChatMessage.fallbackNamespace,
                            attributes: ["start": "2", "end": "4"])),
                ]))
        element.append(
            Element(
                "fallback", namespace: ChatMessage.fallbackNamespace,
                attributes: ["for": "urn:other"]))
        let message = try #require(ChatMessage(element: element))
        #expect(message.bodyWithoutFallback(for: "urn:example") == "ef")
        #expect(message.bodyWithoutFallback(for: "urn:other") == "")
    }

    // MARK: Attachments, encryption, rooms

    @Test func oob() throws {
        let message = try Self.message("xep-0066-1.6", "message-url")
        #expect(
            message.oob == [
                ChatMessage.OOBLink(
                    url: try #require(URL(string: "http://www.jabber.org/images/psa-license.jpg")))
            ])
        let bad = Element.message(children: [
            Element(
                "x", namespace: ChatMessage.oobNamespace,
                children: [
                    .element(
                        Element(
                            "url", namespace: ChatMessage.oobNamespace,
                            children: [.text("not a url")]))
                ])
        ])
        #expect(ChatMessage(element: bad)?.oob == [])
    }

    @Test func rawPayloadsAreKept() throws {
        let encrypted = Element("encrypted", namespace: "urn:xmpp:omemo:2")
        let legacy = Element("encrypted", namespace: "eu.siacs.conversations.axolotl")
        let sfs = Element("file-sharing", namespace: ChatMessage.sfsNamespace)
        let mucUser = Element("x", namespace: MUCPresence.userNamespace)
        let element = Element.message(children: [encrypted, sfs, mucUser])
        let message = try #require(ChatMessage(element: element))
        #expect(message.encrypted == encrypted)
        #expect(message.sfs == sfs)
        #expect(message.mucUser == mucUser)
        #expect(ChatMessage(element: Element.message(children: [legacy]))?.encrypted == legacy)
    }

    @Test func occupantID() throws {
        let message = try Self.message("xep-0421-1.0.1", "occupant-message")
        #expect(message.occupantID == "dd72603deec90a38ba552f7c68cbcc61bca202cd")
        #expect(message.type == .groupchat)
    }

    // MARK: Builders

    @Test func textBuilder() throws {
        let element = ChatMessage.text("Hi", to: try JID("romeo@montague.lit"), id: "m1")
        let message = try #require(ChatMessage(element: element))
        #expect(message.id == "m1")
        #expect(message.originID == "m1")
        #expect(message.type == .chat)
        #expect(message.body == "Hi")
        #expect(message.receiptRequest)
        #expect(message.markable)
        #expect(message.chatState == .active)
        #expect(message.reply == nil)

        let room = ChatMessage.text("Hi", to: try JID("room@muc.example.com"), type: .groupchat)
        let roomMessage = try #require(ChatMessage(element: room))
        #expect(!roomMessage.receiptRequest)
        #expect(roomMessage.markable)
    }

    @Test func replyBuilderQuotesAsAFallback() throws {
        let element = ChatMessage.text(
            "reply", to: try JID("romeo@montague.lit"),
            reply: ChatMessage.Reply(to: try JID("romeo@montague.lit/orchard"), id: "m0"),
            quote: "hello")
        let message = try #require(ChatMessage(element: element))
        #expect(message.body == "> hello\nreply")
        #expect(
            message.reply == ChatMessage.Reply(to: try JID("romeo@montague.lit/orchard"), id: "m0"))
        #expect(
            message.fallbacks
                == [
                    ChatMessage.Fallback(
                        namespace: ChatMessage.replyNamespace, body: [.range(0..<8)], subject: [])
                ])
        #expect(message.bodyWithoutFallback(for: ChatMessage.replyNamespace) == "reply")

        let multiline = ChatMessage.text(
            "ok", to: try JID("romeo@montague.lit"), reply: ChatMessage.Reply(to: nil, id: "m0"),
            quote: "🇩🇪 one\ntwo")
        let parsed = try #require(ChatMessage(element: multiline))
        #expect(parsed.body == "> 🇩🇪 one\n> two\nok")
        #expect(parsed.bodyWithoutFallback(for: ChatMessage.replyNamespace) == "ok")
    }

    @Test func correctionBuilder() throws {
        let element = ChatMessage.correction(
            "But soft, what light through yonder window breaks?", replacing: "bad1",
            to: try JID("juliet@capulet.net/balcony"), id: "good1")
        let message = try #require(ChatMessage(element: element))
        #expect(message.correctionOf == "bad1")
        #expect(message.id == "good1")
        #expect(message.originID == "good1")
        #expect(message.body == "But soft, what light through yonder window breaks?")
    }

    @Test func retractionBuilder() throws {
        let element = ChatMessage.retraction(
            of: "wrong-recipient-1", to: try JID("lord@capulet.example"), id: "retract-message-1")
        let expected = try ModuleFixtures.stanza("xep-0424-0.5.0", "retraction")
        let message = try #require(ChatMessage(element: element))
        let fixture = try #require(ChatMessage(element: expected))
        #expect(message.retraction == fixture.retraction)
        #expect(message.fallbacks == fixture.fallbacks)
        #expect(message.store)
        #expect(message.body == fixture.body)
        #expect(message.originID == "retract-message-1")
    }

    @Test func reactionBuilderSendsEmojiOnlyOnce() throws {
        let element = ChatMessage.reaction(
            ["👋", "👋", "nope", "🐢", "❤️"], toMessage: "744f6e18-a57a-11e9-a656-4889e7820c76",
            to: try JID("romeo@capulet.net/orchard"))
        let message = try #require(ChatMessage(element: element))
        #expect(message.reactions?.reactions == ["👋", "🐢", "❤️"])
        #expect(message.reactions?.messageID == "744f6e18-a57a-11e9-a656-4889e7820c76")
        #expect(message.store)
        #expect(message.body == nil)

        let none = ChatMessage.reaction([], toMessage: "m", to: try JID("romeo@capulet.net"))
        #expect(
            ChatMessage(element: none)?.reactions
                == ChatMessage.Reactions(messageID: "m", reactions: []))
    }

    @Test func displayedBuilder() throws {
        let expected = try ModuleFixtures.stanza("xep-0333-1.0.0", "muc-displayed")
        let element = ChatMessage.displayed(
            "39K7ZYIp", to: try JID("coven@chat.shakespeare.lit"), type: .groupchat,
            thread: "Act IV, Scene I", id: "message-2")
        #expect(element.normalized == expected.normalized(dropping: ["from"]))
    }

    @Test func receiptAnswersOnlyWhatAsksForOne() throws {
        let request = try Self.message("xep-0184-1.4.0", "request")
        let receipt = try #require(ChatMessage.receipt(for: request, id: "bi29sg183b4v"))
        let expected = try ModuleFixtures.stanza("xep-0184-1.4.0", "receipt")
        #expect(receipt.normalized == expected.normalized(dropping: ["from"]))

        var groupchat = request
        groupchat.type = .groupchat
        #expect(ChatMessage.receipt(for: groupchat) == nil)
        var error = request
        error.type = .error
        #expect(ChatMessage.receipt(for: error) == nil)
        var noID = request
        noID.id = nil
        #expect(ChatMessage.receipt(for: noID) == nil)
        var ack = request
        ack.receiptFor = "other"
        #expect(ChatMessage.receipt(for: ack) == nil)
        var noFrom = request
        noFrom.from = nil
        #expect(ChatMessage.receipt(for: noFrom) == nil)
        #expect(ChatMessage.receipt(for: try Self.message("xep-0308-1.2.1", "original")) == nil)
    }

    @Test(arguments: [
        ("👋", true), ("❤️", true), ("🇩🇪", true), ("👍🏽", true), ("👨‍👩‍👧", true), ("1️⃣", true),
        ("a", false), ("1", false), ("❤", false), ("👋👋", false), ("", false), (" 👋", false),
    ])
    func emoji(_ text: String, _ isEmoji: Bool) {
        #expect(ChatMessage.isEmoji(text) == isEmoji)
    }
}
