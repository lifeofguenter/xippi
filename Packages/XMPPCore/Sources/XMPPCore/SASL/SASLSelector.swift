import Foundation

/// The XMPP SASL profile in use.
public enum SASLProfile: Sendable {
    /// RFC 6120 section 6 (`<mechanisms/>`, `<auth/>`).
    case sasl1
    /// XEP-0388 (`<authentication/>`, `<authenticate/>`).
    case sasl2
}

/// Picks the SASL mechanism for password login, for legacy SASL and SASL2 alike.
public enum SASLSelector {
    /// The best usable mechanism the server offers, in this order: SCRAM-SHA-512-PLUS,
    /// SCRAM-SHA-256-PLUS, SCRAM-SHA-1-PLUS, SCRAM-SHA-512, SCRAM-SHA-256, SCRAM-SHA-1, PLAIN.
    ///
    /// Channel binding for -PLUS: `tls-exporter` (RFC 9266) when the server lists it and the
    /// connection has the TLS 1.3 exporter, else `tls-server-end-point` when the server lists
    /// it and it is defined for the server's certificate (not Ed25519).
    ///
    /// The XEP-0440 business rules, against what the server announced:
    /// - Rule 5, binding types without any -PLUS mechanism: throws `.channelBindingDowngrade`
    ///   (SASL2 MUST, SASL1 SHOULD).
    /// - Rule 4, -PLUS without binding types: throws in SASL2 (MUST). SASL1 leaves it undefined
    ///   (a MAY), so the client binds with the strongest binding it has, or, with none, uses
    ///   the bare mechanism with `n` as RFC 5802 allows (ruling R24).
    /// - Rule 6, -PLUS and binding types, none usable on this connection and
    ///   `tls-server-end-point` not among them: abort, relaxed by XEP-0474 rule 6 to going on
    ///   with a verified hash.
    /// - "Goes on only with a verified hash": SCRAM with `n`, which throws
    ///   `.channelBindingDowngrade` at the server-first-message if no hash arrives
    ///   (`.downgradeDetected` if it does not match). PLAIN carries no hash, so it is refused
    ///   there with `.channelBindingDowngrade`.
    ///
    /// The GS2 flag without -PLUS (RFC 5802 section 6, XEP-0440 rules 2 and 3): `n` when the
    /// server offers -PLUS (it supports binding and would fail `y`) or when this connection
    /// has no binding to offer; `y` when the server offers neither -PLUS nor binding types
    /// and the connection could bind, so a server whose -PLUS was stripped fails the exchange.
    ///
    /// PLAIN only with TLS, only when no SCRAM is offered, and only while `allowPlain`.
    /// XEP-0474 asks a client that once used SCRAM with a server never to fall back to PLAIN
    /// there again: pass false once SCRAM has succeeded for the account.
    ///
    /// - Parameters:
    ///   - offered: the mechanisms of the SASL profile in use (`<mechanisms/>` for SASL1,
    ///     `<authentication/>` for SASL2), never both. They also feed the XEP-0474 hash.
    ///   - offeredBindings: the XEP-0440 `<sasl-channel-binding/>` types, empty when absent.
    ///   - tls: the connection's TLS state, nil when TLS is not up.
    ///   - username: the JID's localpart.
    ///   - profile: the SASL profile `offered` came from.
    public static func choose(
        offered: [String], offeredBindings: [String], tls: TLSInfo?, username: String,
        password: String, profile: SASLProfile, allowPlain: Bool = true
    ) throws(SASLError) -> any SASLMechanism {
        try choose(
            offered: offered, offeredBindings: offeredBindings, tls: tls, username: username,
            password: password, profile: profile, allowPlain: allowPlain,
            clientNonce: .scramNonce())
    }

    /// `choose` with the SCRAM client nonce given, for tests that replay recorded exchanges.
    static func choose(
        offered: [String], offeredBindings: [String], tls: TLSInfo?, username: String,
        password: String, profile: SASLProfile, allowPlain: Bool, clientNonce: String
    ) throws(SASLError) -> any SASLMechanism {
        let offeredNames = Set(offered)
        let hashes: [SCRAM.Hash] = [.sha512, .sha256, .sha1]
        let serverOffersPlus = offered.contains { $0.hasSuffix("-PLUS") }
        let serverAnnouncesTypes = !offeredBindings.isEmpty

        // XEP-0440 rule 5.
        if serverAnnouncesTypes && !serverOffersPlus { throw .channelBindingDowngrade }
        // XEP-0440 rule 4: MUST abort in SASL2.
        if serverOffersPlus && !serverAnnouncesTypes && profile == .sasl2 {
            throw .channelBindingDowngrade
        }

        // This connection's bindings, strongest first (XEP-0440 rule 7). Without a list from
        // the server (rule 4 in SASL1), the strongest one is tried.
        let available = [
            tls.flatMap(ChannelBinding.tlsExporter), tls.flatMap(ChannelBinding.tlsServerEndPoint),
        ].compactMap { $0 }
        let usable =
            serverAnnouncesTypes
            ? available.first(where: { offeredBindings.contains($0.type) }) : available.first
        if let binding = usable {
            for hash in hashes where offeredNames.contains(hash.mechanismName + "-PLUS") {
                return SCRAM(
                    hash: hash, username: username, password: password, channelBinding: binding,
                    offeredMechanisms: offered, offeredBindings: offeredBindings,
                    clientNonce: clientNonce)
            }
        }

        // XEP-0440 rule 6: none of the announced types is usable here.
        let requiresDowngradeHash =
            serverOffersPlus && serverAnnouncesTypes
            && !offeredBindings.contains(ChannelBinding.tlsServerEndPointType)
        // Left as is: the server lists tls-server-end-point but the certificate has no such
        // binding (Ed25519, which also leaves the server unable to compute one). The lists are
        // consistent and no XEP-0440 rule applies, so the exchange goes on with "n".

        for hash in hashes where offeredNames.contains(hash.mechanismName) {
            return SCRAM(
                hash: hash, username: username, password: password, channelBinding: nil,
                offeredMechanisms: offered, offeredBindings: offeredBindings,
                clientSupportsChannelBinding: !available.isEmpty && !serverOffersPlus,
                requiresDowngradeHash: requiresDowngradeHash, clientNonce: clientNonce)
        }

        if allowPlain, tls != nil, offeredNames.contains("PLAIN") {
            guard !requiresDowngradeHash else { throw .channelBindingDowngrade }
            return Plain(username: username, password: password)
        }
        throw .noAcceptableMechanism
    }

    /// The FAST mechanism (XEP-0484) to request a token for, from the server's `<fast/>` list,
    /// strongest binding first (XEP-0484 section 6: channel binding MUST be preferred):
    /// `HT-SHA-256-EXPR` with the TLS 1.3 exporter, `HT-SHA-256-ENDP` with a
    /// `tls-server-end-point` binding, else `HT-SHA-256-NONE`. Nil without TLS or when none of
    /// them fits.
    public static func fastMechanism(offered: [String], tls: TLSInfo?) -> String? {
        guard let tls else { return nil }
        if offered.contains(HTMechanism.exporterName), ChannelBinding.tlsExporter(tls) != nil {
            return HTMechanism.exporterName
        }
        if offered.contains(HTMechanism.endPointName),
            ChannelBinding.tlsServerEndPoint(tls) != nil
        {
            return HTMechanism.endPointName
        }
        return offered.contains(HTMechanism.noneName) ? HTMechanism.noneName : nil
    }
}
