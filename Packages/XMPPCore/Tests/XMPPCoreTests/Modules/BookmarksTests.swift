import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct BookmarksTests {
    static let file = "xep-0402-1.2.0"
    static let own = "juliet@capulet.lit/balcony"
    /// The account's features: publish-options, which XEP-0402 relies on.
    static let features: Set<String> = [PubSub.namespace, PubSub.publishOptionsFeature]

    static func thePlay() throws -> Bookmark {
        Bookmark(
            jid: try JID("theplay@conference.shakespeare.lit"), name: "The Play's the Thing",
            autojoin: true, nick: "JC")
    }

    static func orchard() throws -> Bookmark {
        Bookmark(
            jid: try JID("orchard@conference.shakespeare.lit"), name: "The Orcard",
            autojoin: true, nick: "JC",
            extensions: [
                Element(
                    "state", namespace: "http://myclient.example/bookmark/state",
                    attributes: ["minimized": "true"])
            ])
    }

    static func item(id: String?, _ conference: Element) -> Element {
        var item = Element("item", namespace: PubSub.namespace, children: [.element(conference)])
        item[attribute: "id"] = id
        return item
    }

    @Test func fetchMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "retrieve-result"), for: "pubsub")
        let bookmarks = try await Bookmarks.fetch(via: sender)
        #expect(
            bookmarks.map {
                var b = $0
                b.extensions = b.extensions.map(\.normalized)
                return b
            }
                == [try Self.thePlay(), try Self.orchard()])
        let expected = try ModuleFixtures.stanza(Self.file, "retrieve")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func noNodeIsNoBookmarks() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        #expect(try await Bookmarks.fetch(via: sender).isEmpty)
    }

    @Test func conferenceElements() throws {
        let conference = try ModuleFixtures.stanza(Self.file, "conference")
        let bookmark = try #require(
            Bookmark(item: Self.item(id: "council@conference.underhill.org", conference)))
        #expect(bookmark.name == "Council of Oberon")
        #expect(bookmark.autojoin)
        #expect(bookmark.nick == "Puck")
        #expect(bookmark.password == nil)
        let minimal = try #require(
            Bookmark(
                item: Self.item(
                    id: "council@conference.underhill.org",
                    try ModuleFixtures.stanza(Self.file, "minimal"))))
        #expect(minimal == Bookmark(jid: try JID("council@conference.underhill.org")))
    }

    @Test func bookmarkRoundTrips() throws {
        var bookmark = try Self.orchard()
        bookmark.password = "cauldronburn"
        bookmark.autojoin = false
        let parsed = try #require(
            Bookmark(item: Self.item(id: bookmark.jid.description, bookmark.conference)))
        #expect(parsed == bookmark)
        #expect(bookmark.conference[attribute: "autojoin"] == nil)
    }

    @Test func itemsThatCannotBeReadAreSkipped() throws {
        let conference = Element("conference", namespace: Bookmarks.namespace)
        #expect(Bookmark(item: Self.item(id: nil, conference)) == nil)
        #expect(Bookmark(item: Self.item(id: "@", conference)) == nil)
        #expect(Bookmark(item: Self.item(id: "room@muc.example/nick", conference)) == nil)
        #expect(Bookmark(item: Self.item(id: "muc.example", conference)) == nil)
        #expect(
            Bookmark(
                item: Self.item(
                    id: "room@muc.example", Element("conference", namespace: "storage:bookmarks")))
                == nil)
        #expect(Bookmark(item: Self.item(id: "room@muc.example", conference)) != nil)
        let other = Element(
            "conference", namespace: Bookmarks.namespace, attributes: ["autojoin": "yes"])
        #expect(Bookmark(item: Self.item(id: "room@muc.example", other))?.autojoin == false)
    }

    @Test func publishMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "add-result"), for: "pubsub")
        try await Bookmarks.publish(try Self.thePlay(), accountFeatures: Self.features, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "add")
        #expect(sender.sent.count == 1)
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func editingKeepsTheExtensions() async throws {
        let fetching = FakeStanzaSender()
        fetching.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "retrieve-result"), for: "pubsub")
        var orchard = try #require(try await Bookmarks.fetch(via: fetching).last)
        orchard.name = "The Orchard"
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await Bookmarks.publish(orchard, accountFeatures: Self.features, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "edit")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func aMisconfiguredNodeIsReconfiguredOnce() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueError(.error(StanzaError(type: .cancel, condition: .conflict)), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await Bookmarks.publish(try Self.thePlay(), accountFeatures: Self.features, via: sender)
        try #require(sender.sent.count == 3)
        #expect(
            sender.sent[0].normalized(dropping: ["id"])
                == sender.sent[2].normalized(dropping: ["id"]))
        let configure = try #require(
            sender.sent[1].child("pubsub", namespace: PubSub.ownerNamespace)?
                .child("configure", namespace: PubSub.ownerNamespace))
        #expect(configure[attribute: "node"] == Bookmarks.node)
        let form = try #require(
            configure.child("x", namespace: DataForm.namespace).flatMap(DataForm.init))
        #expect(form.formType == "http://jabber.org/protocol/pubsub#node_config")
        #expect(form.field("pubsub#access_model")?.values == ["whitelist"])
        #expect(form.field("pubsub#persist_items")?.values == ["true"])
        #expect(form.field("pubsub#max_items")?.values == ["max"])
        #expect(form.field("pubsub#send_last_published_item")?.values == ["never"])
    }

    @Test func aSecondPreconditionFailureIsThrown() async throws {
        let sender = FakeStanzaSender()
        let conflict = IQError.error(StanzaError(type: .cancel, condition: .conflict))
        sender.enqueueError(conflict, for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        sender.enqueueError(conflict, for: "pubsub")
        await #expect(throws: PubSubError.preconditionNotMet) {
            try await Bookmarks.publish(
                try Self.thePlay(), accountFeatures: Self.features, via: sender)
        }
        #expect(sender.sent.count == 3)
        let refused = FakeStanzaSender()
        refused.enqueueError(conflict, for: "pubsub")
        refused.enqueueError(
            .error(StanzaError(type: .auth, condition: .forbidden)), for: "pubsub")
        await #expect(throws: PubSubError.forbidden) {
            try await Bookmarks.publish(
                try Self.thePlay(), accountFeatures: Self.features, via: refused)
        }
        #expect(refused.sent.count == 2)
    }

    @Test func retractMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await Bookmarks.retract(try JID("theplay@conference.shakespeare.lit"), via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "remove")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func notifications() throws {
        let own = try JID(Self.own)
        #expect(
            Bookmarks.event(try ModuleFixtures.stanza(Self.file, "notify-new"), ownJID: own)
                == Bookmarks.Update(published: [try Self.thePlay()]))
        var notJoined = try Self.thePlay()
        notJoined.autojoin = false
        #expect(
            Bookmarks.event(
                try ModuleFixtures.stanza(Self.file, "notify-autojoin-false"), ownJID: own)
                == Bookmarks.Update(published: [notJoined]))
        #expect(
            Bookmarks.event(try ModuleFixtures.stanza(Self.file, "notify-retract"), ownJID: own)
                == Bookmarks.Update(retracted: [try JID("theplay@conference.shakespeare.lit")]))
    }

    @Test(arguments: [
        "mallory@evil", "mallory@evil/x", "juliet@capulet.lit/balcony", "capulet.lit", nil,
    ])
    func notificationsFromAnyoneElseAreRefused(_ from: String?) throws {
        var message = try ModuleFixtures.stanza(Self.file, "notify-new")
        message[attribute: "from"] = from
        #expect(Bookmarks.event(message, ownJID: try JID(Self.own)) == nil)
    }

    @Test func otherNodesAreNotBookmarks() throws {
        let other = try ModuleFixtures.stanza("xep-0490-1.1.0", "event")
        #expect(Bookmarks.event(other, ownJID: try JID("juliet@capulet.lit")) == nil)
    }

    // MARK: Fix round 1

    /// XEP-0402 8: without publish-options the server would ignore the access model and the
    /// node could be read by contacts, room passwords included.
    @Test func withoutPublishOptionsNothingIsPublished() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        for features in [Set<String>(), [PubSub.namespace], ["urn:xmpp:mam:2"]] {
            await #expect(throws: PubSubError.notSupported) {
                try await Bookmarks.publish(
                    try Self.thePlay(), accountFeatures: features, via: sender)
            }
        }
        #expect(sender.sent.isEmpty)
        try await Bookmarks.publish(try Self.thePlay(), accountFeatures: Self.features, via: sender)
        #expect(sender.sent.count == 1)
    }

    @Test func accountFeaturesComeFromTheOwnBareJID() async throws {
        let sender = FakeStanzaSender(boundJID: try JID(Self.own))
        let info = DiscoInfo(features: [PubSub.publishOptionsFeature, "urn:xmpp:mam:2"])
        sender.enqueueResponse(ModuleFixtures.iqResult(info.element()), for: "query")
        #expect(
            try await PubSub.accountFeatures(via: sender)
                == [PubSub.publishOptionsFeature, "urn:xmpp:mam:2"])
        #expect(sender.sent.first?[attribute: "to"] == "juliet@capulet.lit")
        #expect(sender.sent.first?.type == "get")
        let offline = FakeStanzaSender()
        await #expect(throws: IQError.notConnected) {
            try await PubSub.accountFeatures(via: offline)
        }
        #expect(offline.sent.isEmpty)
    }

    /// XEP-0060 7.1.5's error for a precondition that is not met, as a server sends it.
    @Test func thePreconditionErrorAsServersSendIt() async throws {
        let error = Element(
            "error", attributes: ["type": "cancel"],
            children: [
                .element(Element("conflict", namespace: StanzaError.namespace)),
                .element(
                    Element(
                        "precondition-not-met",
                        namespace: "http://jabber.org/protocol/pubsub#errors")),
            ])
        let answer = Element("iq", attributes: ["type": "error"], children: [.element(error)])
        let sender = FakeStanzaSender()
        sender.enqueueResponse(answer, for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await Bookmarks.publish(try Self.thePlay(), accountFeatures: Self.features, via: sender)
        try #require(sender.sent.count == 3)
        #expect(sender.sent[1].child("pubsub", namespace: PubSub.ownerNamespace) != nil)
    }

    @Test func retractionsOfWhatIsNotARoomAreDropped() throws {
        let retracts = ["room@muc.example/nick", "muc.example", "@", "room@muc.example"].map {
            XMLNode.element(
                Element("retract", namespace: PubSub.eventNamespace, attributes: ["id": $0]))
        }
        var message = Element.message(
            type: "headline",
            children: [
                Element(
                    "event", namespace: PubSub.eventNamespace,
                    children: [
                        .element(
                            Element(
                                "items", namespace: PubSub.eventNamespace,
                                attributes: ["node": Bookmarks.node], children: retracts))
                    ])
            ])
        message[attribute: "from"] = "juliet@capulet.lit"
        #expect(
            Bookmarks.event(message, ownJID: try JID(Self.own))
                == Bookmarks.Update(retracted: [try JID("room@muc.example")]))
    }
}
