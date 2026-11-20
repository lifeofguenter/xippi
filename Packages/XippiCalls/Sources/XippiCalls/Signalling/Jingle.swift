import XMPPCore

/// The namespaces of Jingle and the extensions calls use, each checked against its XEP.
public enum JingleNamespace {
    /// XEP-0166
    public static let jingle = "urn:xmpp:jingle:1"
    /// XEP-0166 error conditions (out-of-order, tie-break, unknown-session, unsupported-info)
    public static let errors = "urn:xmpp:jingle:errors:1"
    /// XEP-0167
    public static let rtp = "urn:xmpp:jingle:apps:rtp:1"
    /// XEP-0167 session-info payloads (ringing, mute, hold)
    public static let rtpInfo = "urn:xmpp:jingle:apps:rtp:info:1"
    /// XEP-0176
    public static let iceUDP = "urn:xmpp:jingle:transports:ice-udp:1"
    /// XEP-0320
    public static let dtls = "urn:xmpp:jingle:apps:dtls:0"
    /// XEP-0338
    public static let grouping = "urn:xmpp:jingle:apps:grouping:0"
    /// XEP-0293
    public static let rtcpFeedback = "urn:xmpp:jingle:apps:rtp:rtcp-fb:0"
    /// XEP-0294
    public static let headerExtensions = "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0"
    /// XEP-0339
    public static let sourceAttributes = "urn:xmpp:jingle:apps:rtp:ssma:0"
    /// ICE options (`trickle`, `renomination`) as Conversations and Monal send them; no XEP
    /// defines them.
    public static let iceOption = "http://gultsch.de/xmpp/drafts/jingle/transports/ice-udp/option"
    /// XEP-0353
    public static let message = "urn:xmpp:jingle-message:0"
    /// XEP-0234
    public static let fileTransfer = "urn:xmpp:jingle:apps:file-transfer:5"
    /// XEP-0300
    public static let hashes = "urn:xmpp:hashes:2"
    /// XEP-0215
    public static let externalServices = "urn:xmpp:extdisco:2"
    /// XEP-0334
    public static let hints = "urn:xmpp:hints"
}

/// The `action` of a `<jingle/>` element (XEP-0166 section 7.2).
public enum JingleAction: String, Sendable, CaseIterable {
    case contentAccept = "content-accept"
    case contentAdd = "content-add"
    case contentModify = "content-modify"
    case contentReject = "content-reject"
    case contentRemove = "content-remove"
    case descriptionInfo = "description-info"
    case securityInfo = "security-info"
    case sessionAccept = "session-accept"
    case sessionInfo = "session-info"
    case sessionInitiate = "session-initiate"
    case sessionTerminate = "session-terminate"
    case transportAccept = "transport-accept"
    case transportInfo = "transport-info"
    case transportReject = "transport-reject"
    case transportReplace = "transport-replace"
}

/// The two parties of a session, as named in `creator`, `senders`, `initiator` and `responder`.
public enum JingleRole: String, Sendable, CaseIterable {
    case initiator, responder

    public var other: JingleRole { self == .initiator ? .responder : .initiator }
}

/// A `<reason/>` (XEP-0166 section 7.4), as carried by session-terminate, content-reject and the
/// Jingle Message Initiation messages.
public struct JingleReason: Sendable, Equatable {
    /// The conditions XEP-0166 defines.
    public static let conditions: Set<String> = [
        "alternative-session", "busy", "cancel", "connectivity-error", "decline", "expired",
        "failed-application", "failed-transport", "general-error", "gone",
        "incompatible-parameters", "media-error", "security-error", "success", "timeout",
        "unsupported-applications", "unsupported-transports",
    ]

    /// The name of the condition element. Kept as received, so a condition from a newer
    /// specification (or a misspelt one) can still be shown; compare against `conditions`.
    public var condition: String
    public var text: String?
    /// The `<sid/>` of an `alternative-session` condition.
    public var alternativeSessionID: String?
    /// Elements in other namespaces that refine the condition, such as XEP-0234's
    /// `<file-not-available/>`.
    public var details: [Element]

    public init(
        condition: String, text: String? = nil, alternativeSessionID: String? = nil,
        details: [Element] = []
    ) {
        self.condition = condition
        self.text = text
        self.alternativeSessionID = alternativeSessionID
        self.details = details
    }

    /// Reads a `<reason/>` in the Jingle namespace; nil when it has no condition.
    public init?(element: Element) {
        guard element.name == "reason", element.namespace == JingleNamespace.jingle else {
            return nil
        }
        var condition: Element?
        var text: String?
        var details: [Element] = []
        for child in element.elements {
            if child.namespace == JingleNamespace.jingle {
                if child.name == "text" {
                    if text == nil { text = child.text }
                } else if condition == nil {
                    condition = child
                }
            } else {
                details.append(child)
            }
        }
        guard let condition else { return nil }
        self.condition = condition.name
        self.text = text
        self.details = details
        if condition.name == "alternative-session",
            let sid = condition.child("sid", namespace: JingleNamespace.jingle)?.text,
            !sid.isEmpty
        {
            alternativeSessionID = sid
        }
    }

    public var element: Element {
        var reason = Element("reason", namespace: JingleNamespace.jingle)
        var condition = Element(self.condition, namespace: JingleNamespace.jingle)
        if let alternativeSessionID {
            condition.append(
                Element(
                    "sid", namespace: JingleNamespace.jingle,
                    children: [.text(alternativeSessionID)]))
        }
        reason.append(condition)
        if let text {
            reason.append(
                Element("text", namespace: JingleNamespace.jingle, children: [.text(text)]))
        }
        for detail in details { reason.append(detail) }
        return reason
    }
}

/// A `<content/>` of a Jingle action. The application, transport and security elements are kept
/// whole; `RTPDescription`, `ICEUDPTransport` and `JingleFileTransferDescription` read them.
public struct JingleContent: Sendable, Equatable {
    public static let creators: Set<String> = ["initiator", "responder"]
    public static let sendersValues: Set<String> = ["both", "initiator", "none", "responder"]

    /// "initiator" or "responder": who added the content, not who sends this action.
    public var creator: String
    public var name: String
    /// "both", "initiator", "none" or "responder"; nil means "both".
    public var senders: String?
    public var description: Element?
    public var transport: Element?
    public var security: Element?

    public init(
        creator: String, name: String, senders: String? = nil, description: Element? = nil,
        transport: Element? = nil, security: Element? = nil
    ) {
        self.creator = creator
        self.name = name
        self.senders = senders
        self.description = description
        self.transport = transport
        self.security = security
    }

    /// Reads a `<content/>`; nil when the name is missing or `creator` or `senders` has a value
    /// XEP-0166 does not define. A missing creator is read as "initiator", as Dino does.
    public init?(element: Element) {
        guard element.name == "content", element.namespace == JingleNamespace.jingle,
            let name = element[attribute: "name"], !name.isEmpty
        else { return nil }
        let creator = element[attribute: "creator"] ?? JingleRole.initiator.rawValue
        guard Self.creators.contains(creator) else { return nil }
        let senders = element[attribute: "senders"]
        if let senders, !Self.sendersValues.contains(senders) { return nil }
        self.creator = creator
        self.name = name
        self.senders = senders
        description = element.child("description")
        transport = element.child("transport")
        security = element.child("security")
    }

    public var element: Element {
        var content = Element(
            "content", namespace: JingleNamespace.jingle,
            attributes: ["creator": creator, "name": name])
        if let senders { content[attribute: "senders"] = senders }
        if let description { content.append(description) }
        if let transport { content.append(transport) }
        if let security { content.append(security) }
        return content
    }
}

/// The `<jingle/>` payload of a Jingle IQ (XEP-0166).
public struct JingleIQ: Sendable, Equatable {
    public var action: JingleAction
    public var sid: String
    public var initiator: JID?
    public var responder: JID?
    public var contents: [JingleContent]
    public var reason: JingleReason?
    /// Every other child of `<jingle/>`: session-info payloads, the XEP-0338 `<group/>`, and
    /// anything else, in the order received.
    public var info: [Element]

    public init(
        action: JingleAction, sid: String, initiator: JID? = nil, responder: JID? = nil,
        contents: [JingleContent] = [], reason: JingleReason? = nil, info: [Element] = []
    ) {
        self.action = action
        self.sid = sid
        self.initiator = initiator
        self.responder = responder
        self.contents = contents
        self.reason = reason
        self.info = info
    }

    /// Reads an `<iq/>` carrying `<jingle/>`, or the `<jingle/>` element itself. Nil when the
    /// action is unknown, the sid is missing, `initiator` or `responder` is not a JID, or a
    /// content is malformed: the IQ then deserves a bad-request error. A malformed reason is
    /// dropped rather than failing the whole action.
    public init?(element: Element) {
        let jingle: Element
        if element.name == "jingle", element.namespace == JingleNamespace.jingle {
            jingle = element
        } else if element.name == "iq",
            let child = element.child("jingle", namespace: JingleNamespace.jingle)
        {
            jingle = child
        } else {
            return nil
        }
        guard let actionValue = jingle[attribute: "action"],
            let action = JingleAction(rawValue: actionValue),
            let sid = jingle[attribute: "sid"], !sid.isEmpty
        else { return nil }
        var initiator: JID?
        if let value = jingle[attribute: "initiator"] {
            guard let jid = try? JID(value) else { return nil }
            initiator = jid
        }
        var responder: JID?
        if let value = jingle[attribute: "responder"] {
            guard let jid = try? JID(value) else { return nil }
            responder = jid
        }
        var contents: [JingleContent] = []
        var reason: JingleReason?
        var info: [Element] = []
        for child in jingle.elements {
            if child.namespace == JingleNamespace.jingle, child.name == "content" {
                guard let content = JingleContent(element: child) else { return nil }
                contents.append(content)
            } else if child.namespace == JingleNamespace.jingle, child.name == "reason" {
                if reason == nil { reason = JingleReason(element: child) }
            } else {
                info.append(child)
            }
        }
        self.action = action
        self.sid = sid
        self.initiator = initiator
        self.responder = responder
        self.contents = contents
        self.reason = reason
        self.info = info
    }

    /// The `<jingle/>` element, to go into an IQ of type set.
    public var element: Element {
        var jingle = Element(
            "jingle", namespace: JingleNamespace.jingle,
            attributes: ["action": action.rawValue, "sid": sid])
        if let initiator { jingle[attribute: "initiator"] = initiator.description }
        if let responder { jingle[attribute: "responder"] = responder.description }
        for content in contents { jingle.append(content.element) }
        if let reason { jingle.append(reason.element) }
        for element in info { jingle.append(element) }
        return jingle
    }
}
