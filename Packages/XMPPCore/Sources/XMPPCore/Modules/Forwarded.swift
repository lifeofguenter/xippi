import Foundation

/// XEP-0297 Stanza Forwarding, which carbons (XEP-0280) and archive results (XEP-0313) wrap
/// messages in.
public enum Forwarded {
    public static let namespace = "urn:xmpp:forward:0"

    /// The stanza inside a `<forwarded/>` and the stamp of its `<delay/>`. Nil unless the
    /// first stanza child is a message, presence or IQ in `jabber:client` (or, from senders that
    /// leave out its xmlns, in the forwarding namespace it then inherits).
    public static func parse(_ forwarded: Element) -> (stanza: Element, delay: Date?)? {
        guard forwarded.name == "forwarded", forwarded.namespace == namespace,
            let stanza = forwarded.elements.first(where: { $0.namespace != Delay.namespace }),
            ["message", "presence", "iq"].contains(stanza.name),
            stanza.namespace == "jabber:client" || stanza.namespace == namespace
        else { return nil }
        return (stanza, Delay.stamp(in: forwarded))
    }
}
