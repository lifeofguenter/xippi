/// What a finished negotiation established.
public struct NegotiationResult: Sendable, Equatable {
    /// The session's full JID: the one bound, or the one of the resumed session.
    public var boundJID: JID
    /// A Stream Management session was resumed (XEP-0198): stanzas the server holds for it
    /// follow, and module state carries on. `features` then include what the resumed session
    /// remembered (`SMResumeState.features`).
    public var resumed: Bool
    /// The resumable SM session: the new one, or the resumed one as it was handed in. Nil when
    /// SM is off or the server did not allow resumption.
    public var sm: SMResumeState?
    /// Stream Management is on for this stream.
    public var smEnabled: Bool
    /// Message Carbons (XEP-0280) were enabled by this negotiation. False after a resumption,
    /// where the resumed session keeps whatever it had.
    public var carbonsEnabled: Bool
    /// Carbons are still to be enabled, with the XEP-0280 IQ sent by the session through SM
    /// (`StreamManagementState.willSend(_:)`): Bind2 enabled SM inline but did not offer
    /// carbons inline, and the negotiator sends nothing SM would count.
    public var carbonsNeedIQ: Bool
    /// What the server offers, from every feature list of this negotiation, plus, after a
    /// resumption, what the resumed session remembered. After an inline resumption the
    /// server sends no features (XEP-0198 9.2), so without remembered features only the
    /// pre-authentication view is known.
    public var features: ServerFeatures
    /// A FAST token (XEP-0484) the server issued, requested or rotated. Store it in place of
    /// the old one.
    public var newFASTToken: FASTToken?
    /// The `h` of `<resumed/>`, or of `<failed/>` when the resumption failed and the server
    /// still said how many stanzas it handled. Drop that many from the old SM queue
    /// (`StreamManagementState.handleAck(h:)` or `resumed(serverH:)`) before sending the rest.
    public var resumeAckedH: UInt32?
    /// The server refused the FAST token, so the password was used. Delete the stored token
    /// unless `newFASTToken` replaces it. When the negotiation throws instead, read
    /// `StreamNegotiator.fastTokenRejected`.
    public var fastTokenRejected: Bool
    /// Stanzas the server sent after resource binding while the negotiation waited for the
    /// session IQs, in order. They came before SM was enabled, so SM does not count them. Handle
    /// them before anything read after `.finished`.
    public var pendingStanzas: [Element]
    /// The SASL mechanism that logged this stream in, as the server offered it
    /// ("SCRAM-SHA-256-PLUS", "HT-SHA-256-EXPR", "PLAIN"). Once a SCRAM mechanism worked,
    /// PLAIN is refused for the account (XEP-0474).
    public var mechanism: String?

    public init(
        boundJID: JID, resumed: Bool, sm: SMResumeState?, smEnabled: Bool, carbonsEnabled: Bool,
        features: ServerFeatures, newFASTToken: FASTToken?, resumeAckedH: UInt32?,
        fastTokenRejected: Bool = false, pendingStanzas: [Element] = [],
        carbonsNeedIQ: Bool = false, mechanism: String? = nil
    ) {
        self.boundJID = boundJID
        self.resumed = resumed
        self.sm = sm
        self.smEnabled = smEnabled
        self.carbonsEnabled = carbonsEnabled
        self.features = features
        self.newFASTToken = newFASTToken
        self.resumeAckedH = resumeAckedH
        self.fastTokenRejected = fastTokenRejected
        self.pendingStanzas = pendingStanzas
        self.carbonsNeedIQ = carbonsNeedIQ
        self.mechanism = mechanism
    }
}

extension NegotiationResult: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    // `newFASTToken` describes itself without the token; everything else here is no secret.
    public var description: String {
        "NegotiationResult(\(boundJID), resumed: \(resumed), smEnabled: \(smEnabled),"
            + " carbonsEnabled: \(carbonsEnabled), newFASTToken: \(newFASTToken.map { "\($0)" } ?? "nil"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "boundJID": boundJID, "resumed": resumed, "smEnabled": smEnabled,
                "carbonsEnabled": carbonsEnabled, "carbonsNeedIQ": carbonsNeedIQ,
                "features": features,
                "newFASTToken": newFASTToken as Any, "resumeAckedH": resumeAckedH as Any,
                "fastTokenRejected": fastTokenRejected,
                "pendingStanzas": pendingStanzas.count, "mechanism": mechanism as Any,
            ])
    }
}

/// Why a negotiation ended. None of the cases carries a password, a proof or a token.
public enum NegotiationError: Error, Equatable {
    /// The stream is not encrypted and the server does not offer STARTTLS, or STARTTLS failed.
    case tlsRequired
    /// The server refused the credentials, with its SASL condition (RFC 6120 section 6.5).
    case authFailed(condition: String, text: String?)
    /// The server refused resource binding (RFC 6120 section 7.6.2) or session establishment.
    case bindFailed(StanzaError)
    /// The server ended the stream with this stream error (RFC 6120 section 4.9.3). A
    /// `see-other-host` that is malformed, or that leaves the domain before TLS, is reported
    /// here too, not followed.
    case streamError(condition: String, text: String?)
    /// The server broke the protocol in a way no stream error describes.
    case unexpected(String)
    /// The server redirects the client (RFC 6120 section 4.9.3.19) to this host or host:port,
    /// checked for syntax. Connect there with the same domain, `to` and certificate checks.
    case seeOtherHost(String)
    /// SASL went wrong on the client's side: no usable mechanism, a server that failed to prove
    /// itself, a downgrade, or credentials that cannot be used.
    case sasl(SASLError)
    /// The server's stream broke the rules: the condition is the stream error to answer with
    /// (`streamErrorToSend`) before closing the stream.
    case invalidStream(condition: String)
}

extension NegotiationError {
    /// The `<stream:error/>` to send before `</stream:stream>` when the client is the side that
    /// ends the stream over the server's error; nil otherwise.
    public var streamErrorToSend: Element? {
        guard case .invalidStream(let condition) = self else { return nil }
        return Element(
            "error", namespace: NegotiationNamespace.streams,
            children: [.element(Element(condition, namespace: NegotiationNamespace.streamErrors))])
    }
}
