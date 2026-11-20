/// What this client is, as other entities discover it (XEP-0030, XEP-0115).
public enum XippiClient {
    public static let name = "Xippi"
    /// The caps node (XEP-0115).
    public static let node = "https://xippi.eu"
    public static let identity = DiscoInfo.Identity(category: "client", type: "pc", name: name)

    /// Every feature the client advertises: the single list, answered to disco#info and hashed
    /// into the caps ver.
    ///
    /// Every entry must be backed by an implementation the shipped app uses, because peers act
    /// on it: they send carbons, markers, reactions, Jingle offers and PEP notifications only to
    /// clients that list them. Add a feature when its implementation lands, never before, and
    /// remove it with its implementation. Task 27's audit checks each entry against the code.
    /// Stream features (CSI, Stream Management) and server or room features (blocking, reporting,
    /// stanza ids, occupant ids, moderation) do not belong here: the client uses them, it does
    /// not offer them.
    public static let features: [String] = [
        // Discovery and entity information (XEP-0030, 0115, 0199, 0092, 0202).
        "http://jabber.org/protocol/disco#info",
        "http://jabber.org/protocol/disco#items",
        "http://jabber.org/protocol/caps",
        "urn:xmpp:ping",
        "jabber:iq:version",
        "urn:xmpp:time",

        // Messaging (XEP-0184, 0333, 0085, 0280, 0308, 0424, 0444, 0461, 0428, 0393).
        "urn:xmpp:receipts",
        "urn:xmpp:chat-markers:0",
        "http://jabber.org/protocol/chatstates",
        "urn:xmpp:carbons:2",
        "urn:xmpp:message-correct:0",
        "urn:xmpp:message-retract:1",
        "urn:xmpp:reactions:0",
        "urn:xmpp:reply:0",
        "urn:xmpp:fallback:0",
        "urn:xmpp:styling:0",

        // PEP notifications this client consumes (XEP-0490, 0402, 0084, 0172, 0292, 0384).
        "urn:xmpp:mds:displayed:0+notify",
        "urn:xmpp:bookmarks:1+notify",
        "urn:xmpp:avatar:metadata+notify",
        "http://jabber.org/protocol/nick+notify",
        "urn:xmpp:vcard4+notify",
        "eu.siacs.conversations.axolotl.devicelist+notify",
        "urn:xmpp:omemo:2:devices+notify",

        // Profiles (XEP-0292: a client that supports the vCard4 namespace MUST list it).
        "urn:ietf:params:xml:ns:vcard-4.0",

        // Files (XEP-0066, 0447, 0234 over 0261 and 0260, hashes per XEP-0300).
        "jabber:x:oob",
        "urn:xmpp:sfs:0",
        "urn:xmpp:jingle:apps:file-transfer:5",
        "urn:xmpp:jingle:transports:ibb:1",
        "http://jabber.org/protocol/ibb",
        "urn:xmpp:jingle:transports:s5b:1",
        "http://jabber.org/protocol/bytestreams",
        "urn:xmpp:hashes:2",
        "urn:xmpp:hash-function-text-names:sha-256",

        // Group chats and channels (XEP-0045, 0249, 0369 with PAM per XEP-0405).
        "http://jabber.org/protocol/muc",
        "jabber:x:conference",
        "urn:xmpp:mix:core:1",

        // Calls (XEP-0166, 0167, 0176, 0320, 0353, 0293, 0294, 0338, 0339).
        "urn:xmpp:jingle:1",
        "urn:xmpp:jingle:apps:rtp:1",
        "urn:xmpp:jingle:apps:rtp:audio",
        "urn:xmpp:jingle:apps:rtp:video",
        "urn:xmpp:jingle:transports:ice-udp:1",
        "urn:xmpp:jingle:apps:dtls:0",
        "urn:xmpp:jingle-message:0",
        "urn:xmpp:jingle:apps:rtp:rtcp-fb:0",
        "urn:xmpp:jingle:apps:rtp:rtp-hdrext:0",
        "urn:ietf:rfc:5888",
        "urn:ietf:rfc:5576",
    ]

    public static let discoInfo = DiscoInfo(identities: [identity], features: Set(features))
}
