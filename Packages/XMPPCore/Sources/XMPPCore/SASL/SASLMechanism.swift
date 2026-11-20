import Foundation

/// One client side SASL exchange (RFC 4422), used by both legacy SASL (RFC 6120) and SASL2
/// (XEP-0388). Values are single use: one instance per authentication attempt.
///
/// Call order:
/// - `initialResponse()` once, for the `<auth/>` or `<authenticate/>` element.
/// - `respond(to:)` for each challenge, with the challenge's decoded bytes.
/// - `verifySuccess(_:)` with the decoded additional data of `<success/>`, or nil when it has
///   none. It throws unless the server proved itself where the mechanism can do that.
///
/// A call that throws leaves the mechanism failed; start a new one to try again.
///
/// Calls are synchronous and can be slow: SCRAM's key derivation runs up to 10,000,000
/// iterations, about a second or more. Never call them on the main actor.
public protocol SASLMechanism: Sendable {
    /// The IANA mechanism name, as sent in the `mechanism` attribute.
    var name: String { get }

    /// The client's first message. Nil when the mechanism has none.
    mutating func initialResponse() throws(SASLError) -> Data?

    /// The answer to a server challenge.
    mutating func respond(to challenge: Data) throws(SASLError) -> Data

    /// Checks the server's additional data with success.
    mutating func verifySuccess(_ additionalData: Data?) throws(SASLError)
}

/// Channel binding data for a TLS connection (RFC 5056).
public struct ChannelBinding: Sendable, Equatable {
    /// The channel binding type name from the IANA registry, such as `tls-server-end-point`.
    public var type: String
    /// The binding data for this connection.
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// The `tls-exporter` type name (RFC 9266).
    public static let tlsExporterType = "tls-exporter"

    /// The connection's `tls-exporter` binding, or nil when the connection has none (TLS 1.2,
    /// or a TLS stack that does not expose the exporter).
    public static func tlsExporter(_ tls: TLSInfo) -> ChannelBinding? {
        guard let data = tls.exporterBinding, !data.isEmpty else { return nil }
        return ChannelBinding(type: tlsExporterType, data: data)
    }

    /// The `tls-server-end-point` type name (RFC 5929 section 4).
    public static let tlsServerEndPointType = "tls-server-end-point"

    /// The connection's `tls-server-end-point` binding, or nil when it is undefined for the
    /// server's certificate (for example Ed25519).
    public static func tlsServerEndPoint(_ tls: TLSInfo) -> ChannelBinding? {
        let data = tls.tlsServerEndPointBinding()
        guard !data.isEmpty else { return nil }
        return ChannelBinding(type: tlsServerEndPointType, data: data)
    }
}

extension Data {
    /// Compares in time that depends only on the lengths, for values derived from secrets.
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(self, other) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
