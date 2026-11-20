import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

@Suite("XMPPURIIntent")
struct XMPPURIIntentTests {
    private func intent(_ link: String, hasAccounts: Bool = true) -> XMPPURIIntent? {
        URL(string: link).flatMap { XMPPURIIntent(url: $0, hasAccounts: hasAccounts) }
    }

    @Test func messageOpensTheChatWithTheBody() throws {
        #expect(
            intent("xmpp:romeo@montague.net?message;body=Here%27s%20a%20test")
                == .openChat(try JID("romeo@montague.net"), body: "Here's a test"))
    }

    @Test func plainAddressOpensTheChat() throws {
        #expect(
            intent("xmpp:romeo@montague.net") == .openChat(try JID("romeo@montague.net"), body: nil)
        )
        // A resource names a device: the chat is with the person.
        #expect(
            intent("xmpp:romeo@montague.net/orchard?message")
                == .openChat(try JID("romeo@montague.net"), body: nil))
    }

    @Test func serverAloneIsNoChat() {
        #expect(intent("xmpp:montague.net") == nil)
        #expect(intent("xmpp:montague.net?message") == nil)
    }

    @Test func overlongBodyIsDropped() throws {
        let long = String(repeating: "a", count: XMPPURIIntent.maxBodyBytes + 1)
        #expect(
            intent("xmpp:romeo@montague.net?message;body=\(long)")
                == .openChat(try JID("romeo@montague.net"), body: nil))
    }

    /// The link only fills in the join sheet: the nick from the resource, the password.
    @Test func joinFillsInTheSheet() throws {
        #expect(
            intent("xmpp:room@conference.example?join")
                == .joinRoom(try JID("room@conference.example"), nick: nil, password: nil))
        #expect(
            intent("xmpp:room@conference.example/Juliet?join;password=cauldron")
                == .joinRoom(
                    try JID("room@conference.example"), nick: "Juliet", password: "cauldron"))
        #expect(intent("xmpp:conference.example?join") == nil)
    }

    @Test func subscribeFillsInAddContact() throws {
        #expect(
            intent("xmpp:romeo@montague.net?subscribe")
                == .addContact(try JID("romeo@montague.net"), name: nil))
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=Romeo%20M")
                == .addContact(try JID("romeo@montague.net"), name: "Romeo M"))
    }

    @Test func registerOpensTheRegisterSheetWithTheToken() {
        #expect(
            intent("xmpp:example.org?register;preauth=abc")
                == .register(RegistrationInvite(server: "example.org", token: "abc", username: nil))
        )
        #expect(
            intent("xmpp:juliet@example.org?register;preauth=t1")
                == .register(
                    RegistrationInvite(server: "example.org", token: "t1", username: "juliet")))
    }

    @Test func rosterInviteRegistersOnlyWithoutAccounts() {
        let link = "xmpp:romeo@example.com?roster;preauth=TOKEN;ibr=y"
        #expect(
            intent(link, hasAccounts: false)
                == .register(
                    RegistrationInvite(server: "example.com", token: "TOKEN", username: nil)))
        #expect(intent(link, hasAccounts: true) == nil)
    }

    // MARK: Control and direction characters

    /// Any page can open a link: a field with a control character or a bidi control is
    /// dropped, never stored or shown.
    @Test func fieldsWithControlCharactersAreDropped() throws {
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=Romeo%0AAdmin")
                == .addContact(try JID("romeo@montague.net"), name: nil))
        #expect(
            intent("xmpp:room@conference.example?join;password=caul%00dron")
                == .joinRoom(try JID("room@conference.example"), nick: nil, password: nil))
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=%E2%80%AEoemoR")
                == .addContact(try JID("romeo@montague.net"), name: nil))
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=Ro%E2%81%A6meo")
                == .addContact(try JID("romeo@montague.net"), name: nil))
    }

    @Test func nickWithABidiControlIsDropped() {
        let link = intent("xmpp:room@conference.example/%E2%80%AEJuliet?join")
        switch link {
        case nil: break  // the address itself is refused
        case .joinRoom(_, let nick, _)?: #expect(nick == nil)
        default: Issue.record("not a join: \(String(describing: link))")
        }
    }

    /// A body keeps its line breaks and tabs; any other control character or a bidi control
    /// drops it.
    @Test func bodyKeepsLinesButNotControls() throws {
        let bob = try JID("romeo@montague.net")
        #expect(
            intent("xmpp:romeo@montague.net?message;body=one%0Atwo%09three")
                == .openChat(bob, body: "one\ntwo\tthree"))
        #expect(intent("xmpp:romeo@montague.net?message;body=ring%07") == .openChat(bob, body: nil))
        #expect(
            intent("xmpp:romeo@montague.net?message;body=%1B%5B2J") == .openChat(bob, body: nil))
        #expect(
            intent("xmpp:romeo@montague.net?message;body=pay%E2%80%AEmoc.exe")
                == .openChat(bob, body: nil))
    }

    /// The address itself: a bidi control anywhere in it refuses the whole link (R59).
    @Test func addressWithABidiControlIsRefused() {
        #expect(intent("xmpp:%E2%80%AEromeo@montague.net?subscribe") == nil)
        #expect(intent("xmpp:romeo@ex%E2%80%AEample.com") == nil)
        #expect(intent("xmpp:%E2%80%AEx@example.org?register") == nil)
        #expect(intent("xmpp:example.org?register;preauth=abc", hasAccounts: false) != nil)
    }

    /// Line and paragraph separators break a one-line value as a line feed does.
    @Test func lineAndParagraphSeparatorsAreDropped() throws {
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=Romeo%E2%80%A8Admin")
                == .addContact(try JID("romeo@montague.net"), name: nil))
        #expect(
            intent("xmpp:room@conference.example?join;password=a%E2%80%A9b")
                == .joinRoom(try JID("room@conference.example"), nick: nil, password: nil))
        #expect(
            intent("xmpp:romeo@montague.net?message;body=one%E2%80%A8two")
                == .openChat(try JID("romeo@montague.net"), body: nil))
    }

    /// Windows and old Mac line ends become line feeds.
    @Test func bodyLineEndsBecomeLineFeeds() throws {
        let bob = try JID("romeo@montague.net")
        #expect(
            intent("xmpp:romeo@montague.net?message;body=one%0D%0Atwo%0Dthree")
                == .openChat(bob, body: "one\ntwo\nthree"))
    }

    /// Lengths count bytes: one character can carry any number of combining marks.
    @Test func lengthsCountBytesNotCharacters() throws {
        let marks = String(repeating: "%CC%81", count: XMPPURIIntent.maxBodyBytes / 2 + 1)
        #expect(
            intent("xmpp:romeo@montague.net?message;body=a\(marks)")
                == .openChat(try JID("romeo@montague.net"), body: nil))
        let nameMarks = String(repeating: "%CC%81", count: XMPPURIIntent.maxFieldBytes / 2 + 1)
        #expect(
            intent("xmpp:romeo@montague.net?subscribe;name=R\(nameMarks)")
                == .addContact(try JID("romeo@montague.net"), name: nil))
    }

    @Test func invitationTokenWithControlCharactersIsDropped() {
        #expect(
            intent("xmpp:example.org?register;preauth=%01abc")
                == .register(RegistrationInvite(server: "example.org", token: nil, username: nil)))
        let long = String(repeating: "t", count: XMPPURIIntent.maxFieldBytes + 1)
        #expect(
            intent("xmpp:example.org?register;preauth=\(long)")
                == .register(RegistrationInvite(server: "example.org", token: nil, username: nil)))
    }

    @Test func actionsALinkMustNotTakeAreIgnored() {
        #expect(intent("xmpp:romeo@montague.net?roster;name=Romeo") == nil)
        #expect(intent("xmpp:romeo@montague.net?remove") == nil)
        #expect(intent("xmpp:romeo@montague.net?unsubscribe") == nil)
        #expect(intent("xmpp:room@conference.example?invite;jid=romeo@montague.net") == nil)
    }

    @Test func otherSchemesAreIgnored() {
        #expect(intent("javascript:alert(1)") == nil)
        #expect(intent("https://example.com/#xmpp:romeo@montague.net") == nil)
    }

    // MARK: Which account

    private func account(_ id: Int64, enabled: Bool = true) -> AccountRecord {
        AccountRecord(
            id: id, jid: "user\(id)@example.org", enabled: enabled, resource: "",
            clientID: "c\(id)",
            hostOverride: nil, portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
            rosterVersion: nil, smResume: nil, createdAt: Date())
    }

    private func chat(account: Int64, jid: String, active: TimeInterval) -> ChatRecord {
        ChatRecord(
            id: account * 100, accountID: account, jid: jid, kind: .direct, name: nil,
            pinned: false, muted: false, notify: .all, draft: nil, encryption: .none, nick: nil,
            password: nil, autojoin: false, lastActivity: Date(timeIntervalSince1970: active),
            unreadCount: 0, mentionCount: 0, lastReadMessageID: nil, avatarHash: nil)
    }

    private func choice(
        _ link: String, accounts: [AccountRecord], chats: [ChatRecord] = [], lastUsed: Int64? = nil
    ) throws -> URIAccountChoice {
        let intent = try #require(intent(link))
        return URIAccountChoice(
            for: intent, accounts: accounts, chats: chats, lastUsed: lastUsed)
    }

    @Test func oneAccountIsUsedWithoutAsking() throws {
        #expect(
            try choice(
                "xmpp:romeo@montague.net", accounts: [account(1), account(2, enabled: false)])
                == .use(1))
    }

    @Test func noEnabledAccountMeansNoAction() throws {
        #expect(
            try choice("xmpp:room@conference.example?join", accounts: [account(1, enabled: false)])
                == .none)
    }

    @Test func severalAccountsAskWithTheLastUsedFirst() throws {
        #expect(
            try choice(
                "xmpp:room@conference.example?join", accounts: [account(1), account(2)],
                lastUsed: 2) == .ask([1, 2], preselected: 2))
        // A last used account that is gone or disabled is not offered.
        #expect(
            try choice(
                "xmpp:room@conference.example?join",
                accounts: [account(1), account(2), account(3, enabled: false)], lastUsed: 3)
                == .ask([1, 2], preselected: 1))
    }

    @Test func accountThatHasTheChatIsPreselected() throws {
        let chats = [
            chat(account: 1, jid: "romeo@montague.net", active: 10),
            chat(account: 2, jid: "romeo@montague.net", active: 20),
        ]
        #expect(
            try choice(
                "xmpp:romeo@montague.net?subscribe", accounts: [account(1), account(2)],
                chats: chats, lastUsed: 1) == .ask([1, 2], preselected: 2))
    }

    /// Opening a chat only one account has needs no question.
    @Test func existingChatOfOneAccountOpensDirectly() throws {
        let chats = [chat(account: 2, jid: "romeo@montague.net", active: 20)]
        #expect(
            try choice(
                "xmpp:romeo@montague.net", accounts: [account(1), account(2)], chats: chats,
                lastUsed: 1) == .use(2))
        // Joining still asks: the sheet is the confirmation.
        #expect(
            try choice(
                "xmpp:romeo@montague.net?subscribe", accounts: [account(1), account(2)],
                chats: chats, lastUsed: 1) == .ask([1, 2], preselected: 2))
    }

    @Test func registeringNeedsNoAccount() throws {
        #expect(try choice("xmpp:example.org?register", accounts: []) == .notNeeded)
    }
}
