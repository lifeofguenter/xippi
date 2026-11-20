import Testing

@testable import XippiSession

@Suite("RegistrationInvite")
struct RegistrationInviteTests {
    @Test func registerURIWithToken() throws {
        let invite = try #require(RegistrationInvite(link: "xmpp:example.org?register;preauth=abc"))
        #expect(invite == RegistrationInvite(server: "example.org", token: "abc", username: nil))
    }

    @Test func registerURIReservesTheUsername() throws {
        let invite = try #require(
            RegistrationInvite(link: "  xmpp:juliet@example.org?register;preauth=t1\n"))
        #expect(
            invite == RegistrationInvite(server: "example.org", token: "t1", username: "juliet"))
    }

    @Test func rosterInviteWithRegistration() throws {
        let invite = try #require(
            RegistrationInvite(link: "xmpp:romeo@example.com?roster;preauth=TOKEN;ibr=y"))
        // The JID is the inviter's: the new account gets no user name from it.
        #expect(invite == RegistrationInvite(server: "example.com", token: "TOKEN", username: nil))
    }

    @Test func rosterInviteWithoutRegistrationIsNoRegistrationInvite() {
        #expect(RegistrationInvite(link: "xmpp:romeo@example.com?roster;preauth=TOKEN") == nil)
    }

    @Test func registerWithoutToken() throws {
        let invite = try #require(RegistrationInvite(link: "xmpp:example.org?register"))
        #expect(invite == RegistrationInvite(server: "example.org", token: nil, username: nil))
    }

    @Test func landingPageWithTheURIInItsFragment() throws {
        let invite = try #require(
            RegistrationInvite(
                link: "https://xmpp.link/#romeo@example.com?roster;preauth=T2;ibr=y"))
        #expect(invite == RegistrationInvite(server: "example.com", token: "T2", username: nil))
        let prefixed = try #require(
            RegistrationInvite(link: "https://invite.example/#xmpp:example.org?register;preauth=T3")
        )
        #expect(prefixed.token == "T3")
    }

    @Test func otherLinksAreNoInvites() {
        #expect(RegistrationInvite(link: "") == nil)
        #expect(RegistrationInvite(link: "https://example.org/") == nil)
        #expect(RegistrationInvite(link: "javascript:alert(1)") == nil)
        #expect(RegistrationInvite(link: "xmpp:room@conference.example.org?join") == nil)
        #expect(RegistrationInvite(link: "xmpp:alice@example.org") == nil)
    }

    @Test func emptyTokenCountsAsNone() throws {
        let invite = try #require(RegistrationInvite(link: "xmpp:example.org?register;preauth="))
        #expect(invite.token == nil)
    }
}

@Suite("RegistrationRequest")
struct RegistrationRequestTests {
    private static let preset = RegistrationInvite(
        server: "example.org", token: "T1", username: "juliet")

    @Test func presetInviteGivesTokenAndUserName() throws {
        let request = try RegistrationRequest(domain: "", inviteText: "", preset: Self.preset)
        #expect(
            request == RegistrationRequest(domain: "example.org", token: "T1", username: "juliet"))
    }

    @Test func presetInviteWithTheDomainTyped() throws {
        let request = try RegistrationRequest(
            domain: "example.org", inviteText: " ", preset: Self.preset)
        #expect(request.token == "T1")
        #expect(request.username == "juliet")
    }

    @Test func typedLinkWinsOverThePreset() throws {
        let request = try RegistrationRequest(
            domain: "", inviteText: "xmpp:example.net?register;preauth=T2", preset: Self.preset)
        #expect(request == RegistrationRequest(domain: "example.net", token: "T2", username: nil))
    }

    @Test func domainsCompareNormalised() throws {
        let request = try RegistrationRequest(
            domain: " Example.ORG ", inviteText: "xmpp:example.org?register;preauth=T3",
            preset: nil)
        #expect(request.domain == "example.org")
        #expect(request.token == "T3")
    }

    @Test func inviteForAnotherDomainIsRefused() {
        #expect(throws: RegistrationRequest.Problem.inviteForOtherDomain("example.org")) {
            try RegistrationRequest(domain: "example.net", inviteText: "", preset: Self.preset)
        }
    }

    @Test func badInputIsRefused() {
        #expect(throws: RegistrationRequest.Problem.invalidInvite) {
            try RegistrationRequest(domain: "example.org", inviteText: "nonsense", preset: nil)
        }
        #expect(throws: RegistrationRequest.Problem.invalidDomain) {
            try RegistrationRequest(domain: "", inviteText: "", preset: nil)
        }
        #expect(throws: RegistrationRequest.Problem.invalidDomain) {
            try RegistrationRequest(domain: "a b", inviteText: "", preset: nil)
        }
    }

    @Test func noInviteNoToken() throws {
        let request = try RegistrationRequest(domain: "example.org", inviteText: "", preset: nil)
        #expect(request == RegistrationRequest(domain: "example.org", token: nil, username: nil))
    }
}
