import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct VCardTempTests {
    static let file = "xep-0054-1.3.0"

    static func vcard(_ example: String, file: String = file) throws -> Element {
        let iq = try ModuleFixtures.stanza(file, example)
        return try #require(iq.child("vCard", namespace: VCardTemp.namespace))
    }

    static func withoutSource(_ profile: Profile?) -> Profile? {
        guard var profile else { return nil }
        profile.source = nil
        return profile
    }

    @Test func fetchMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "result"), for: "vCard")
        let profile = try #require(try await VCardTemp.fetch(via: sender))
        #expect(profile.fullName == "Peter Saint-Andre")
        #expect(profile.nickname == "stpeter")
        #expect(profile.emails == ["stpeter@jabber.org"])
        #expect(profile.phones == ["303-308-3282", "303-555-1212"])
        #expect(profile.url == URL(string: "http://www.xmpp.org/xsf/people/stpeter.shtml"))
        #expect(profile.note?.hasPrefix("More information about me") == true)
        #expect(profile.note?.hasSuffix("http://www.saint-andre.com/") == true)
        #expect(profile.avatar == nil)
        #expect(profile.source?.name == "vCard")
        let expected = try ModuleFixtures.stanza(Self.file, "request")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func fetchAnotherUser() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "empty"), for: "vCard")
        #expect(try await VCardTemp.fetch(try JID("jer@jabber.org"), via: sender) == nil)
        let expected = try ModuleFixtures.stanza(Self.file, "request-other")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func anOccupantsVCardIsAskedOfTheOccupantJID() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "empty"), for: "vCard")
        _ = try await VCardTemp.fetch(try JID("coven@chat.shakespeare.lit/thirdwitch"), via: sender)
        #expect(sender.sent.first?[attribute: "to"] == "coven@chat.shakespeare.lit/thirdwitch")
    }

    @Test func noVCard() async throws {
        let missing = FakeStanzaSender()
        missing.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "item-not-found"), for: "vCard")
        #expect(try await VCardTemp.fetch(via: missing) == nil)
        let unavailable = FakeStanzaSender()
        unavailable.enqueueResponse(try ModuleFixtures.stanza(Self.file, "no-vcard"), for: "vCard")
        #expect(try await VCardTemp.fetch(try JID("jer@jabber.org"), via: unavailable) == nil)
        let failing = FakeStanzaSender()
        failing.enqueueError(.timeout, for: "vCard")
        await #expect(throws: IQError.timeout) { try await VCardTemp.fetch(via: failing) }
        let malformed = FakeStanzaSender()
        malformed.enqueueResponse(ModuleFixtures.iqResult(), for: "vCard")
        await #expect(throws: IQError.malformedResponse) {
            try await VCardTemp.fetch(via: malformed)
        }
    }

    @Test func publishingKeepsWhatTheProfileDoesNotShow() async throws {
        var profile = try #require(VCardTemp.profile(from: try Self.vcard("result")))
        profile.note = "Check out my blog at https://stpeter.im/"
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "update-result"), for: "vCard")
        try await VCardTemp.publish(profile, via: sender)
        let expected = try ModuleFixtures.stanza(Self.file, "update")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    @Test func anUnchangedProfileIsTheSameVCard() throws {
        let vcard = try Self.vcard("publish-photo", file: "xep-0153-1.1.1-vcard")
        let profile = try #require(VCardTemp.profile(from: vcard))
        #expect(profile.nickname == nil)
        #expect(profile.emails == ["jcapulet@shakespeare.lit"])
        // The XEP's BINVAL is a placeholder, so there is no photo to show, but it is kept.
        #expect(profile.avatar == nil)
        #expect(VCardTemp.photoHash(of: profile) == nil)
        #expect(VCardTemp.vcard(profile).normalized == vcard.normalized)
    }

    @Test func changedListsKeepTheirParameters() throws {
        var profile = try #require(VCardTemp.profile(from: try Self.vcard("result")))
        profile.phones = ["303-555-1212", "555-0100"]
        profile.emails = []
        profile.nickname = nil
        let vcard = VCardTemp.vcard(profile)
        let tels = vcard.children("TEL", namespace: VCardTemp.namespace)
        let home = tels.first {
            $0.child("NUMBER", namespace: VCardTemp.namespace)?.text == "303-555-1212"
        }
        #expect(home?.child("HOME", namespace: VCardTemp.namespace) != nil)
        #expect(
            !tels.contains {
                $0.child("NUMBER", namespace: VCardTemp.namespace)?.text == "303-308-3282"
            })
        // The empty fax and message numbers are not phone numbers the profile shows.
        #expect(tels.count == 6)
        #expect(vcard.children("EMAIL", namespace: VCardTemp.namespace).isEmpty)
        #expect(vcard.child("NICKNAME", namespace: VCardTemp.namespace) == nil)
        #expect(vcard.child("ADR", namespace: VCardTemp.namespace) != nil)
        #expect(Self.withoutSource(VCardTemp.profile(from: vcard)) == Self.withoutSource(profile))
    }

    @Test func photos() throws {
        let png = AvatarsTests.png()
        let embedded = Element(
            "vCard", namespace: VCardTemp.namespace,
            children: [
                .element(
                    Element(
                        "PHOTO", namespace: VCardTemp.namespace,
                        children: [
                            .element(
                                Element(
                                    "TYPE", namespace: VCardTemp.namespace,
                                    children: [.text("image/png")])),
                            .element(
                                Element(
                                    "BINVAL", namespace: VCardTemp.namespace,
                                    children: [
                                        .text(
                                            "\n"
                                                + png.base64EncodedString(
                                                    options: .lineLength76Characters) + "\n")
                                    ])),
                        ]))
            ])
        let profile = try #require(VCardTemp.profile(from: embedded))
        #expect(profile.avatar == .data(png, type: "image/png"))
        #expect(VCardTemp.photoHash(of: profile) == Avatars.sha1(png))

        let external = Element(
            "vCard", namespace: VCardTemp.namespace,
            children: [
                .element(
                    Element(
                        "PHOTO", namespace: VCardTemp.namespace,
                        children: [
                            .element(
                                Element(
                                    "EXTVAL", namespace: VCardTemp.namespace,
                                    children: [.text("https://example.org/me.png")]))
                        ]))
            ])
        #expect(
            VCardTemp.profile(from: external)?.avatar
                == .url(try #require(URL(string: "https://example.org/me.png"))))

        let large = Data(repeating: 1, count: Avatars.maxBytes + 1)
        var tooLarge = embedded
        tooLarge.children = [
            .element(
                Element(
                    "PHOTO", namespace: VCardTemp.namespace,
                    children: [
                        .element(
                            Element(
                                "BINVAL", namespace: VCardTemp.namespace,
                                children: [.text(large.base64EncodedString())]))
                    ]))
        ]
        #expect(VCardTemp.profile(from: tooLarge)?.avatar == nil)
    }

    @Test func aNewProfileRoundTrips() throws {
        let profile = Profile(
            fullName: "Juliet Capulet", nickname: "juliet",
            emails: ["juliet@capulet.lit", "j@example.org"], phones: ["+39 045 800"],
            url: URL(string: "https://capulet.lit/juliet"), note: "Wherefore art thou?",
            avatar: .data(AvatarsTests.png(), type: "image/png"))
        let vcard = VCardTemp.vcard(profile)
        #expect(vcard.name == "vCard")
        #expect(vcard.namespace == VCardTemp.namespace)
        #expect(Self.withoutSource(VCardTemp.profile(from: vcard)) == profile)
        #expect(VCardTemp.photoHash(of: profile) == Avatars.sha1(AvatarsTests.png()))
    }

    @Test func linksOtherThanTheWebAreNotShown() throws {
        let vcard = Element(
            "vCard", namespace: VCardTemp.namespace,
            children: [
                .element(
                    Element(
                        "URL", namespace: VCardTemp.namespace,
                        children: [.text("javascript:alert(1)")]))
            ])
        #expect(VCardTemp.profile(from: vcard)?.url == nil)
        #expect(VCardTemp.profile(from: Element("vcard", namespace: VCard4.namespace)) == nil)
    }

    /// Ruling R36: a new photo larger than an avatar may be is not published; the stanza would
    /// exceed the server's limit and end the stream. A photo the vCard already had stays.
    @Test func aNewPhotoOverThePublishCapIsRefused() async throws {
        let large = Data(repeating: 1, count: Avatars.maxPublishBytes + 1)
        let sender = FakeStanzaSender()
        await #expect(
            throws: IQError.error(StanzaError(type: .modify, condition: .notAcceptable))
        ) {
            try await VCardTemp.publish(
                Profile(fullName: "Juliet", avatar: .data(large, type: "image/png")), via: sender)
        }
        #expect(sender.sent.isEmpty)
        var kept = try #require(
            VCardTemp.profile(
                from: VCardTemp.vcard(Profile(avatar: .data(large, type: "image/png")))))
        kept.fullName = "Juliet"
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "vCard")
        try await VCardTemp.publish(kept, via: sender)
        #expect(sender.sent.count == 1)
    }
}
