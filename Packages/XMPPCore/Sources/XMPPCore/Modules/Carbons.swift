/// A copy of a message the account sent or received on another session (XEP-0280).
public struct CarbonCopy: Sendable, Hashable {
    public enum Direction: Sendable, Hashable {
        /// Sent by another session of this account.
        case sent
        /// Received by another session of this account.
        case received
    }

    public var direction: Direction
    /// The forwarded message.
    public var message: Element

    public init(direction: Direction, message: Element) {
        self.direction = direction
        self.message = message
    }
}

/// XEP-0280 Message Carbons. Enabling them is the connection's (inline with Bind2, or an IQ
/// after binding); this reads and marks messages.
public enum Carbons {
    public static let namespace = "urn:xmpp:carbons:2"

    /// The message has a `<sent/>` or `<received/>` carbon wrapper. One that `unwrap` refuses
    /// is a forgery: drop it, never read the outer message as a chat message.
    public static func isCarbon(_ message: Element) -> Bool {
        message.name == "message"
            && message.elements.contains {
                $0.namespace == namespace && ($0.name == "sent" || $0.name == "received")
            }
    }

    /// The carbon in `message`, when it is a genuine one (XEP-0280 section 11): the outer
    /// message comes from the account's bare JID (`from` present), it carries exactly one
    /// wrapper, and the forwarded message involves the account: a sent copy is from it, a
    /// received copy is to it. Nil otherwise, including for messages that are no carbons.
    public static func unwrap(_ message: Element, ownJID: JID) -> CarbonCopy? {
        guard message.name == "message", message.isFromOwnAccount(ownJID, allowingMissing: false)
        else { return nil }
        let wrappers = message.elements.filter {
            $0.namespace == namespace && ($0.name == "sent" || $0.name == "received")
        }
        guard wrappers.count == 1, let wrapper = wrappers.first,
            let forwarded = wrapper.child("forwarded", namespace: Forwarded.namespace),
            let (inner, _) = Forwarded.parse(forwarded), inner.name == "message"
        else { return nil }
        let own = ownJID.bare
        switch wrapper.name {
        case "sent":
            guard inner.from?.bare == own else { return nil }
            return CarbonCopy(direction: .sent, message: inner)
        default:
            guard inner.to?.bare == own else { return nil }
            return CarbonCopy(direction: .received, message: inner)
        }
    }

    /// The elements that keep a sent message out of carbons: `<private/>` and the XEP-0334
    /// `<no-copy/>` hint.
    public static let privateElements: [Element] = [
        Element("private", namespace: namespace),
        Element("no-copy", namespace: ChatMessage.hintsNamespace),
    ]
}
