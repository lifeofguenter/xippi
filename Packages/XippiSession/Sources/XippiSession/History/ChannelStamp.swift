import Foundation
import XMPPCore

/// What a MIX channel stamps on a message it serves (XEP-0369 `<mix/>`): the sender's nick
/// and, unless the channel is anonymous, its real JID. Read only from a message the channel
/// itself serves (its own archive's result, or live from the channel's JID), and only when
/// there is exactly one stamp: with more than one, a sender added its own, and none is taken.
///
/// ejabberd 26.09 stamps in the namespace of XEP-0369 before 0.14 (`urn:xmpp:mix:core:0`)
/// while it answers joins in `core:1`; a stamp in either is read, one stamp in all.
struct ChannelStamp: Sendable, Equatable {
    static let legacyNamespace = "urn:xmpp:mix:core:0"

    var nick: String?
    var jid: JID?

    init(nick: String?, jid: JID?) {
        self.nick = nick
        self.jid = jid
    }

    /// The one stamp of the message; nil without one, or with several.
    init?(of message: Element) {
        guard case .one(let stamp) = ChannelStamps(of: message) else { return nil }
        self = stamp
    }
}

/// The stamps a channel put on a message: none, exactly one (believed), or several (a sender
/// added its own, so none is believed).
enum ChannelStamps: Sendable, Equatable {
    case none
    case one(ChannelStamp)
    case several

    init(of message: Element) {
        let stamps = message.elements.filter {
            $0.name == "mix"
                && ($0.namespace == MIX.coreNamespace
                    || $0.namespace == ChannelStamp.legacyNamespace)
        }
        guard let stamp = stamps.first else {
            self = .none
            return
        }
        guard stamps.count == 1 else {
            self = .several
            return
        }
        let namespace = stamp.namespace
        let nick = stamp.child("nick", namespace: namespace)?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self = .one(
            ChannelStamp(
                nick: nick?.isEmpty == false ? nick : nil,
                jid: stamp.child("jid", namespace: namespace).flatMap {
                    try? JID($0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }))
    }

    /// What a channel message from `from` is stored under, its nick and sender address, so
    /// that senders stay apart without a participant id ever shown as a name:
    /// - The one stamp's nick, else its real JID, with `from` as the address.
    /// - No name stamped and a participant id in `from`: no nick (""), with `from` as the
    ///   address. The app shows a participant without a name, kept apart by that id.
    /// - Several stamps, or no name and no participant id (a bare channel `from`): no nick,
    ///   with the bare channel as the address. The app shows an unknown sender, a group of
    ///   its own message that never merges with anyone.
    ///
    /// The participants node holds the same nick the channel stamps, so it has nothing more
    /// to give.
    func sender(from: JID) -> (nick: String, jid: String) {
        let name: String? =
            switch self {
            case .one(let stamp): stamp.nick ?? stamp.jid?.bare.description
            case .none, .several: nil
            }
        if let name { return (name, from.description) }
        if self != .several, from.resourcepart?.isEmpty == false {
            return ("", from.description)
        }
        return ("", from.bare.description)
    }
}
