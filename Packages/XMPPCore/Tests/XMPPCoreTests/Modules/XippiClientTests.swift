import Testing

@testable import XMPPCore

@Suite struct XippiClientTests {
    @Test func identity() {
        #expect(
            XippiClient.discoInfo.identities == [
                DiscoInfo.Identity(category: "client", type: "pc", name: "Xippi")
            ])
        #expect(XippiClient.node == "https://xippi.eu")
    }

    @Test func featureListHasNoDuplicates() {
        #expect(Set(XippiClient.features).count == XippiClient.features.count)
        #expect(XippiClient.discoInfo.features == Set(XippiClient.features))
    }

    @Test(arguments: [
        "http://jabber.org/protocol/disco#info", "http://jabber.org/protocol/disco#items",
        "http://jabber.org/protocol/caps", "urn:xmpp:ping", "jabber:iq:version", "urn:xmpp:time",
        "urn:xmpp:receipts", "urn:xmpp:chat-markers:0", "http://jabber.org/protocol/chatstates",
        "urn:xmpp:carbons:2", "urn:xmpp:mds:displayed:0+notify", "urn:xmpp:message-correct:0",
        "urn:xmpp:message-retract:1", "urn:xmpp:reactions:0", "urn:xmpp:reply:0",
        "urn:xmpp:fallback:0", "urn:xmpp:styling:0", "jabber:x:oob", "urn:xmpp:sfs:0",
        "urn:xmpp:bookmarks:1+notify", "urn:xmpp:avatar:metadata+notify",
        "http://jabber.org/protocol/nick+notify", "urn:xmpp:vcard4+notify",
        "urn:ietf:params:xml:ns:vcard-4.0", "http://jabber.org/protocol/muc",
        "jabber:x:conference", "urn:xmpp:mix:core:1", "urn:xmpp:jingle:1",
        "urn:xmpp:jingle:apps:rtp:1", "urn:xmpp:jingle:apps:rtp:audio",
        "urn:xmpp:jingle:apps:rtp:video", "urn:xmpp:jingle:transports:ice-udp:1",
        "urn:xmpp:jingle:apps:dtls:0", "urn:xmpp:jingle-message:0",
        "urn:xmpp:jingle:apps:file-transfer:5", "urn:xmpp:jingle:transports:ibb:1",
        "http://jabber.org/protocol/ibb", "urn:xmpp:jingle:transports:s5b:1",
        "http://jabber.org/protocol/bytestreams",
        "eu.siacs.conversations.axolotl.devicelist+notify", "urn:xmpp:omemo:2:devices+notify",
    ])
    func advertises(_ feature: String) {
        #expect(XippiClient.discoInfo.features.contains(feature))
    }

    /// Stream, server and room features are not the client's to advertise.
    @Test(arguments: [
        "urn:xmpp:csi:0", "urn:xmpp:mds:displayed:0", "urn:xmpp:sm:3", "urn:xmpp:blocking",
        "urn:xmpp:reporting:1", "urn:xmpp:sid:0", "urn:xmpp:occupant-id:0",
        "urn:xmpp:message-moderate:1",
    ])
    func doesNotAdvertise(_ feature: String) {
        #expect(!XippiClient.discoInfo.features.contains(feature))
    }

    @Test func ownCapsVerify() {
        let caps = Caps.advertisement(node: XippiClient.node, info: XippiClient.discoInfo)
        #expect(caps.hash == "sha-1")
        #expect(!caps.ver.isEmpty)
        #expect(Caps.verify(caps, query: XippiClient.discoInfo.element()))
    }
}
