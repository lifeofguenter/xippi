import Foundation
import Testing
import XMPPCore

@testable import XippiSession

@Suite("XMPPURI")
struct XMPPURITests {
    private func parse(_ string: String) -> XMPPURI? {
        URL(string: string).flatMap { XMPPURI(url: $0) }
    }

    @Test func parsesJoinURI() throws {
        let uri = try #require(parse("xmpp:room@conf.example?join"))
        #expect(uri.jid == (try JID("room@conf.example")))
        #expect(uri.action == .join)
        #expect(uri.params.isEmpty)
    }

    @Test func parsesPreAuth() throws {
        let uri = try #require(parse("xmpp:example.org?register;preauth=abc"))
        #expect(uri.jid == (try JID("example.org")))
        #expect(uri.action == .register)
        #expect(uri.params["preauth"] == "abc")
    }

    @Test func parsesInviteRosterWithIBR() throws {
        let uri = try #require(parse("xmpp:inviter@example.com?roster;preauth=TOKEN;ibr=y"))
        #expect(uri.action == .roster)
        #expect(uri.params == ["preauth": "TOKEN", "ibr": "y"])
        let register = try #require(parse("xmpp:juliet@example.com?register;preauth=TOKEN"))
        #expect(register.action == .register)
        #expect(register.params["preauth"] == "TOKEN")
    }

    @Test func rejectsJavascript() {
        #expect(parse("javascript:alert(1)") == nil)
        #expect(parse("http://example.com") == nil)
        #expect(parse("mailto:a@example.com") == nil)
    }

    @Test func schemeIsCaseInsensitive() throws {
        let uri = try #require(parse("XMPP:romeo@montague.net?message"))
        #expect(uri.action == .message)
    }

    @Test func rejectsInvalidJID() {
        #expect(parse("xmpp:") == nil)
        #expect(parse("xmpp:@example.com") == nil)
        #expect(parse("xmpp:a@") == nil)
        #expect(parse("xmpp:a@b@c") == nil)
        #expect(parse("xmpp:/etc/passwd") == nil)
    }

    @Test func percentEncodedLocalparts() throws {
        // RFC 5122 section 2.4 example: IRI form of an address with a non-ASCII domain.
        let uri = try #require(parse("xmpp:ji%C5%99i@%C4%8Dechy.example/v%20Praze"))
        #expect(uri.jid.localpart == "jiři")
        #expect(uri.jid.domainpart == "čechy.example")
        #expect(uri.jid.resourcepart == "v Praze")
    }

    @Test func encodedAtSignInLocalpartIsRejected() {
        #expect(parse("xmpp:a%40b@example.org") == nil)
        #expect(parse("xmpp:evil%2Fx@good.example") == nil)
        #expect(parse("xmpp:romeo%40montague.net") == nil)
    }

    @Test func encodedSlashStaysInResource() throws {
        let uri = try #require(parse("xmpp:user@example.org/res%2Fpart"))
        #expect(uri.jid.localpart == "user")
        #expect(uri.jid.domainpart == "example.org")
        #expect(uri.jid.resourcepart == "res/part")
    }

    @Test func messageWithKeys() throws {
        let uri = try #require(
            parse(
                "xmpp:romeo@montague.net?message;subject=Test%20Message;body=Here%27s%20a%20test%20message"
            ))
        #expect(uri.action == .message)
        #expect(uri.params["subject"] == "Test Message")
        #expect(uri.params["body"] == "Here's a test message")
    }

    @Test func rosterWithNameAndGroup() throws {
        let uri = try #require(
            parse("xmpp:romeo@montague.net?roster;name=Romeo%20Montague;group=Friends"))
        #expect(uri.action == .roster)
        #expect(uri.params == ["name": "Romeo Montague", "group": "Friends"])
    }

    @Test func plainActions() throws {
        #expect(try #require(parse("xmpp:romeo@montague.net?subscribe")).action == .subscribe)
        #expect(try #require(parse("xmpp:romeo@montague.net?unsubscribe")).action == .unsubscribe)
        #expect(try #require(parse("xmpp:romeo@montague.net?remove")).action == .remove)
        #expect(try #require(parse("xmpp:room@conf.example?invite;jid=a@b.c")).action == .invite)
    }

    @Test func noQueryHasNoAction() throws {
        let uri = try #require(parse("xmpp:example-node@example.com/some-resource"))
        #expect(uri.action == nil)
        #expect(uri.jid.resourcepart == "some-resource")
    }

    @Test func unknownActionIsDropped() throws {
        let uri = try #require(parse("xmpp:romeo@montague.net?frobnicate;x=1"))
        #expect(uri.action == nil)
        #expect(uri.params == ["x": "1"])
    }

    @Test func encodedSeparatorStaysInValue() throws {
        let uri = try #require(parse("xmpp:a@b.c?message;body=one%3Btwo%26three"))
        #expect(uri.params["body"] == "one;two&three")
    }

    @Test func authorityComponent() throws {
        let uri = try #require(parse("xmpp://guest@example.com/support@example.com?message"))
        #expect(uri.authority == (try JID("guest@example.com")))
        #expect(uri.jid == (try JID("support@example.com")))
        #expect(uri.action == .message)
        #expect(parse("xmpp://guest@example.com") == nil)
    }

    @Test func fragmentIsIgnored() throws {
        let uri = try #require(parse("xmpp:a@b.c?join#frag"))
        #expect(uri.action == .join)
    }
}
