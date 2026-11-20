import Foundation

public enum IQType: String, Sendable {
    case get, set, result, error
}

extension String {
    /// 22 characters of base64url (no padding) from 16 random bytes.
    public static func stanzaID() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 { bytes.append(UInt8.random(in: .min ... .max, using: &rng)) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Element {
    public var id: String? { self[attribute: "id"] }
    public var type: String? { self[attribute: "type"] }

    /// nil when absent or not a valid JID.
    public var from: JID? { self[attribute: "from"].flatMap { try? JID($0) as JID } }
    public var to: JID? { self[attribute: "to"].flatMap { try? JID($0) as JID } }

    public static func iq(
        type: IQType, id: String = .stanzaID(), to: JID? = nil, payload: Element?
    ) -> Element {
        var e = Element("iq", attributes: ["type": type.rawValue, "id": id])
        if let to { e[attribute: "to"] = to.description }
        if let payload { e.append(payload) }
        return e
    }

    public static func message(
        type: String? = "chat", id: String = .stanzaID(), to: JID? = nil, body: String? = nil,
        children: [Element] = []
    ) -> Element {
        var e = Element("message", attributes: ["id": id])
        if let type { e[attribute: "type"] = type }
        if let to { e[attribute: "to"] = to.description }
        if let body { e.append(Element("body", children: [.text(body)])) }
        for c in children { e.append(c) }
        return e
    }

    public static func presence(
        type: String? = nil, id: String = .stanzaID(), to: JID? = nil, children: [Element] = []
    ) -> Element {
        var e = Element("presence", attributes: ["id": id])
        if let type { e[attribute: "type"] = type }
        if let to { e[attribute: "to"] = to.description }
        for c in children { e.append(c) }
        return e
    }

    /// Reply with type result, addresses swapped and the same id.
    public func iqResult(payload: Element? = nil) -> Element {
        var e = Element("iq", attributes: ["type": IQType.result.rawValue])
        if let id { e[attribute: "id"] = id }
        e[attribute: "to"] = self[attribute: "from"]
        e[attribute: "from"] = self[attribute: "to"]
        if let payload { e.append(payload) }
        return e
    }

    /// Error reply: addresses swapped, the original children kept, the error appended in the
    /// stanza's own namespace (RFC 6120 8.3.2), `jabber:client` for a stanza read off the
    /// stream.
    public func errorResponse(_ error: StanzaError) -> Element {
        var e = Element(name, namespace: namespace, attributes: attributes, children: children)
        e[attribute: "type"] = "error"
        e[attribute: "to"] = self[attribute: "from"]
        e[attribute: "from"] = self[attribute: "to"]
        var errorElement = error.element
        errorElement.namespace = namespace
        e.append(errorElement)
        return e
    }
}
