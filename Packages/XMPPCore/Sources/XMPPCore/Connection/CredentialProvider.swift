/// Where a connection gets an account's secrets, and keeps the FAST tokens the server issues.
///
/// Every call is for the account's bare JID.
public protocol CredentialProvider: Sendable {
    func password(for jid: JID) async -> String?
    /// The FAST token (XEP-0484) to try before the password, if any. An expired one is not
    /// used.
    func fastToken(for jid: JID) async -> FASTToken?
    /// Replaces the stored FAST token; nil deletes it, after the server refused it.
    func store(_ token: FASTToken?, for jid: JID) async
    /// Whether a SCRAM login has worked for the account before, so PLAIN is refused for it
    /// (XEP-0474): a server, or someone in the middle, that offers only PLAIN gets no password.
    func plainRefused(for jid: JID) async -> Bool
    /// A SCRAM login worked for the account: keep that, so `plainRefused(for:)` is true from
    /// now on, across launches.
    func refusePlain(for jid: JID) async
}

extension CredentialProvider {
    /// Nothing kept: the connection still refuses PLAIN for as long as it lives, once SCRAM
    /// worked. A provider that keeps the account's secrets keeps this too.
    public func plainRefused(for jid: JID) async -> Bool { false }

    public func refusePlain(for jid: JID) async {}
}
