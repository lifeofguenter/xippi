import Foundation

/// The system's `XMPPTransport`: Network.framework, TLS 1.2 or newer, for both kinds of
/// endpoint.
///
/// - STARTTLS endpoints start as plain TCP; `startTLS(serverName:)` adds TLS to the running
///   connection.
/// - Direct TLS endpoints (XEP-0368) start TLS with the connection, in
///   `startTLS(serverName:)`, with ALPN `xmpp-client`.
///
/// Either way the XMPP domain given to `startTLS(serverName:)` is the SNI, and the
/// certificate is checked by the `TrustEvaluator` against it, not against the host connected
/// to. On TLS 1.3, `TLSInfo` carries the `tls-exporter` channel binding.
///
/// Before TLS on a STARTTLS endpoint, the server closing its side of the stream is not
/// reported: a read waiting then ends with `.closed` once a send draws a reset from the
/// server, or when the transport is closed. A reset is reported at once. After TLS, the end of
/// the stream is empty data as usual.
///
/// Cancelling a task that waits in one of the calls closes the transport: a read or write
/// handed to the system cannot be withdrawn without breaking the stream.
///
/// `pathEvents` carries the connection's viability and better-path updates.
public final class TCPTransport: XMPPTransport {
    public let endpoint: ServerEndpoint
    private let connection: NetworkConnection

    public init(endpoint: ServerEndpoint, trust: any TrustEvaluator) {
        self.endpoint = endpoint
        connection = NetworkConnection(endpoint: endpoint, trust: trust)
    }

    deinit {
        connection.close()
    }

    public func open() async throws(TransportError) {
        try await connection.open()
    }

    public func startTLS(serverName: String) async throws(TransportError) -> TLSInfo {
        try await connection.startTLS(serverName: serverName)
    }

    public func send(_ data: Data) async throws(TransportError) {
        try await connection.send(data)
    }

    public func receive() async throws(TransportError) -> Data {
        try await connection.receive()
    }

    public func close() {
        connection.close()
    }

    /// Network.framework's viability and better-path updates, until `close()`.
    public var pathEvents: AsyncStream<TransportPathEvent> { connection.pathEvents }

    /// Calls waiting on the system right now, for tests.
    var pendingCallCount: Int { connection.pendingCallCount }
}
