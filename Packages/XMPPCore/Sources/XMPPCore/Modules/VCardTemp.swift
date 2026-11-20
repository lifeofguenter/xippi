import Foundation

/// XEP-0054 vcard-temp: the vCard every server keeps, read with an IQ to the account's bare
/// JID (or a room's JID, for room avatars), and the store of XEP-0153 avatars.
public enum VCardTemp {
    public static let namespace = "vcard-temp"

    /// The profile in a `<vCard xmlns='vcard-temp'/>`; nil for another element.
    public static func profile(from vcard: Element) -> Profile? {
        guard vcard.name == "vCard", vcard.namespace == namespace else { return nil }
        var profile = Profile(
            fullName: first(of: vcard, "FN", text),
            nickname: first(of: vcard, "NICKNAME", text),
            emails: vcard.children("EMAIL", namespace: namespace).compactMap(email),
            phones: vcard.children("TEL", namespace: namespace).compactMap(phone),
            url: first(of: vcard, "URL", url).flatMap(URL.init(string:)),
            note: first(of: vcard, "DESC", text),
            avatar: vcard.children("PHOTO", namespace: namespace).lazy.compactMap(photo).first)
        profile.source = vcard
        return profile
    }

    /// The vCard for `profile`: its `source` with the profile's fields written in, or a new
    /// vCard when the source is not a vcard-temp one.
    public static func vcard(_ profile: Profile) -> Element {
        let source = profile.source.flatMap {
            $0.name == "vCard" && $0.namespace == namespace ? $0 : nil
        }
        var merge = VCardMerge(source: source)
        merge.setSingle(named("FN"), value: text, to: profile.fullName) {
            element("FN", text: profile.fullName)
        }
        merge.setSingle(named("NICKNAME"), value: text, to: profile.nickname) {
            element("NICKNAME", text: profile.nickname)
        }
        merge.setSingle(named("PHOTO"), value: photoKey, to: profile.avatar.map(VCardTemp.key)) {
            profile.avatar.map(photoElement)
        }
        merge.setList(named("EMAIL"), value: email, to: profile.emails) { address in
            Element(
                "EMAIL", namespace: namespace,
                children: [.element(element("USERID", text: address))])
        }
        merge.setList(named("TEL"), value: phone, to: profile.phones) { number in
            Element(
                "TEL", namespace: namespace, children: [.element(element("NUMBER", text: number))])
        }
        merge.setSingle(named("URL"), value: url, to: profile.url?.absoluteString) {
            element("URL", text: profile.url?.absoluteString)
        }
        merge.setSingle(named("DESC"), value: text, to: profile.note) {
            element("DESC", text: profile.note)
        }
        var vcard = source ?? Element("vCard", namespace: namespace)
        vcard.children = merge.children
        return vcard
    }

    /// The vCard of `jid`: a contact's bare JID, a room's, or an occupant's `room@service/nick`
    /// (the room passes the request on, which is how room avatars and occupant avatars are
    /// read); nil for the account's own. Nil when there is none: `item-not-found`,
    /// `service-unavailable` or an empty `<vCard/>` (XEP-0054 3.1 and 3.3).
    public static func fetch(_ jid: JID? = nil, via sender: any StanzaSending)
        async throws(IQError) -> Profile?
    {
        let result: Element
        do {
            result = try await sender.request(
                .iq(type: .get, to: jid, payload: Element("vCard", namespace: namespace)))
        } catch .error(let error)
            where [.itemNotFound, .serviceUnavailable].contains(error.condition)
        {
            return nil
        }
        let vcard = try result.resultPayload("vCard", namespace: namespace)
        guard !vcard.elements.isEmpty else { return nil }
        return profile(from: vcard)
    }

    /// Replaces the account's vCard with `profile`'s. A new embedded photo over
    /// `Avatars.maxPublishBytes` is refused with `not-acceptable`, and nothing is sent.
    public static func publish(_ profile: Profile, via sender: any StanzaSending)
        async throws(IQError)
    {
        guard profile.photoFits(readingSourceWith: self.profile(from:)) else {
            throw .error(StanzaError(type: .modify, condition: .notAcceptable))
        }
        _ = try await sender.request(.iq(type: .set, payload: vcard(profile)))
    }

    /// The XEP-0153 hash of the profile's embedded photo, as presence advertises it.
    public static func photoHash(of profile: Profile) -> String? {
        guard case .data(let data, _) = profile.avatar else { return nil }
        return Avatars.sha1(data)
    }

    // MARK: Properties

    private static func named(_ name: String) -> (Element) -> Bool {
        { $0.name == name && $0.namespace == namespace }
    }

    private static func first(
        of vcard: Element, _ name: String, _ value: (Element) -> String?
    ) -> String? {
        vcard.children(name, namespace: namespace).lazy.compactMap(value).first
    }

    private static func text(_ element: Element) -> String? { element.trimmedText }

    private static func email(_ element: Element) -> String? {
        element.child("USERID", namespace: namespace)?.trimmedText
    }

    private static func phone(_ element: Element) -> String? {
        element.child("NUMBER", namespace: namespace)?.trimmedText
    }

    private static func url(_ element: Element) -> String? {
        Profile.webURL(element.text)?.absoluteString
    }

    private static func photo(_ element: Element) -> Profile.Photo? {
        if let binval = element.child("BINVAL", namespace: namespace) {
            return Profile.imageData(base64: binval.text).map {
                .data($0, type: element.child("TYPE", namespace: namespace)?.trimmedText)
            }
        }
        return element.child("EXTVAL", namespace: namespace)
            .flatMap { Profile.webURL($0.text) }.map { .url($0) }
    }

    private static func photoKey(_ element: Element) -> String? { photo(element).map(key) }

    /// A photo as a value to compare: what it shows, not how the XML spells it.
    private static func key(_ photo: Profile.Photo) -> String {
        switch photo {
        case .data(let data, let type): "data:\(type ?? ""):\(Avatars.sha1(data))"
        case .url(let url): "url:" + url.absoluteString
        }
    }

    private static func photoElement(_ photo: Profile.Photo) -> Element {
        var element = Element("PHOTO", namespace: namespace)
        switch photo {
        case .data(let data, let type):
            if let type { element.append(self.element("TYPE", text: type)) }
            element.append(self.element("BINVAL", text: data.base64EncodedString()))
        case .url(let url):
            element.append(self.element("EXTVAL", text: url.absoluteString))
        }
        return element
    }

    private static func element(_ name: String, text: String?) -> Element {
        Element(name, namespace: namespace, children: text.map { [.text($0)] } ?? [])
    }
}
