import Foundation
import XMPPCore

/// A parsed `xmpp:` URI (RFC 5122) with the XEP-0147 query actions and the
/// XEP-0401 `preauth` and `ibr` parameters.
public struct XMPPURI: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case message, join, subscribe, unsubscribe, register, roster, remove, invite
    }

    /// The address the URI points at.
    public let jid: JID
    /// The account to authenticate as, from `xmpp://account@domain/target`.
    public let authority: JID?
    public let action: Action?
    /// The decoded key-value pairs of the query (the first value of a repeated key wins).
    public let params: [String: String]

    public init(
        jid: JID, authority: JID? = nil, action: Action? = nil, params: [String: String] = [:]
    ) {
        self.jid = jid
        self.authority = authority
        self.action = action
        self.params = params
    }

    public init?(url: URL) {
        let raw = url.absoluteString
        guard raw.prefix(5).lowercased() == "xmpp:" else { return nil }
        var rest = Substring(raw.dropFirst(5))
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }

        var query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = rest[..<mark]
        }

        var authority: JID?
        var path = rest
        if rest.hasPrefix("//") {
            let afterSlashes = rest.dropFirst(2)
            let end = afterSlashes.firstIndex(of: "/") ?? afterSlashes.endIndex
            guard let parsed = Self.jid(fromRaw: afterSlashes[..<end]) else { return nil }
            authority = parsed
            path =
                end < afterSlashes.endIndex ? afterSlashes[afterSlashes.index(after: end)...] : ""
        } else if rest.hasPrefix("/") {
            return nil
        }
        guard !path.isEmpty, let jid = Self.jid(fromRaw: path) else { return nil }

        var action: Action?
        var params: [String: String] = [:]
        if let query, !query.isEmpty {
            // RFC 5122 separates pairs with ";", "&" is common in the wild.
            let parts = query.split(omittingEmptySubsequences: true) { $0 == ";" || $0 == "&" }
            for (position, part) in parts.enumerated() {
                if let equals = part.firstIndex(of: "=") {
                    guard let key = Self.decode(part[..<equals]),
                        let value = Self.decode(part[part.index(after: equals)...])
                    else { return nil }
                    if params[key] == nil { params[key] = value }
                } else {
                    guard let name = Self.decode(part) else { return nil }
                    if position == 0 {
                        action = Action(rawValue: name)
                    } else if params[name] == nil {
                        params[name] = ""
                    }
                }
            }
        }

        self.init(jid: jid, authority: authority, action: action, params: params)
    }

    private static func decode(_ part: Substring) -> String? {
        String(part).removingPercentEncoding
    }

    /// Splits the raw (still escaped) text at the first "/" and the first "@" before it
    /// and decodes each part on its own, so an escaped "@" or "/" never changes the structure.
    private static func jid(fromRaw raw: Substring) -> JID? {
        var rest = raw
        var resource: String?
        if let slash = rest.firstIndex(of: "/") {
            guard let decoded = decode(rest[rest.index(after: slash)...]) else { return nil }
            resource = decoded
            rest = rest[..<slash]
        }
        var local: String?
        if let at = rest.firstIndex(of: "@") {
            guard let decoded = decode(rest[..<at]) else { return nil }
            local = decoded
            rest = rest[rest.index(after: at)...]
        }
        guard let domain = decode(rest) else { return nil }
        return try? JID(localpart: local, domainpart: domain, resourcepart: resource)
    }
}
