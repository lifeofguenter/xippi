import XMPPCore

/// A Jingle Message Initiation message (XEP-0353).
public enum JMIAction: Sendable, Equatable {
    /// The initiator wants to call; sent to the responder's bare JID so every device rings.
    case propose(sid: String, media: [JingleMedia])
    /// A device of the responder is ringing.
    case ringing(sid: String)
    /// The initiator gave up before an answer.
    case retract(sid: String, reason: JingleReason?, tieBreak: Bool)
    /// The responder took the call on one device, sent to its own bare JID. The legacy way
    /// of stopping the other devices' ringing, still sent by Conversations and Dino; XEP-0353
    /// 0.8.0 relies on the carbon of `proceed` instead. Only valid from the own bare JID,
    /// which the caller checks.
    case accept(sid: String)
    /// The responder declined.
    case reject(sid: String, reason: JingleReason?, tieBreak: Bool)
    /// The responder took the call; the initiator now sends session-initiate to that device.
    case proceed(sid: String)
    /// The call ended. `migratedTo` names the session that replaces it.
    case finish(sid: String, reason: JingleReason?, migratedTo: String?)

    public var sid: String {
        switch self {
        case .propose(let sid, _), .ringing(let sid), .retract(let sid, _, _), .accept(let sid),
            .reject(let sid, _, _), .proceed(let sid), .finish(let sid, _, _):
            sid
        }
    }
}

/// Builds and reads Jingle Message Initiation payloads (XEP-0353, `urn:xmpp:jingle-message:0`).
///
/// The builders return the payload; `message(to:payload:)` puts it in the `type="chat"`
/// message with a `<store/>` hint the XEP requires, so carbons and the archive carry it.
public enum JMI {
    public static let namespace = JingleNamespace.message

    public static func propose(sid: String, media: [JingleMedia]) -> Element {
        var propose = payload("propose", sid: sid)
        for medium in media {
            propose.append(
                Element(
                    "description", namespace: JingleNamespace.rtp,
                    attributes: ["media": medium.rawValue]))
        }
        return propose
    }

    public static func ringing(sid: String) -> Element {
        payload("ringing", sid: sid)
    }

    /// XEP-0353 asks for a cancel reason, and expired with a tie-break when two proposes cross.
    public static func retract(
        sid: String, reason: JingleReason? = JingleReason(condition: "cancel"),
        tieBreak: Bool = false
    ) -> Element {
        payload("retract", sid: sid, reason: reason, tieBreak: tieBreak)
    }

    public static func accept(sid: String) -> Element {
        payload("accept", sid: sid)
    }

    /// XEP-0353 asks for a busy reason, and expired with a tie-break when two proposes cross.
    public static func reject(
        sid: String, reason: JingleReason? = JingleReason(condition: "busy"),
        tieBreak: Bool = false
    ) -> Element {
        payload("reject", sid: sid, reason: reason, tieBreak: tieBreak)
    }

    public static func proceed(sid: String) -> Element {
        payload("proceed", sid: sid)
    }

    public static func finish(sid: String, reason: JingleReason, migratedTo: String? = nil)
        -> Element
    {
        var finish = payload("finish", sid: sid, reason: reason)
        if let migratedTo {
            finish.append(Element("migrated", namespace: namespace, attributes: ["to": migratedTo]))
        }
        return finish
    }

    /// The `<message type="chat"/>` that carries `payload`, with the `<store/>` hint.
    public static func message(to: JID, payload: Element, id: String = .stanzaID()) -> Element {
        Element.message(
            type: "chat", id: id, to: to,
            children: [payload, Element("store", namespace: JingleNamespace.hints)])
    }

    /// The JMI action a message carries; nil for a groupchat or error message, a payload
    /// without an id, or a propose with no audio or video description.
    public static func parse(_ message: Element) -> JMIAction? {
        guard message.name == "message" else { return nil }
        if let type = message.type, type == "groupchat" || type == "error" { return nil }
        for child in message.elements where child.namespace == namespace {
            if let action = action(child) { return action }
        }
        return nil
    }

    static func action(_ element: Element) -> JMIAction? {
        guard let sid = element[attribute: "id"], !sid.isEmpty else { return nil }
        let reason = element.child("reason", namespace: JingleNamespace.jingle)
            .flatMap(JingleReason.init(element:))
        let tieBreak = element.child("tie-break", namespace: namespace) != nil
        switch element.name {
        case "propose":
            var media: [JingleMedia] = []
            for description in element.children("description", namespace: JingleNamespace.rtp) {
                if let medium = description[attribute: "media"].flatMap(
                    JingleMedia.init(rawValue:)),
                    !media.contains(medium)
                {
                    media.append(medium)
                }
            }
            return media.isEmpty ? nil : .propose(sid: sid, media: media)
        case "ringing":
            return .ringing(sid: sid)
        case "retract":
            return .retract(sid: sid, reason: reason, tieBreak: tieBreak)
        case "accept":
            return .accept(sid: sid)
        case "reject":
            return .reject(sid: sid, reason: reason, tieBreak: tieBreak)
        case "proceed":
            return .proceed(sid: sid)
        case "finish":
            let migratedTo = element.child("migrated", namespace: namespace)?[attribute: "to"]
            return .finish(
                sid: sid, reason: reason,
                migratedTo: migratedTo.flatMap { $0.isEmpty ? nil : $0 })
        default:
            return nil
        }
    }

    static func payload(
        _ name: String, sid: String, reason: JingleReason? = nil, tieBreak: Bool = false
    ) -> Element {
        var element = Element(name, namespace: namespace, attributes: ["id": sid])
        if let reason { element.append(reason.element) }
        if tieBreak { element.append(Element("tie-break", namespace: namespace)) }
        return element
    }
}
