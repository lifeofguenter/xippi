/// Why SASL authentication cannot go on. None of the cases carries a password, a salted
/// password, a proof or a token.
public enum SASLError: Error, Equatable {
    /// Nothing the server offers is usable here: no supported mechanism, PLAIN without TLS,
    /// a -PLUS mechanism without channel binding data, or a FAST token for a mechanism that
    /// cannot run on this connection.
    case noAcceptableMechanism
    /// The server's data breaks the mechanism's syntax or rules (RFC 5802 section 7), or came
    /// at a point in the exchange where none was expected.
    case malformedChallenge
    /// The server could not prove it knows the credentials: a wrong or missing SCRAM server
    /// signature or HT responder message, or success before the exchange ended.
    case serverSignatureMismatch
    /// The XEP-0474 hash shows that the mechanism or channel binding lists the client saw are
    /// not the ones the server sent.
    case downgradeDetected
    /// The server's channel binding announcements break the XEP-0440 business rules: what an
    /// attacker who strips channel binding leaves behind. Raised when choosing the mechanism,
    /// or at the server-first-message when only a verified XEP-0474 hash could have cleared
    /// them and none arrived.
    case channelBindingDowngrade
    /// The username or password cannot be prepared with SASLprep, or is empty afterwards. The
    /// exchange is aborted before anything is sent (RFC 5802 5.1); ask the user again.
    case unusableCredential(SASLCredential)
    /// Authentication failed with a SASL condition (RFC 6120 6.5) from the server.
    case failure(condition: String, text: String?)
}

/// Which credential `SASLError.unusableCredential` is about.
public enum SASLCredential: Sendable, Equatable {
    case username, password
}
