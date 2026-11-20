/// A group chat the user keeps (XEP-0402): an item of the bookmarks node whose id is the room's
/// JID and whose payload is a `<conference/>`.
public struct Bookmark: Sendable, Hashable {
    /// The room's bare JID (the item id).
    public var jid: JID
    public var name: String?
    /// Join the room on login.
    public var autojoin: Bool
    public var nick: String?
    public var password: String?
    /// The children of `<extensions/>`, kept exactly as they came: other clients store their
    /// own data there, and XEP-0402 requires it back unchanged on every edit.
    public var extensions: [Element]

    public init(
        jid: JID, name: String? = nil, autojoin: Bool = false, nick: String? = nil,
        password: String? = nil, extensions: [Element] = []
    ) {
        self.jid = jid
        self.name = name
        self.autojoin = autojoin
        self.nick = nick
        self.password = password
        self.extensions = extensions
    }

    /// Reads a node item (`<item/>` of the pubsub or pubsub#event namespace). Nil without an
    /// id that is a room's JID (bare, with a local part), or without a `<conference/>`. `autojoin` is true only for `true`
    /// or `1`.
    public init?(item: Element) {
        guard item.name == "item",
            let jid = item[attribute: "id"].flatMap({ try? JID($0) }), Bookmarks.isRoom(jid),
            let conference = item.child("conference", namespace: Bookmarks.namespace)
        else { return nil }
        self.jid = jid
        name = conference[attribute: "name"]?.nonEmpty
        autojoin = ["true", "1"].contains(conference[attribute: "autojoin"])
        nick = conference.child("nick", namespace: Bookmarks.namespace)?.trimmedText
        password = conference.child("password", namespace: Bookmarks.namespace)?.text.nonEmpty
        extensions =
            conference.child("extensions", namespace: Bookmarks.namespace)?.elements ?? []
    }

    /// The item's `<conference/>` payload. `autojoin` is written only when true, its default
    /// being false.
    public var conference: Element {
        var conference = Element("conference", namespace: Bookmarks.namespace)
        conference[attribute: "name"] = name
        if autojoin { conference[attribute: "autojoin"] = "true" }
        if let nick {
            conference.append(
                Element("nick", namespace: Bookmarks.namespace, children: [.text(nick)]))
        }
        if let password {
            conference.append(
                Element("password", namespace: Bookmarks.namespace, children: [.text(password)]))
        }
        if !extensions.isEmpty {
            conference.append(
                Element(
                    "extensions", namespace: Bookmarks.namespace,
                    children: extensions.map(XMLNode.element)))
        }
        return conference
    }
}

/// XEP-0402 PEP Native Bookmarks: one private item per room in the account's
/// `urn:xmpp:bookmarks:1` node.
public enum Bookmarks {
    public static let node = "urn:xmpp:bookmarks:1"
    public static let namespace = node
    /// Advertised in caps so the server pushes changes made by the account's other clients.
    public static let notifyFeature = node + "+notify"

    /// The node's configuration, as XEP-0402 shows it: kept, as many items as the server
    /// allows, nothing sent on subscribing, and only the account may read it.
    static let options: KeyValuePairs<String, [String]> = [
        "pubsub#persist_items": ["true"],
        "pubsub#max_items": ["max"],
        "pubsub#send_last_published_item": ["never"],
        "pubsub#access_model": ["whitelist"],
    ]

    /// What a notification changed.
    public struct Update: Sendable, Hashable {
        /// Added or edited bookmarks.
        public var published: [Bookmark]
        /// The rooms whose bookmarks were removed.
        public var retracted: [JID]

        public init(published: [Bookmark] = [], retracted: [JID] = []) {
            self.published = published
            self.retracted = retracted
        }
    }

    /// Every bookmark. A node that does not exist yet has none. Items that cannot be read are
    /// skipped.
    public static func fetch(via sender: any StanzaSending) async throws(PubSubError) -> [Bookmark]
    {
        try await PubSub.items(node: node, via: sender).compactMap(bookmark(from:))
    }

    /// Adds or edits `bookmark`, with the publish-options that keep the node private. When the
    /// node exists with another configuration (it would show the bookmarks to others), it is
    /// configured to these options and the bookmark published once more.
    ///
    /// `accountFeatures` are the disco#info features of the account's bare JID, read once per
    /// session (`PubSub.accountFeatures`). Without `PubSub.publishOptionsFeature` the server
    /// would ignore the options and could show the bookmarks, room passwords included, to
    /// contacts (XEP-0402 8): `.notSupported` is thrown and nothing is sent.
    public static func publish(
        _ bookmark: Bookmark, accountFeatures: Set<String>, via sender: any StanzaSending
    ) async throws(PubSubError) {
        guard accountFeatures.contains(PubSub.publishOptionsFeature) else {
            throw .notSupported
        }
        try await PubSub.publishConfiguring(
            node: node,
            item: PubSubItem(id: bookmark.jid.bare.description, payload: bookmark.conference),
            options: options, via: sender)
    }

    /// Removes the bookmark of `room`, telling the account's other clients.
    public static func retract(_ room: JID, via sender: any StanzaSending) async throws(PubSubError)
    {
        try await PubSub.retract(node: node, itemID: room.bare.description, via: sender)
    }

    /// The change a notification of the bookmarks node carries. Nil for any other message, and
    /// for one whose `from` is not the account's own bare JID: another account's node is not
    /// the user's bookmarks.
    public static func event(_ message: Element, ownJID: JID) -> Update? {
        guard let event = PubSub.event(from: message), event.node == node, event.kind == .items,
            message.isFromOwnAccount(ownJID, allowingMissing: false)
        else { return nil }
        return Update(
            published: event.items.compactMap(bookmark(from:)),
            retracted: event.retracted.compactMap { id in
                (try? JID(id)).flatMap { isRoom($0) ? $0 : nil }
            })
    }

    /// A room's JID: bare, with a local part. A domain alone would be joined as
    /// `domain/nick`.
    static func isRoom(_ jid: JID) -> Bool { jid.isBare && jid.localpart != nil }

    private static func bookmark(from item: PubSubItem) -> Bookmark? {
        guard let id = item.id, let payload = item.payload else { return nil }
        return Bookmark(
            item: Element(
                "item", namespace: PubSub.namespace, attributes: ["id": id],
                children: [.element(payload)]))
    }
}
