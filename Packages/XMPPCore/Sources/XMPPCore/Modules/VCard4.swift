import Foundation

/// XEP-0292 vCard4 over XMPP: the RFC 6351 XML vCard in the PEP node `urn:xmpp:vcard4`.
public enum VCard4 {
    public static let node = "urn:xmpp:vcard4"
    public static let namespace = "urn:ietf:params:xml:ns:vcard-4.0"
    /// Advertised in caps so contacts' servers push profile changes.
    public static let notifyFeature = node + "+notify"

    /// The node's configuration for persistent data (XEP-0222): kept, and pushed only when it
    /// changes. Without an access model: only the internal `publish(_:via:)` uses it; the
    /// account's profile goes out through `publish(_:access:accountFeatures:via:)` (R64).
    static let options: KeyValuePairs<String, [String]> = [
        "pubsub#persist_items": ["true"],
        "pubsub#send_last_published_item": ["never"],
    ]

    /// The profile in a `<vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'/>`; nil for another
    /// element.
    public static func profile(from vcard: Element) -> Profile? {
        guard vcard.name == "vcard", vcard.namespace == namespace else { return nil }
        var profile = Profile(
            fullName: first(of: vcard, "fn", text),
            nickname: first(of: vcard, "nickname", text),
            emails: vcard.children("email", namespace: namespace).compactMap(text),
            phones: vcard.children("tel", namespace: namespace).compactMap(phone),
            url: first(of: vcard, "url", url).flatMap(URL.init(string:)),
            note: first(of: vcard, "note", text),
            avatar: vcard.children("photo", namespace: namespace).lazy.compactMap(photo).first)
        profile.source = vcard
        return profile
    }

    /// The vCard for `profile`: its `source` with the profile's fields written in, or a new
    /// vCard when the source is not a vCard4 one.
    public static func vcard(_ profile: Profile) -> Element {
        let source = profile.source.flatMap {
            $0.name == "vcard" && $0.namespace == namespace ? $0 : nil
        }
        var merge = VCardMerge(source: source)
        merge.setSingle(named("fn"), value: text, to: profile.fullName) {
            property("fn", "text", profile.fullName)
        }
        merge.setSingle(named("nickname"), value: text, to: profile.nickname) {
            property("nickname", "text", profile.nickname)
        }
        merge.setSingle(named("photo"), value: photoURI, to: profile.avatar.map(uri)) {
            property("photo", "uri", profile.avatar.map(uri))
        }
        merge.setList(named("email"), value: text, to: profile.emails) { address in
            property("email", "text", address)
        }
        merge.setList(named("tel"), value: phone, to: profile.phones) { number in
            isTelURI(number)
                ? property("tel", "uri", "tel:" + number) : property("tel", "text", number)
        }
        merge.setSingle(named("url"), value: url, to: profile.url?.absoluteString) {
            property("url", "uri", profile.url?.absoluteString)
        }
        merge.setSingle(named("note"), value: text, to: profile.note) {
            property("note", "text", profile.note)
        }
        var vcard = source ?? Element("vcard", namespace: namespace)
        vcard.children = merge.children
        return vcard
    }

    /// The vCard `jid` (nil: the account) publishes; nil when it publishes none.
    public static func fetch(_ jid: JID? = nil, via sender: any StanzaSending)
        async throws(PubSubError) -> Profile?
    {
        // A node may hold several items (XEP-0292 publishes without an id): the newest only.
        let items = try await PubSub.items(node: node, from: jid?.bare, max: 1, via: sender)
        return items.last?.payload.flatMap(profile(from:))
    }

    /// Publishes `profile` as the account's vCard: the whole vCard, as one item (`current`).
    /// A new embedded photo over `Avatars.maxPublishBytes` is refused with `not-acceptable`,
    /// and nothing is sent.
    static func publish(_ profile: Profile, via sender: any StanzaSending)
        async throws(PubSubError)
    {
        guard profile.photoFits(readingSourceWith: self.profile(from:)) else {
            throw .request(.error(StanzaError(type: .modify, condition: .notAcceptable)))
        }
        try await PubSub.publishConfiguring(
            node: node, item: PubSubItem(id: "current", payload: vcard(profile)),
            options: options, via: sender)
    }

    /// Whose vCard a notification says has changed (XEP-0292 4.2.2: the notification may carry
    /// no payload, so fetch it). Nil for any other message, and for one that does not come
    /// from a bare JID.
    public static func updated(_ message: Element) -> JID? {
        guard let event = PubSub.event(from: message), event.node == node, event.kind == .items,
            let from = event.from, from.isBare
        else { return nil }
        return from
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

    /// The first `<text/>` value of a property.
    private static func text(_ property: Element) -> String? {
        property.child("text", namespace: namespace)?.trimmedText
    }

    private static func uriValue(_ property: Element) -> String? {
        property.child("uri", namespace: namespace)?.trimmedText
    }

    /// A `tel:` URI without its scheme, or a text value.
    private static func phone(_ property: Element) -> String? {
        if let uri = uriValue(property) {
            guard uri.lowercased().hasPrefix("tel:") else { return nil }
            return String(uri.dropFirst(4)).nonEmpty
        }
        return text(property)
    }

    private static func url(_ property: Element) -> String? {
        Profile.webURL(uriValue(property))?.absoluteString
    }

    /// A `data:` URI with base64 image data, or a web address.
    private static func photo(_ property: Element) -> Profile.Photo? {
        guard let uri = uriValue(property) else { return nil }
        guard uri.lowercased().hasPrefix("data:") else {
            return Profile.webURL(uri).map { .url($0) }
        }
        guard let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        guard header.lowercased().hasSuffix(";base64"),
            let data = Profile.imageData(base64: String(uri[uri.index(after: comma)...]))
        else { return nil }
        let type = String(header.dropLast(";base64".count)).nonEmpty
        return .data(data, type: type)
    }

    /// A photo as the URI that is compared and written: equal photos give equal URIs.
    private static func photoURI(_ property: Element) -> String? { photo(property).map(uri) }

    private static func uri(_ photo: Profile.Photo) -> String {
        switch photo {
        case .data(let data, let type): "data:\(type ?? "");base64,\(data.base64EncodedString())"
        case .url(let url): url.absoluteString
        }
    }

    /// Whether `number` can be written as a `tel:` URI (RFC 3966 digits, visual separators,
    /// `*` and `#`), with at least one digit.
    private static func isTelURI(_ number: String) -> Bool {
        let allowed = Set("0123456789+-.()*#".utf8)
        return number.utf8.allSatisfy(allowed.contains)
            && number.utf8.contains { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func property(_ name: String, _ type: String, _ value: String?) -> Element {
        Element(
            name, namespace: namespace,
            children: [
                .element(
                    Element(type, namespace: namespace, children: value.map { [.text($0)] } ?? []))
            ])
    }
}
