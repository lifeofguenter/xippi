import Foundation
import XMPPCore
import XippiStore

/// What an `xmpp:` link opened from outside the app asks for (RFC 5122, XEP-0147, XEP-0401).
/// Any page can open such a link, so nothing here acts by itself: a chat opens with the text
/// filled in but not sent, and joining a room, adding a contact or registering opens its sheet
/// for the user to confirm.
///
/// `roster`, `remove`, `unsubscribe` and `invite` are not taken from a link. A XEP-0401 roster
/// invite that allows registration (`ibr=y`) opens the register sheet when there is no
/// account yet.
public enum XMPPURIIntent: Sendable, Equatable {
    /// The chat with the bare JID, its composer filled with `body`.
    case openChat(JID, body: String?)
    /// The join sheet for the room, filled in.
    case joinRoom(JID, nick: String?, password: String?)
    /// The add-contact sheet, filled in.
    case addContact(JID, name: String?)
    /// The register sheet with the invite.
    case register(RegistrationInvite)

    /// The longest text a link may fill in, in UTF-8 bytes (a character can carry any number
    /// of combining marks); a longer one fills in nothing.
    public static let maxBodyBytes = 40_000
    /// The longest name, nick, password or invitation token taken from a link, in UTF-8 bytes.
    public static let maxFieldBytes = 4_000

    public init?(url: URL, hasAccounts: Bool) {
        guard let uri = XMPPURI(url: url) else { return nil }
        self.init(uri, hasAccounts: hasAccounts)
    }

    public init?(_ uri: XMPPURI, hasAccounts: Bool) {
        // The address shows in every sheet: one that hides characters is no address.
        guard LinkText.isClean(uri.jid.description) else { return nil }
        let bare = uri.jid.bare
        switch uri.action {
        case nil, .message:
            guard bare.localpart != nil else { return nil }
            self = .openChat(bare, body: Self.body(uri.params["body"]))
        case .join:
            guard bare.localpart != nil else { return nil }
            self = .joinRoom(
                bare, nick: Self.field(uri.jid.resourcepart),
                password: Self.field(uri.params["password"]))
        case .subscribe:
            self = .addContact(bare, name: Self.field(uri.params["name"]))
        case .register:
            guard let invite = RegistrationInvite(uri: uri) else { return nil }
            self = .register(invite)
        case .roster:
            guard !hasAccounts, let invite = RegistrationInvite(uri: uri) else { return nil }
            self = .register(invite)
        case .remove, .unsubscribe, .invite:
            return nil
        }
    }

    /// The address the account acts on; nil for registering, which needs no account.
    public var target: JID? {
        switch self {
        case .openChat(let jid, _), .joinRoom(let jid, _, _), .addContact(let jid, _): jid
        case .register: nil
        }
    }

    /// A one-line value: trimmed, at most `maxFieldBytes`, and nil when it holds a
    /// control character, a bidi control or a line or paragraph separator.
    static func field(_ value: String?) -> String? {
        guard let value, LinkText.isClean(value) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxFieldBytes else { return nil }
        return trimmed
    }

    /// The text to fill in: line ends as line feeds; nil when empty, over `maxBodyBytes`, or
    /// holding a control character other than a line feed or a tab, a bidi control, or a line
    /// or paragraph separator.
    static func body(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.isEmpty, text.utf8.count <= maxBodyBytes,
            LinkText.isClean(text, allowing: ["\n", "\t"])
        else { return nil }
        return text
    }
}

/// Text from a link that any page can open: no control characters (Unicode `Cc`) except the
/// ones allowed, no line or paragraph separators (U+2028, U+2029), and no bidi controls,
/// which reorder what is shown (U+061C, U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069).
enum LinkText {
    static func isClean(_ text: String, allowing allowed: Set<Unicode.Scalar> = []) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if allowed.contains(scalar) { return true }
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: return !bidiControls.contains(scalar.value)
            }
        }
    }

    private static let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068,
        0x2069,
    ]
}

/// Which account an `xmpp:` link acts as. Only enabled accounts are offered. With several,
/// the user is asked, starting from the account that already has a chat with the address
/// (the most recent), else the one used last, else the first.
public enum URIAccountChoice: Sendable, Equatable {
    /// One account fits: no question.
    case use(Int64)
    /// Ask, offering these accounts with one chosen.
    case ask([Int64], preselected: Int64)
    /// No enabled account: nothing to do.
    case none
    /// Registering needs no account.
    case notNeeded

    public init(
        for intent: XMPPURIIntent, accounts: [AccountRecord], chats: [ChatRecord],
        lastUsed: Int64?
    ) {
        guard let target = intent.target?.description else {
            self = .notNeeded
            return
        }
        let candidates = accounts.filter(\.enabled).compactMap(\.id)
        guard let first = candidates.first else {
            self = .none
            return
        }
        guard candidates.count > 1 else {
            self = .use(first)
            return
        }
        let withChat =
            chats
            .filter { $0.jid == target && candidates.contains($0.accountID) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .map(\.accountID)
        // Opening a chat only one account has asks nothing; the sheets are confirmations and
        // always show.
        if case .openChat = intent, Set(withChat).count == 1, let only = withChat.first {
            self = .use(only)
            return
        }
        let preferred =
            withChat.first ?? lastUsed.flatMap { candidates.contains($0) ? $0 : nil } ?? first
        self = .ask(candidates, preselected: preferred)
    }
}
