import CryptoKit
import Foundation

/// A FAST token (XEP-0484) as the server issued it in `<token/>`. The token is a secret
/// equivalent to a password: store it in the Keychain and keep it out of logs.
public struct FASTToken: Sendable, Codable, Equatable {
    /// The FAST mechanism the token was requested for; the server refuses it for any other.
    public var mechanism: String
    public var token: String
    public var expiry: Date

    public init(mechanism: String, token: String, expiry: Date) {
        self.mechanism = mechanism
        self.token = token
        self.expiry = expiry
    }
}

extension FASTToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Never the token itself.
    public var description: String { "FASTToken(\(mechanism), expiry: \(expiry))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["mechanism": mechanism, "expiry": expiry])
    }
}

/// The Hashed Token mechanisms FAST uses (draft-schmaus-kitten-sasl-ht-09): `HT-SHA-256-EXPR`
/// with the `tls-exporter` binding, `HT-SHA-256-ENDP` with `tls-server-end-point`, and
/// `HT-SHA-256-NONE` without one. One round trip: the client proves it holds the token, and the
/// server's additional data with success proves the server holds it too.
public struct HTMechanism: SASLMechanism {
    public static let exporterName = "HT-SHA-256-EXPR"
    public static let endPointName = "HT-SHA-256-ENDP"
    public static let noneName = "HT-SHA-256-NONE"

    /// The token's own mechanism: the server binds a token to the one it was requested for.
    public let name: String
    private let username: String
    private let key: Data
    private let bindingData: Data
    private var step = Step.start

    private enum Step: Sendable {
        case start, sent, verified, failed
    }

    /// Refuses with `.noAcceptableMechanism` a token for another mechanism, an EXPR or ENDP
    /// token without a non-empty binding of its type (`tls-exporter`, `tls-server-end-point`),
    /// an empty token, or a username that is empty or holds NUL. The binding is ignored for
    /// NONE.
    public init(username: String, token: FASTToken, binding: ChannelBinding?) throws(SASLError) {
        guard !username.isEmpty, !username.utf8.contains(0), !token.token.isEmpty else {
            throw .noAcceptableMechanism
        }
        switch token.mechanism {
        case Self.noneName:
            bindingData = Data()
        case Self.exporterName, Self.endPointName:
            let type =
                token.mechanism == Self.exporterName
                ? ChannelBinding.tlsExporterType : ChannelBinding.tlsServerEndPointType
            guard let binding, binding.type == type, !binding.data.isEmpty else {
                throw .noAcceptableMechanism
            }
            bindingData = binding.data
        default:
            throw .noAcceptableMechanism
        }
        name = token.mechanism
        self.username = username
        key = Data(token.token.utf8)
    }

    /// The token's mechanism with the binding it needs from this connection. Throws
    /// `.noAcceptableMechanism` when the connection cannot provide it: no TLS 1.3 exporter for
    /// EXPR (STARTTLS), or a certificate without `tls-server-end-point` for ENDP. Fall back to
    /// the password then.
    public init(username: String, token: FASTToken, tls: TLSInfo?) throws(SASLError) {
        let binding: ChannelBinding? =
            switch token.mechanism {
            case Self.exporterName: tls.flatMap(ChannelBinding.tlsExporter)
            case Self.endPointName: tls.flatMap(ChannelBinding.tlsServerEndPoint)
            default: nil
            }
        try self.init(username: username, token: token, binding: binding)
    }

    /// initiator-msg = authcid NUL HMAC(token, "Initiator" || cb-data)
    public mutating func initialResponse() throws(SASLError) -> Data? {
        guard case .start = step else {
            step = .failed
            throw .malformedChallenge
        }
        step = .sent
        var message = Data(username.utf8)
        message.append(0)
        message.append(hashedToken("Initiator"))
        return message
    }

    /// HT is a single round trip: a challenge is a protocol error.
    public mutating func respond(to challenge: Data) throws(SASLError) -> Data {
        step = .failed
        throw .malformedChallenge
    }

    /// The additional data must be HMAC(token, "Responder" || cb-data) (section 3.3).
    public mutating func verifySuccess(_ additionalData: Data?) throws(SASLError) {
        let current = step
        step = .failed
        guard case .sent = current, let additionalData,
            additionalData.constantTimeEquals(hashedToken("Responder"))
        else { throw .serverSignatureMismatch }
        step = .verified
    }

    private func hashedToken(_ label: String) -> Data {
        var message = Data(label.utf8)
        message.append(bindingData)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}

extension HTMechanism: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Only the name: the stored values include the token.
    public var description: String { name }
    public var debugDescription: String { "HTMechanism(\(name))" }
    public var customMirror: Mirror { Mirror(self, children: ["name": name]) }
}
