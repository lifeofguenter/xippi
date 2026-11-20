/// RFC 6120 section 8.3 stanza error.
public struct StanzaError: Error, Sendable, Equatable {
    public enum ErrorType: String, Sendable {
        case auth, cancel, `continue`, modify, wait
    }

    public enum Condition: String, Sendable, CaseIterable {
        case badRequest = "bad-request"
        case conflict
        case featureNotImplemented = "feature-not-implemented"
        case forbidden
        case gone
        case internalServerError = "internal-server-error"
        case itemNotFound = "item-not-found"
        case jidMalformed = "jid-malformed"
        case notAcceptable = "not-acceptable"
        case notAllowed = "not-allowed"
        case notAuthorized = "not-authorized"
        case policyViolation = "policy-violation"
        case recipientUnavailable = "recipient-unavailable"
        case redirect
        case registrationRequired = "registration-required"
        case remoteServerNotFound = "remote-server-not-found"
        case remoteServerTimeout = "remote-server-timeout"
        case resourceConstraint = "resource-constraint"
        case serviceUnavailable = "service-unavailable"
        case subscriptionRequired = "subscription-required"
        case undefinedCondition = "undefined-condition"
        case unexpectedRequest = "unexpected-request"
    }

    public static let namespace = "urn:ietf:params:xml:ns:xmpp-stanzas"

    public var type: ErrorType
    public var condition: Condition
    public var text: String?

    public init(type: ErrorType, condition: Condition, text: String? = nil) {
        self.type = type
        self.condition = condition
        self.text = text
    }

    /// Parses an `<error/>` element; nil when the type or condition is unknown.
    public init?(element: Element) {
        guard element.name == "error",
            let rawType = element[attribute: "type"], let type = ErrorType(rawValue: rawType)
        else { return nil }
        var found: Condition?
        for child in element.elements
        where child.namespace == Self.namespace && child.name != "text" {
            if let c = Condition(rawValue: child.name) {
                found = c
                break
            }
        }
        guard let condition = found else { return nil }
        self.type = type
        self.condition = condition
        self.text = element.child("text", namespace: Self.namespace)?.text
    }

    public var element: Element {
        var error = Element("error", attributes: ["type": type.rawValue])
        error.append(Element(condition.rawValue, namespace: Self.namespace))
        if let text {
            error.append(Element("text", namespace: Self.namespace, children: [.text(text)]))
        }
        return error
    }
}
