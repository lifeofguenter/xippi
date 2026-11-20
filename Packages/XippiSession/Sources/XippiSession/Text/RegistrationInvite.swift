import Foundation
import XMPPCore

/// A XEP-0401 invite to register an account: the server and the XEP-0445 token, from an
/// `xmpp:` URI or a landing page link that carries one in its fragment (as xmpp.link does).
public struct RegistrationInvite: Sendable, Equatable {
    /// The domain to register at.
    public var server: String
    /// The invite token; nil when the URI names none.
    public var token: String?
    /// The user name the invite reserves (`xmpp:juliet@example.com?register;preauth=...`).
    public var username: String?

    public init(server: String, token: String?, username: String?) {
        self.server = server
        self.token = token
        self.username = username
    }

    /// nil for anything but a `register` URI, or a `roster` URI that allows registration
    /// (`ibr=y`).
    public init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uri = Self.uri(in: trimmed) else { return nil }
        self.init(uri: uri)
    }

    /// The same for a parsed `xmpp:` URI.
    public init?(uri: XMPPURI) {
        // The server and the user name come from the address: one that hides characters is
        // no invite.
        guard LinkText.isClean(uri.jid.description) else { return nil }
        // A token with a control character or over the length is not sent: dropping the
        // character would change it.
        let token = uri.params["preauth"].flatMap {
            $0.isEmpty || $0.utf8.count > XMPPURIIntent.maxFieldBytes || !LinkText.isClean($0)
                ? nil : $0
        }
        switch uri.action {
        case .register:
            self.init(server: uri.jid.domainpart, token: token, username: uri.jid.localpart)
        case .roster where uri.params["ibr"] == "y":
            // The JID is the inviter's; the new account is on the same server.
            self.init(server: uri.jid.domainpart, token: token, username: nil)
        default:
            return nil
        }
    }

    private static func uri(in text: String) -> XMPPURI? {
        if text.lowercased().hasPrefix("xmpp:") {
            return URL(string: text).flatMap(XMPPURI.init(url:))
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let fragment = url.fragment(percentEncoded: true), !fragment.isEmpty
        else { return nil }
        let candidate = fragment.lowercased().hasPrefix("xmpp:") ? fragment : "xmpp:" + fragment
        return URL(string: candidate).flatMap(XMPPURI.init(url:))
    }
}

/// Where to register and with which invite: the domain typed in, and the invite from the link
/// typed in, or else the one the sheet was opened with (an `xmpp:` URI).
public struct RegistrationRequest: Sendable, Equatable {
    public enum Problem: Error, Equatable {
        case invalidInvite
        case invalidDomain
        /// The invite is for this other domain.
        case inviteForOtherDomain(String)
    }

    /// The domain, normalised.
    public var domain: String
    /// The invite token to send first (XEP-0445).
    public var token: String?
    /// The user name the invite reserves, to fill in.
    public var username: String?

    public init(domain: String, token: String?, username: String?) {
        self.domain = domain
        self.token = token
        self.username = username
    }

    /// An empty `domain` takes the invite's. A typed link that is no invite, a domain that is
    /// not one, or an invite for another domain than the one typed is refused.
    public init(domain: String, inviteText: String, preset: RegistrationInvite?)
        throws(Problem)
    {
        var invite = preset
        let link = inviteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty {
            guard let typed = RegistrationInvite(link: link) else { throw .invalidInvite }
            invite = typed
        }
        let typedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = Self.normalised(typedDomain.isEmpty ? invite?.server ?? "" : typedDomain)
        else { throw .invalidDomain }
        if let invite, Self.normalised(invite.server) != name {
            throw .inviteForOtherDomain(invite.server)
        }
        self.init(domain: name, token: invite?.token, username: invite?.username)
    }

    private static func normalised(_ domain: String) -> String? {
        guard !domain.isEmpty,
            let jid = try? JID(localpart: nil, domainpart: domain, resourcepart: nil)
        else { return nil }
        return jid.domainpart.lowercased()
    }
}
