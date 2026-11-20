import Foundation

/// What one account connects with, apart from its credentials.
public struct AccountConfig: Sendable, Equatable {
    /// The account's JID. Its domain is the server to look up and the name its certificate must
    /// carry.
    public var jid: JID
    /// The resource to ask for in legacy binding; nil lets the server choose.
    public var resource: String?
    /// Connect here instead of looking up the domain's SRV records.
    public var endpointOverride: ServerEndpoint?
    /// This installation's id (SASL2 user agent), which FAST tokens and Bind2 sessions are tied
    /// to.
    public var clientID: UUID
    /// The client's name, for SASL2 and the Bind2 tag. Never anything private.
    public var software: String
    /// The device's name, for SASL2.
    public var device: String
    /// Whether PLAIN may be used. XEP-0474 asks for false once SCRAM worked for the account.
    public var allowPlain: Bool

    public init(
        jid: JID, resource: String? = nil, endpointOverride: ServerEndpoint? = nil,
        clientID: UUID, software: String, device: String, allowPlain: Bool = true
    ) {
        self.jid = jid
        self.resource = resource
        self.endpointOverride = endpointOverride
        self.clientID = clientID
        self.software = software
        self.device = device
        self.allowPlain = allowPlain
    }
}
