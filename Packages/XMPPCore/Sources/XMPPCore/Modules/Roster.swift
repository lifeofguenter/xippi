import Foundation

/// One contact of the roster (RFC 6121 section 2).
public struct RosterItem: Sendable, Hashable {
    public enum Subscription: String, Sendable, CaseIterable {
        case none, to, from, both, remove
    }

    public var jid: JID
    public var name: String?
    public var subscription: Subscription
    /// A subscription request is pending (`ask='subscribe'`).
    public var ask: Bool
    /// Group names, trimmed, without empty names or repeats.
    public var groups: [String]
    /// The subscription is pre-approved (RFC 6121 3.4).
    public var approved: Bool

    public init(
        jid: JID, name: String? = nil, subscription: Subscription = .none, ask: Bool = false,
        groups: [String] = [], approved: Bool = false
    ) {
        self.jid = jid
        self.name = name
        self.subscription = subscription
        self.ask = ask
        self.groups = groups
        self.approved = approved
    }

    /// Reads an `<item/>`; nil without a valid JID. A missing or unknown subscription reads as
    /// `none`, and a name of only whitespace as no name.
    public init?(element: Element) {
        guard element.name == "item", element.namespace == Roster.namespace,
            let jid = element[attribute: "jid"].flatMap({ try? JID($0) })
        else { return nil }
        self.jid = jid
        name = element[attribute: "name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        subscription =
            element[attribute: "subscription"].flatMap(Subscription.init(rawValue:)) ?? .none
        ask = element[attribute: "ask"] == "subscribe"
        approved = ["true", "1"].contains(element[attribute: "approved"])
        groups = element.children("group", namespace: Roster.namespace).compactMap(\.trimmedText)
            .uniqued()
    }

    /// The item as the server writes it, every attribute included.
    public var element: Element {
        var item = itemForSet
        if subscription != .none { item[attribute: "subscription"] = subscription.rawValue }
        if ask { item[attribute: "ask"] = "subscribe" }
        if approved { item[attribute: "approved"] = "true" }
        return item
    }

    /// The item as a client sends it in a roster set: JID, name and groups only (RFC 6121
    /// 2.1.5: subscription and ask are the server's).
    var itemForSet: Element {
        var item = Element(
            "item", namespace: Roster.namespace, attributes: ["jid": jid.description])
        item[attribute: "name"] = name
        for group in groups {
            item.append(Element("group", namespace: Roster.namespace, children: [.text(group)]))
        }
        return item
    }
}

/// The answer to a roster get.
public enum RosterFetch: Sendable, Hashable {
    /// The whole roster, and its version when the server versions it.
    case full(items: [RosterItem], version: String?)
    /// The roster has not changed since the version sent; changes follow as pushes.
    case unchanged
}

/// A roster push from the server: one changed item (`subscription == .remove` when deleted).
public struct RosterPush: Sendable, Hashable {
    public var item: RosterItem
    public var version: String?

    public init(item: RosterItem, version: String?) {
        self.item = item
        self.version = version
    }
}

/// RFC 6121 roster management, with roster versioning (section 2.6).
public enum Roster {
    public static let namespace = "jabber:iq:roster"

    /// Fetches the roster. `version` nil sends no `ver` (no versioning); `""` starts versioning
    /// with no cached roster; anything else is the cached version. Send a version only when the
    /// server offers the `rosterver` stream feature.
    public static func fetch(version: String?, via sender: any StanzaSending)
        async throws(IQError) -> RosterFetch
    {
        var query = Element("query", namespace: namespace)
        query[attribute: "ver"] = version
        let result = try await sender.request(.iq(type: .get, payload: query))
        // An empty result (no query) means "unchanged" (RFC 6121 2.6.3); an empty query is an
        // empty roster.
        guard let answer = result.child("query", namespace: namespace) else { return .unchanged }
        let items = answer.children("item", namespace: namespace).compactMap(RosterItem.init)
        return .full(items: items, version: answer[attribute: "ver"])
    }

    /// Reads a roster push. Nil unless it is an IQ set from the account itself (no `from`, or
    /// the account's bare JID, RFC 6121 2.1.6) carrying exactly one valid item; the caller
    /// answers a nil push with an error and must not apply it.
    public static func push(from stanza: Element, ownJID: JID) -> RosterPush? {
        guard stanza.isIQ(.set, payload: "query", namespace: namespace),
            stanza.isFromOwnAccount(ownJID, allowingMissing: true),
            let query = stanza.elements.first
        else { return nil }
        let items = query.children("item", namespace: namespace)
        guard items.count == 1, let item = items.first.flatMap(RosterItem.init) else { return nil }
        return RosterPush(item: item, version: query[attribute: "ver"])
    }

    /// Adds or updates a contact: its name and groups.
    public static func set(_ item: RosterItem, via sender: any StanzaSending) async throws(IQError)
    {
        let query = Element("query", namespace: namespace, children: [.element(item.itemForSet)])
        _ = try await sender.request(.iq(type: .set, payload: query))
    }

    /// Removes a contact, which also cancels the subscriptions both ways.
    public static func remove(_ jid: JID, via sender: any StanzaSending) async throws(IQError) {
        let item = Element(
            "item", namespace: namespace,
            attributes: [
                "jid": jid.description, "subscription": RosterItem.Subscription.remove.rawValue,
            ])
        let query = Element("query", namespace: namespace, children: [.element(item)])
        _ = try await sender.request(.iq(type: .set, payload: query))
    }
}
