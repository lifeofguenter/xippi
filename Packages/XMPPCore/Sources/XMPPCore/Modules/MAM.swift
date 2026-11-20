import Foundation

/// The end of an archive query (XEP-0313 `<fin/>`): whether the last page has come, and the
/// RSM ids of the page's first and last results, to ask for the next page.
public struct MAMFin: Sendable, Hashable {
    /// No more results match the query: paging is done.
    public var complete: Bool
    /// False when the server says the results may still change (XEP-0313 4.3.2): do not keep
    /// them as final without asking again later.
    public var stable: Bool
    public var first: String?
    public var last: String?
    /// How many results match in all, when the server says.
    public var count: Int?

    public init(
        complete: Bool, stable: Bool = true, first: String? = nil, last: String? = nil,
        count: Int? = nil
    ) {
        self.complete = complete
        self.stable = stable
        self.first = first
        self.last = last
        self.count = count
    }

    /// Reads a `<fin xmlns='urn:xmpp:mam:2'/>`. `complete` is true only for `true` or `1`,
    /// `stable` false only for `false` or `0`.
    public init?(element: Element) {
        guard element.name == "fin", element.namespace == MAM.namespace else { return nil }
        complete = ["true", "1"].contains(element[attribute: "complete"])
        stable = !["false", "0"].contains(element[attribute: "stable"])
        let set = element.child("set", namespace: RSM.namespace).flatMap(RSM.Response.init)
        first = set?.first
        last = set?.last
        count = set?.count
    }
}

/// One archived message of a query's results.
public struct MAMResult: Sendable, Hashable {
    public var queryID: String
    /// The message's id in the archive: the RSM id for paging, and the stanza id to dedup by.
    public var archiveID: String
    /// The archived message.
    public var forwarded: Element
    /// When the archive received it.
    public var timestamp: Date

    public init(queryID: String, archiveID: String, forwarded: Element, timestamp: Date) {
        self.queryID = queryID
        self.archiveID = archiveID
        self.forwarded = forwarded
        self.timestamp = timestamp
    }
}

/// XEP-0441 archiving preferences.
public struct MAMPreferences: Sendable, Hashable {
    public enum Default: String, Sendable, CaseIterable {
        /// Archive everything.
        case always
        /// Archive nothing.
        case never
        /// Archive messages with roster contacts.
        case roster
    }

    public var `default`: Default
    /// Always archived, whatever the default.
    public var always: [JID]
    /// Never archived, whatever the default.
    public var never: [JID]

    public init(default: Default, always: [JID] = [], never: [JID] = []) {
        self.default = `default`
        self.always = always
        self.never = never
    }

    /// Reads a `<prefs/>`; nil without a known default. JIDs that cannot be read are skipped.
    init?(element: Element) {
        guard element.name == "prefs", element.namespace == MAM.namespace,
            let value = element[attribute: "default"].flatMap(Default.init(rawValue:))
        else { return nil }
        func jids(_ name: String) -> [JID] {
            (element.child(name, namespace: MAM.namespace)?.children(
                "jid", namespace: MAM.namespace)
                ?? []).compactMap { $0.trimmedText.flatMap { try? JID($0) } }
        }
        self.default = value
        always = jids("always")
        never = jids("never")
    }

    var element: Element {
        func list(_ name: String, _ jids: [JID]) -> XMLNode {
            .element(
                Element(
                    name, namespace: MAM.namespace,
                    children: jids.map {
                        .element(
                            Element(
                                "jid", namespace: MAM.namespace, children: [.text($0.description)]))
                    }))
        }
        return Element(
            "prefs", namespace: MAM.namespace, attributes: ["default": self.default.rawValue],
            children: [list("always", always), list("never", never)])
    }
}

/// The oldest and newest messages of an archive (XEP-0313 5). Archives that advertise
/// `MAM.extendedFeature` answer it; others answer with an error.
public struct MAMMetadata: Sendable, Hashable {
    public struct Bound: Sendable, Hashable {
        public var id: String
        public var timestamp: Date

        public init(id: String, timestamp: Date) {
            self.id = id
            self.timestamp = timestamp
        }

        init?(element: Element?) {
            guard let element, let id = element[attribute: "id"]?.nonEmpty,
                let timestamp = element[attribute: "timestamp"].flatMap(XMPPDateTime.parse)
            else { return nil }
            self.id = id
            self.timestamp = timestamp
        }
    }

    /// Nil for an empty archive.
    public var start: Bound?
    public var end: Bound?

    public init(start: Bound? = nil, end: Bound? = nil) {
        self.start = start
        self.end = end
    }
}

/// XEP-0313 Message Archive Management: the account's archive and each room's, read page by
/// page with XEP-0059 RSM.
public enum MAM {
    public static let namespace = "urn:xmpp:mam:2"
    /// The archive takes `after-id`, `before-id` and `ids` (and flipped pages and metadata).
    public static let extendedFeature = "urn:xmpp:mam:2#extended"
    /// The archive takes the `include-groupchat` field.
    public static let groupchatFieldFeature = "urn:xmpp:mam:2#groupchat-field"

    /// The query IQ; see `query`. Throws `.error(bad-request)` for an empty id, and
    /// `.error(feature-not-implemented)` for `afterID`,
    /// `beforeID` or `ids` when `archiveFeatures` lacks `extendedFeature` (XEP-0313 4.1: a
    /// client checks before it uses them).
    public static func queryRequest(
        archive: JID?, with: JID? = nil, start: Date? = nil, end: Date? = nil,
        afterID: String? = nil, beforeID: String? = nil, ids: [String] = [],
        includeGroupchat: Bool? = nil, page: RSM.Request.Position = .first, max: Int? = nil,
        queryID: String, archiveFeatures: Set<String> = []
    ) throws(IQError) -> Element {
        // An empty id is never sent: an empty <before/> asks for the last page (XEP-0059), so
        // an id that was lost would silently fetch the newest messages instead.
        let emptyPageID: Bool
        switch page {
        case .after(let id), .before(let id): emptyPageID = id.isEmpty
        default: emptyPageID = false
        }
        if emptyPageID || afterID?.isEmpty == true || beforeID?.isEmpty == true
            || ids.contains(where: \.isEmpty)
        {
            throw .error(StanzaError(type: .modify, condition: .badRequest))
        }
        if afterID != nil || beforeID != nil || !ids.isEmpty,
            !archiveFeatures.contains(extendedFeature)
        {
            throw .error(StanzaError(type: .cancel, condition: .featureNotImplemented))
        }
        var fields: [DataForm.Field] = []
        func add(_ variable: String, _ values: [String]) {
            fields.append(DataForm.Field(variable: variable, values: values))
        }
        if let with { add("with", [with.description]) }
        if let start { add("start", [XMPPDateTime.string(from: start)]) }
        if let end { add("end", [XMPPDateTime.string(from: end)]) }
        if let afterID { add("after-id", [afterID]) }
        if let beforeID { add("before-id", [beforeID]) }
        if !ids.isEmpty { add("ids", ids) }
        if let includeGroupchat, archiveFeatures.contains(groupchatFieldFeature) {
            add("include-groupchat", [includeGroupchat ? "true" : "false"])
        }
        var query = Element("query", namespace: namespace, attributes: ["queryid": queryID])
        if !fields.isEmpty {
            let formType = DataForm.Field(variable: "FORM_TYPE", type: .hidden, values: [namespace])
            query.append(DataForm(type: .submit, fields: [formType] + fields).element)
        }
        if max != nil || page != .first {
            query.append(RSM.Request(max: max, position: page).element)
        }
        return .iq(type: .set, to: archive?.bare, payload: query)
    }

    /// Asks `archive` (nil: the account's own) for the messages that match, one page of at
    /// most `max` in chronological order at `page`, and returns the `<fin/>` once they have
    /// come. The results arrive as separate messages, read with `result(from:...)`.
    ///
    /// - `with`, `start`, `end`: the filters every archive takes.
    /// - `afterID`, `beforeID`, `ids`: filters by archive id; only for an archive whose
    ///   `archiveFeatures` (its disco#info features) list `extendedFeature`. Elsewhere page
    ///   with `page: .after(id)` or `.before(id)`, which every archive takes.
    /// - `includeGroupchat`: sent only to an archive that lists `groupchatFieldFeature`;
    ///   elsewhere the server decides.
    /// - An id the archive does not know throws `.error(item-not-found)`.
    public static func query(
        archive: JID?, with: JID? = nil, start: Date? = nil, end: Date? = nil,
        afterID: String? = nil, beforeID: String? = nil, ids: [String] = [],
        includeGroupchat: Bool? = nil, page: RSM.Request.Position = .first, max: Int? = nil,
        queryID: String, archiveFeatures: Set<String> = [], via sender: any StanzaSending
    ) async throws(IQError) -> MAMFin {
        let request = try queryRequest(
            archive: archive, with: with, start: start, end: end, afterID: afterID,
            beforeID: beforeID, ids: ids, includeGroupchat: includeGroupchat, page: page,
            max: max, queryID: queryID, archiveFeatures: archiveFeatures)
        let result = try await sender.request(request)
        guard let fin = MAMFin(element: try result.resultPayload("fin", namespace: namespace))
        else { throw .malformedResponse }
        return fin
    }

    /// The query a result message belongs to, to find the query (and so the archive) it
    /// answers. Says nothing about whether the result can be trusted: `result(from:...)` does.
    public static func queryID(of message: Element) -> String? {
        guard message.name == "message" else { return nil }
        return message.child("result", namespace: namespace)?[attribute: "queryid"]?.nonEmpty
    }

    /// Whether `message` comes from `archive` (XEP-0313 8.2): for the account's own archive
    /// (nil, or the account's bare JID), from the account's bare JID or without `from`; for a
    /// room or channel, from its bare JID exactly.
    public static func isFromArchive(_ message: Element, archive: JID?, ownJID: JID) -> Bool {
        guard let archive, archive.bare != ownJID.bare else {
            return message.isFromOwnAccount(ownJID, allowingMissing: true)
        }
        guard let raw = message[attribute: "from"], let from = try? JID(raw) else { return false }
        return from == archive.bare
    }

    /// The result in `message` of the query `queryID` sent to `archive`. Nil when it is not a
    /// result of that query, when it does not come from that archive (anyone can send a
    /// message that looks like one), or when it cannot be read: no archive id, no stamp, or
    /// not exactly one forwarded message.
    public static func result(from message: Element, queryID: String, archive: JID?, ownJID: JID)
        -> MAMResult?
    {
        guard message.name == "message", isFromArchive(message, archive: archive, ownJID: ownJID)
        else { return nil }
        let results = message.children("result", namespace: namespace)
        guard results.count == 1, let result = results.first,
            result[attribute: "queryid"] == queryID,
            let archiveID = result[attribute: "id"]?.nonEmpty,
            let forwarded = result.child("forwarded", namespace: Forwarded.namespace),
            let (stanza, delay) = Forwarded.parse(forwarded), stanza.name == "message",
            let timestamp = delay
        else { return nil }
        return MAMResult(
            queryID: queryID, archiveID: archiveID, forwarded: stanza, timestamp: timestamp)
    }

    /// The first and last message of `archive` (nil: the account's own).
    public static func metadata(archive: JID?, via sender: any StanzaSending)
        async throws(IQError) -> MAMMetadata
    {
        let result = try await sender.request(
            .iq(type: .get, to: archive?.bare, payload: Element("metadata", namespace: namespace)))
        let metadata = try result.resultPayload("metadata", namespace: namespace)
        return MAMMetadata(
            start: MAMMetadata.Bound(element: metadata.child("start", namespace: namespace)),
            end: MAMMetadata.Bound(element: metadata.child("end", namespace: namespace)))
    }

    /// The account's archiving preferences (XEP-0441).
    public static func preferences(via sender: any StanzaSending) async throws(IQError)
        -> MAMPreferences
    {
        let result = try await sender.request(
            .iq(type: .get, payload: Element("prefs", namespace: namespace)))
        guard
            let preferences = MAMPreferences(
                element: try result.resultPayload("prefs", namespace: namespace))
        else { throw .malformedResponse }
        return preferences
    }

    /// Sets the account's archiving preferences; returns them as the server now has them.
    @discardableResult
    public static func setPreferences(_ preferences: MAMPreferences, via sender: any StanzaSending)
        async throws(IQError) -> MAMPreferences
    {
        let result = try await sender.request(.iq(type: .set, payload: preferences.element))
        guard
            let updated = MAMPreferences(
                element: try result.resultPayload("prefs", namespace: namespace))
        else { throw .malformedResponse }
        return updated
    }
}
