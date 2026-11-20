/// XEP-0191 Blocking Command.
public enum Blocking {
    public static let namespace = "urn:xmpp:blocking"

    /// A change to the blocklist that the server pushes to every session.
    public enum Push: Sendable, Hashable {
        case blocked([JID])
        case unblocked([JID])
        /// Every JID was unblocked.
        case unblockedAll
    }

    /// The blocked JIDs. Items without a valid JID are skipped.
    public static func list(via sender: any StanzaSending) async throws(IQError) -> [JID] {
        let result = try await sender.request(
            .iq(type: .get, payload: Element("blocklist", namespace: namespace)))
        let list = try result.resultPayload("blocklist", namespace: namespace)
        return jids(in: list) ?? []
    }

    /// Blocks `jids`; an empty list sends nothing.
    public static func block(_ jids: [JID], via sender: any StanzaSending) async throws(IQError) {
        guard !jids.isEmpty else { return }
        _ = try await sender.request(.iq(type: .set, payload: command("block", jids)))
    }

    /// Unblocks `jids`. An empty list sends nothing: on the wire it would unblock everyone,
    /// which is `unblockAll`.
    public static func unblock(_ jids: [JID], via sender: any StanzaSending) async throws(IQError) {
        guard !jids.isEmpty else { return }
        _ = try await sender.request(.iq(type: .set, payload: command("unblock", jids)))
    }

    /// Unblocks every JID.
    public static func unblockAll(via sender: any StanzaSending) async throws(IQError) {
        _ = try await sender.request(
            .iq(type: .set, payload: Element("unblock", namespace: namespace)))
    }

    /// Reads a blocklist push. Nil unless it is an IQ set from the account itself (no `from`, or
    /// the account's bare JID), like a roster push; a block needs at least one valid item, and
    /// an unblock is "unblock all" only when it has no items at all.
    public static func push(from stanza: Element, ownJID: JID) -> Push? {
        guard stanza.isFromOwnAccount(ownJID, allowingMissing: true) else { return nil }
        if stanza.isIQ(.set, payload: "block", namespace: namespace),
            let block = stanza.elements.first
        {
            guard let jids = jids(in: block), !jids.isEmpty else { return nil }
            return .blocked(jids)
        }
        if stanza.isIQ(.set, payload: "unblock", namespace: namespace),
            let unblock = stanza.elements.first
        {
            if unblock.children("item", namespace: namespace).isEmpty { return .unblockedAll }
            guard let jids = jids(in: unblock), !jids.isEmpty else { return nil }
            return .unblocked(jids)
        }
        return nil
    }

    /// The valid item JIDs of `element`; nil when it has items and none is valid.
    private static func jids(in element: Element) -> [JID]? {
        let items = element.children("item", namespace: namespace)
        let jids = items.compactMap { $0[attribute: "jid"].flatMap { try? JID($0) } }.uniqued()
        return !items.isEmpty && jids.isEmpty ? nil : jids
    }

    private static func command(_ name: String, _ jids: [JID]) -> Element {
        Element(name, namespace: namespace, children: jids.map { .element(item($0)) })
    }

    static func item(_ jid: JID) -> Element {
        Element("item", namespace: namespace, attributes: ["jid": jid.description])
    }
}
