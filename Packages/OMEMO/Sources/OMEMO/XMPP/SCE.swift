import Foundation
import XMPPCore

/// Why a decrypted XEP-0420 envelope was refused.
public enum SCEError: Error, Sendable, Equatable {
    /// Not well-formed, restricted XML, or more than one element.
    case invalidXML
    /// The root is not one `<envelope/>` with one `<content/>`.
    case notAnEnvelope
    /// A room message without the `<to/>` affix (XEP-0384 requires it in group chats).
    case missingRecipient
    /// `<to/>` names someone other than the stanza's recipient (or room).
    case recipientMismatch
    /// `<from/>` names someone other than the stanza's sender.
    case senderMismatch
}

/// XEP-0420 Stanza Content Encryption, the profile OMEMO 2 uses: the encrypted payload is an
/// `<envelope/>` whose `<content/>` holds the message's elements, with random padding (`<rpad/>`,
/// required), the time of encryption (`<time/>`), the recipient (`<to/>`, required in group
/// chats) and the sender (`<from/>`), all bare JIDs.
public enum SCE {
    public static let namespace = "urn:xmpp:sce:1"

    /// The namespaces of elements a server acts on, which XEP-0420 keeps out of `<content/>`:
    /// processing hints, stanza and origin ids, extended addressing, and EME. A receiver drops
    /// them.
    static let serverProcessedNamespaces: Set<String> = [
        "urn:xmpp:hints", "urn:xmpp:sid:0", "http://jabber.org/protocol/address",
        "urn:xmpp:eme:0",
    ]

    public struct Envelope: Sendable, Equatable {
        /// The message's elements, each with its namespace (`<body/>` in `jabber:client`).
        public var content: [Element]
        public var padding: String?
        public var time: Date?
        public var to: JID?
        public var from: JID?

        public init(
            content: [Element], padding: String?, time: Date?, to: JID?, from: JID?
        ) {
            self.content = content
            self.padding = padding
            self.time = time
            self.to = to
            self.from = from
        }

        public var element: Element {
            var envelope = Element("envelope", namespace: SCE.namespace)
            envelope.append(
                Element("content", namespace: SCE.namespace, children: content.map { .element($0) })
            )
            if let padding {
                envelope.append(
                    Element("rpad", namespace: SCE.namespace, children: [.text(padding)]))
            }
            if let time {
                envelope.append(
                    Element(
                        "time", namespace: SCE.namespace,
                        attributes: ["stamp": XMPPDateTime.string(from: time)]))
            }
            if let to {
                envelope.append(
                    Element("to", namespace: SCE.namespace, attributes: ["jid": to.description]))
            }
            if let from {
                envelope.append(
                    Element("from", namespace: SCE.namespace, attributes: ["jid": from.description])
                )
            }
            return envelope
        }

        /// Reads a decrypted payload.
        ///
        /// - Elements in `<content/>` without a namespace of their own, and those in
        ///   `serverProcessedNamespaces`, are dropped. A `<body/>` written without a namespace
        ///   (so in the envelope's) is read as `jabber:client`, the namespace XEP-0420 requires.
        /// - A `<time/>` whose stamp cannot be read counts as absent; `<to/>` or `<from/>` with
        ///   a JID that cannot be read is a mismatch.
        public init(parsing data: Data) throws(SCEError) {
            let root = try Self.singleElement(data)
            guard root.name == "envelope", root.namespace == SCE.namespace else {
                throw .notAnEnvelope
            }
            let contents = root.children("content", namespace: SCE.namespace)
            guard contents.count == 1, let content = contents.first else {
                throw .notAnEnvelope
            }
            self.content = content.elements.compactMap { element in
                if element.name == "body", element.namespace == SCE.namespace {
                    var body = element
                    body.namespace = "jabber:client"
                    return body
                }
                guard let namespace = element.namespace, namespace != SCE.namespace,
                    !SCE.serverProcessedNamespaces.contains(namespace)
                else { return nil }
                return element
            }
            padding = root.child("rpad", namespace: SCE.namespace)?.text
            time = root.child("time", namespace: SCE.namespace)?[attribute: "stamp"].flatMap(
                XMPPDateTime.parse)
            to = try Self.jid(root, "to", else: .recipientMismatch)
            from = try Self.jid(root, "from", else: .senderMismatch)
        }

        /// Checks the affixes against the stanza: `<from/>`, when present, must be `sender`;
        /// `<to/>` must be the room in a room message, and when present the recipient in a
        /// direct one. This keeps a server from turning a room message into a direct one or
        /// back, or passing one person's message off as another's.
        public func verify(sender: JID, recipient: MessageRecipient) throws(SCEError) {
            switch recipient {
            case .room(let room):
                guard let to else { throw .missingRecipient }
                guard to.bare == room.bare else { throw .recipientMismatch }
            case .direct(let jid):
                if let to, to.bare != jid.bare { throw .recipientMismatch }
            }
            if let from, from.bare != sender.bare { throw .senderMismatch }
        }

        private static func jid(
            _ root: Element, _ name: String, else error: SCEError
        ) throws(SCEError) -> JID? {
            guard let element = root.child(name, namespace: SCE.namespace) else { return nil }
            guard let value = element[attribute: "jid"], let jid = try? JID(value) else {
                throw error
            }
            return jid.bare
        }

        /// The one element `data` holds, read with the stream parser's limits and restrictions.
        private static func singleElement(_ data: Data) throws(SCEError) -> Element {
            var parser = XMLStreamParser()
            var events = parser.feed(
                Array(
                    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
                        .utf8))
            events += parser.feed(data)
            events += parser.feed(Array("</stream:stream>".utf8))
            guard events.count == 3, case .streamOpened = events[0],
                case .stanza(let element) = events[1], case .streamClosed = events[2]
            else { throw .invalidXML }
            return element
        }
    }

    /// Random padding for `<rpad/>`: a short message is padded to at least 128 bytes, and then
    /// 1 to 200 more characters are added, so the length of the ciphertext says little about the
    /// length of the message.
    static func randomPadding(contentLength: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        let length = max(0, 128 - contentLength) + Int.random(in: 1...200)
        var padding = [UInt8]()
        padding.reserveCapacity(length)
        for _ in 0..<length {
            padding.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return String(decoding: padding, as: UTF8.self)
    }
}
