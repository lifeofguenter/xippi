import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct VCard4Tests {
    static let file = "xep-0292-0.12.2"

    static func vcard() throws -> Element {
        let iq = try ModuleFixtures.stanza(file, "retrieve-result")
        return try #require(
            iq.child("pubsub", namespace: PubSub.namespace)?
                .child("items", namespace: PubSub.namespace)?
                .child("item", namespace: PubSub.namespace)?
                .child("vcard", namespace: VCard4.namespace))
    }

    @Test func fetchMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "retrieve-result"), for: "pubsub")
        let profile = try #require(
            try await VCard4.fetch(try JID("stpeter@jabber.org"), via: sender))
        #expect(profile.fullName == "Peter Saint-Andre")
        #expect(profile.nickname == "stpeter")
        #expect(profile.emails == ["psaintan@cisco.com", "stpeter@jabber.org"])
        #expect(
            profile.phones == [
                "+1-303-308-3282", "+1-303-308-3219", "+1-720-256-6756", "+1-303-555-1212",
            ])
        #expect(profile.url == URL(string: "https://stpeter.im/"))
        #expect(profile.note?.hasPrefix("More information about me") == true)
        #expect(
            profile.avatar
                == .url(try #require(URL(string: "https://stpeter.im/images/stpeter_oscon.jpg"))))
        // The XEP's request, asking for the newest item only: a node may hold several.
        var expected = try ModuleFixtures.stanza(Self.file, "retrieve").normalized(
            dropping: ["id", "from"])
        expected.children = expected.children.map { node in
            guard case .element(var pubsub) = node else { return node }
            pubsub.children = pubsub.children.map { node in
                guard case .element(var items) = node else { return node }
                items[attribute: "max_items"] = "1"
                return .element(items)
            }
            return .element(pubsub)
        }
        #expect(sender.sent.first?.normalized(dropping: ["id"]) == expected)
    }

    @Test func noVCard() async throws {
        let missing = FakeStanzaSender()
        missing.enqueueError(
            .error(StanzaError(type: .cancel, condition: .itemNotFound)), for: "pubsub")
        #expect(try await VCard4.fetch(via: missing) == nil)
        let empty = FakeStanzaSender()
        empty.enqueueResponse(
            ModuleFixtures.iqResult(
                Element(
                    "pubsub", namespace: PubSub.namespace,
                    children: [
                        .element(
                            Element(
                                "items", namespace: PubSub.namespace,
                                attributes: ["node": VCard4.node]))
                    ])), for: "pubsub")
        #expect(try await VCard4.fetch(via: empty) == nil)
        #expect(empty.sent.first?[attribute: "to"] == nil)
    }

    @Test func publishKeepsWhatTheProfileDoesNotShow() async throws {
        let original = try Self.vcard()
        var profile = try #require(VCard4.profile(from: original))
        profile.note = "Check out my blog at https://stpeter.im/"
        profile.emails = ["stpeter@jabber.org"]
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await VCard4.publish(profile, via: sender)
        let iq = try #require(sender.sent.first)
        #expect(iq.type == "set")
        #expect(iq[attribute: "to"] == nil)
        let pubsub = try #require(iq.child("pubsub", namespace: PubSub.namespace))
        let publish = try #require(pubsub.child("publish", namespace: PubSub.namespace))
        #expect(publish[attribute: "node"] == VCard4.node)
        let item = try #require(publish.child("item", namespace: PubSub.namespace))
        #expect(item[attribute: "id"] == "current")
        let vcard = try #require(item.child("vcard", namespace: VCard4.namespace))
        // Everything but the note and the dropped email is as it was, in place.
        var expected = original.normalized
        expected.children = expected.children.compactMap { node in
            guard case .element(var element) = node else { return node }
            if element.name == "note" {
                element.children = [
                    .element(
                        Element(
                            "text", namespace: VCard4.namespace,
                            children: [.text("Check out my blog at https://stpeter.im/")]))
                ]
            }
            if element.name == "email",
                element.child("text", namespace: VCard4.namespace)?.text == "psaintan@cisco.com"
            {
                return nil
            }
            return .element(element)
        }
        #expect(vcard.normalized == expected)
        let form = try #require(
            pubsub.child("publish-options", namespace: PubSub.namespace)?
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init))
        #expect(form.formType == PubSub.publishOptionsFeature)
        #expect(form.field("pubsub#persist_items")?.values == ["true"])
        #expect(form.field("pubsub#send_last_published_item")?.values == ["never"])
        // Who may read it stays the server's (or the user's) choice.
        #expect(form.field("pubsub#access_model") == nil)
    }

    @Test func aNewProfileRoundTrips() throws {
        let profile = Profile(
            fullName: "Juliet Capulet", nickname: "juliet", emails: ["juliet@capulet.lit"],
            phones: ["+39-045-800", "ask the nurse"], url: URL(string: "https://capulet.lit/"),
            note: "Wherefore art thou?", avatar: .data(AvatarsTests.png(), type: "image/png"))
        let vcard = VCard4.vcard(profile)
        var parsed = VCard4.profile(from: vcard)
        parsed?.source = nil
        #expect(parsed == profile)
        let photo = vcard.child("photo", namespace: VCard4.namespace)?
            .child("uri", namespace: VCard4.namespace)?.text
        #expect(photo?.hasPrefix("data:image/png;base64,") == true)
        let tels = vcard.children("tel", namespace: VCard4.namespace)
        #expect(tels.first?.child("uri", namespace: VCard4.namespace)?.text == "tel:+39-045-800")
        #expect(tels.last?.child("text", namespace: VCard4.namespace)?.text == "ask the nurse")
    }

    @Test func photosThatCannotBeShown() throws {
        func photo(_ uri: String) -> Element {
            Element(
                "vcard", namespace: VCard4.namespace,
                children: [
                    .element(
                        Element(
                            "photo", namespace: VCard4.namespace,
                            children: [
                                .element(
                                    Element(
                                        "uri", namespace: VCard4.namespace,
                                        children: [.text(uri)]))
                            ]))
                ])
        }
        #expect(VCard4.profile(from: photo("data:image/png;base64,!!!"))?.avatar == nil)
        #expect(VCard4.profile(from: photo("file:///etc/passwd"))?.avatar == nil)
        #expect(VCard4.profile(from: photo("data:image/png,raw"))?.avatar == nil)
        let large = Data(repeating: 1, count: Avatars.maxBytes + 1).base64EncodedString()
        #expect(VCard4.profile(from: photo("data:image/png;base64," + large))?.avatar == nil)
        let png = AvatarsTests.png()
        #expect(
            VCard4.profile(from: photo("data:image/png;base64," + png.base64EncodedString()))?
                .avatar == .data(png, type: "image/png"))
        #expect(VCard4.profile(from: Element("vCard", namespace: VCardTemp.namespace)) == nil)
    }

    @Test func notifications() throws {
        let message = try ModuleFixtures.stanza(Self.file, "notification")
        #expect(VCard4.updated(message) == (try JID("romeo@montague.lit")))
        var full = message
        full[attribute: "from"] = "romeo@montague.lit/orchard"
        #expect(VCard4.updated(full) == nil)
        var none = message
        none[attribute: "from"] = nil
        #expect(VCard4.updated(none) == nil)
        #expect(VCard4.updated(try ModuleFixtures.stanza("xep-0402-1.2.0", "notify-new")) == nil)
    }

    @Test func aNewPhotoOverThePublishCapIsRefused() async throws {
        let large = Data(repeating: 1, count: Avatars.maxPublishBytes + 1)
        let sender = FakeStanzaSender()
        await #expect(
            throws: PubSubError.request(
                .error(StanzaError(type: .modify, condition: .notAcceptable)))
        ) {
            try await VCard4.publish(
                Profile(fullName: "Juliet", avatar: .data(large, type: "image/png")), via: sender)
        }
        #expect(sender.sent.isEmpty)
        var kept = try #require(
            VCard4.profile(from: VCard4.vcard(Profile(avatar: .data(large, type: "image/png")))))
        kept.fullName = "Juliet"
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "pubsub")
        try await VCard4.publish(kept, via: sender)
        #expect(sender.sent.count == 1)
    }
}
