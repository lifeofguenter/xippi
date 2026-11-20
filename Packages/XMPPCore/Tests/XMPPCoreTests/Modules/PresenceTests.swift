import Foundation
import Testing

@testable import XMPPCore

@Suite struct PresenceTests {
    static func presence(_ file: String, _ name: String, index: Int = 0) throws -> Presence {
        let stanza = try ModuleFixtures.stanzas(file, name)[index]
        let presence = try #require(Presence(element: stanza))
        #expect(Presence(element: presence.element) == presence, "\(file) \(name) round trip")
        return presence
    }

    @Test func showStatusAndID() throws {
        let presence = try Self.presence("rfc6121", "presence-dnd")
        #expect(presence.type == .available)
        #expect(presence.show == .dnd)
        #expect(presence.status == "busy!")
        #expect(presence.priority == 0)
        #expect(presence.id == "pres1")
        #expect(presence.from == (try JID("juliet@example.com/chamber")))
    }

    @Test func types() throws {
        #expect(try Self.presence("rfc6121", "presence-probe").type == .probe)
        #expect(try Self.presence("rfc6121", "presence-unsubscribed").type == .unsubscribed)
        #expect(try Self.presence("xep-0045-1.35.6", "kicked").type == .unavailable)
    }

    @Test func priorityAndDelay() throws {
        let presence = try Self.presence("xep-0203-2.0", "last-presence")
        #expect(presence.show == .xa)
        #expect(presence.status == "anon!")
        #expect(presence.priority == 1)
        let juliet = try JID("juliet@capulet.com/balcony")
        let stamp = try xmppDate("2002-09-10T23:41:07Z")
        #expect(presence.delays == [Delay.Stamp(stamp: stamp, from: juliet)])
        #expect(presence.delay(trusting: [juliet]) == stamp)
        #expect(presence.delay(trusting: []) == nil)
    }

    /// RFC 6120 8.3.1: a bounced presence carries our own show, status and caps back; none of
    /// it is the peer's.
    @Test func bouncedPresenceCarriesNoStatus() throws {
        let sent = Presence(
            show: .dnd, status: "busy", priority: 5,
            caps: Caps.advertisement(node: XippiClient.node, info: XippiClient.discoInfo),
            avatarHash: .noAvatar, idleSince: try xmppDate("2026-11-19T08:00:00Z"), nick: "Me",
            to: try JID("room@muc.example.com/me"), id: "p1"
        ).element
        let bounce = sent.errorResponse(StanzaError(type: .cancel, condition: .notAllowed))
        let presence = try #require(Presence(element: bounce))
        #expect(presence.type == .error)
        #expect(presence.error == StanzaError(type: .cancel, condition: .notAllowed))
        #expect(presence.from == (try JID("room@muc.example.com/me")))
        #expect(presence.id == "p1")
        #expect(presence.show == nil)
        #expect(presence.status == nil)
        #expect(presence.priority == 0)
        #expect(presence.caps == nil)
        #expect(presence.avatarHash == nil)
        #expect(presence.idleSince == nil)
        #expect(presence.nick == nil)
        #expect(presence.muc == nil)
    }

    @Test func idleSince() throws {
        let presence = try Self.presence("xep-0319-1.0.2", "idle")
        #expect(presence.show == .away)
        #expect(presence.idleSince == (try xmppDate("1969-07-21T02:56:15Z")))
        #expect(try Self.presence("xep-0319-1.0.2", "back").idleSince == nil)
    }

    @Test func avatarHash() throws {
        let file = "xep-0153-1.1.1"
        #expect(
            try Self.presence(file, "photo-hash").avatarHash
                == .hash("01b87fcd030b72895ff8e88db57ec525450f000d"))
        #expect(try Self.presence(file, "not-ready").avatarHash == .notReady)
        #expect(try Self.presence(file, "no-image").avatarHash == .noAvatar)
        #expect(try Self.presence("rfc6121", "presence-dnd").avatarHash == nil)
    }

    @Test func avatarHashIsLowercasedAndChecked() throws {
        func presence(photo: String) -> Element {
            Element.presence(children: [
                Element(
                    "x", namespace: "vcard-temp:x:update",
                    children: [
                        .element(
                            Element(
                                "photo", namespace: "vcard-temp:x:update", children: [.text(photo)])
                        )
                    ])
            ])
        }
        #expect(
            Presence(element: presence(photo: "01B87FCD030B72895FF8E88DB57EC525450F000D"))?
                .avatarHash
                == .hash("01b87fcd030b72895ff8e88db57ec525450f000d"))
        #expect(Presence(element: presence(photo: "not-a-hash"))?.avatarHash == nil)
        // Full-width digits are hex digits to Character, not to XEP-0153.
        let fullWidth = String(repeating: "0", count: 37) + "\u{FF11}"
        #expect(fullWidth.utf8.count == 40)
        #expect(Presence(element: presence(photo: fullWidth))?.avatarHash == nil)
    }

    @Test func caps() throws {
        let presence = try Self.presence("xep-0115-1.6.0", "presence-caps")
        #expect(
            presence.caps
                == Caps.Advertisement(
                    node: "http://code.google.com/p/exodus", ver: "QgayPKawpkPSDYmwT/WM94uAlu0="))
    }

    @Test func nickInASubscriptionRequest() throws {
        let presence = try Self.presence("xep-0172-1.1", "subscribe-with-nick")
        #expect(presence.type == .subscribe)
        #expect(presence.nick == "Ishmael")
    }

    @Test func mucJoinWithCodes110And210() throws {
        let presence = try Self.presence("xep-0045-1.35.6", "self-presence")
        let muc = try #require(presence.muc)
        #expect(muc.statusCodes == [100, 110, 210])
        #expect(muc.isSelf)
        #expect(muc.affiliation == .member)
        #expect(muc.role == .participant)
    }

    @Test func mucOccupantID() throws {
        let presence = try Self.presence("xep-0421-1.0.1", "occupant-presence")
        #expect(presence.muc?.occupantID == "dd72603deec90a38ba552f7c68cbcc61bca202cd")
        #expect(presence.muc?.statusCodes == [])
    }

    @Test func mucNickChange() throws {
        let presence = try Self.presence("xep-0045-1.35.6", "nick-change", index: 2)
        #expect(presence.type == .unavailable)
        let muc = try #require(presence.muc)
        #expect(muc.statusCodes == [303, 110])
        #expect(muc.nickChange == "oldhag")
        #expect(muc.realJID == (try JID("hag66@shakespeare.lit/pda")))
        // Without 303 the item's nick is not a nick change.
        let other = try Self.presence("xep-0045-1.35.6", "nick-change", index: 3)
        #expect(other.muc?.nickChange == nil)
    }

    @Test func mucKick() throws {
        let muc = try #require(try Self.presence("xep-0045-1.35.6", "kicked").muc)
        #expect(muc.statusCodes == [110, 307])
        #expect(muc.role == MUCPresence.Role.none)
        #expect(muc.affiliation == MUCPresence.Affiliation.none)
        #expect(muc.reason == "Avaunt, you cullion!")
    }

    @Test func mucDestroy() throws {
        let muc = try #require(try Self.presence("xep-0045-1.35.6", "destroyed").muc)
        #expect(
            muc.destroy
                == MUCPresence.Destroy(
                    alternate: try JID("coven@chat.shakespeare.lit"), reason: "Macbeth doth come."))
    }

    @Test func mucStatusCodesOutsideTheRangeAreIgnored() throws {
        let x = Element(
            "x", namespace: MUCPresence.userNamespace,
            children: ["110", "99", "1000", "abc", "-110"].map {
                .element(
                    Element(
                        "status", namespace: MUCPresence.userNamespace, attributes: ["code": $0]))
            })
        #expect(MUCPresence(presence: Element.presence(children: [x]))?.statusCodes == [110])
        #expect(MUCPresence(presence: Element.presence()) == nil)
    }

    @Test func invalidValuesAreTolerated() throws {
        var stanza = Element.presence(children: [
            Element("show", children: [.text("bogus")]),
            Element("priority", children: [.text("300")]),
        ])
        let presence = try #require(Presence(element: stanza))
        #expect(presence.show == nil)
        #expect(presence.priority == 0)
        stanza[attribute: "type"] = "bogus"
        #expect(Presence(element: stanza) == nil)
        stanza[attribute: "type"] = nil
        stanza[attribute: "from"] = "@"
        #expect(Presence(element: stanza) == nil)
        #expect(Presence(element: Element("message")) == nil)
    }

    @Test func negativePriority() throws {
        let stanza = Element.presence(children: [Element("priority", children: [.text("-128")])])
        #expect(Presence(element: stanza)?.priority == -128)
    }

    @Test func ownPresenceElement() throws {
        let caps = Caps.advertisement(node: XippiClient.node, info: XippiClient.discoInfo)
        let presence = Presence(
            show: .away, status: "Lunch", priority: 5, caps: caps, avatarHash: .noAvatar,
            idleSince: try xmppDate("2026-11-19T08:00:00Z"))
        let element = presence.element
        #expect(element.name == "presence")
        #expect(element.type == nil)
        #expect(element.child("show")?.text == "away")
        #expect(element.child("c", namespace: Caps.namespace)?[attribute: "ver"] == caps.ver)
        #expect(
            element.child("idle", namespace: "urn:xmpp:idle:1")?[attribute: "since"]
                == "2026-11-19T08:00:00Z")
        #expect(Presence(element: element) == presence)
    }

    @Test func subscriptionBuilders() throws {
        let contact = try JID("starbuck@moby-dick.lit/ship")
        let subscribe = Presence.subscribe(to: contact, nick: "Ishmael")
        #expect(subscribe.type == "subscribe")
        #expect(subscribe[attribute: "to"] == "starbuck@moby-dick.lit")
        #expect(
            subscribe.child("nick", namespace: "http://jabber.org/protocol/nick")?.text == "Ishmael"
        )
        #expect(Presence.subscribe(to: contact).child("nick") == nil)
        #expect(Presence.unsubscribe(to: contact).type == "unsubscribe")
        #expect(Presence.subscribed(to: contact).type == "subscribed")
        #expect(Presence.unsubscribed(to: contact).type == "unsubscribed")
        #expect(Presence.unsubscribed(to: contact)[attribute: "to"] == "starbuck@moby-dick.lit")
    }
}
