import Foundation
import os

/// A byte stream to one XMPP server endpoint, with TLS.
///
/// Call order:
/// - `open()` once.
/// - On a direct TLS endpoint, `startTLS(serverName:)` right after `open()`: `send` and
///   `receive` refuse with `.invalidCall("TLS not started")` until TLS is up, so no byte travels
///   in clear.
/// - On a STARTTLS endpoint, `startTLS(serverName:)` after the server's `<proceed/>`, with no
///   `receive()` outstanding.
/// - `close()` at the end. Any call outstanding then ends with `.closed`, and every later call
///   fails with `.closed`.
///
/// One `receive()` at a time: a second one while the first is outstanding fails at once with
/// `.invalidCall`, as does every other call out of this order. Sends may come from any task;
/// they go out in the order they were made.
public protocol XMPPTransport: AnyObject, Sendable {
    /// Starts the connection. A failure to connect is reported by the call that next needs the
    /// connection (`startTLS`, `send` or `receive`), as `.connectFailed`.
    func open() async throws(TransportError)

    /// Starts TLS and returns once the server's certificate is accepted.
    ///
    /// `serverName` is the XMPP domain the certificate must be valid for (RFC 6120 13.7.2.1),
    /// not the host the connection went to.
    func startTLS(serverName: String) async throws(TransportError) -> TLSInfo

    func send(_ data: Data) async throws(TransportError)

    /// The next bytes from the server, as soon as there are any; empty at the end of the stream.
    ///
    /// Exception: before TLS on a STARTTLS endpoint, `TCPTransport` may not see the server
    /// close its side of the stream. The read then ends with `.closed` once a send draws a
    /// reset, or only when the caller's deadline closes the transport, so every read before
    /// TLS needs a deadline.
    func receive() async throws(TransportError) -> Data

    /// Ends the connection. Safe to call more than once, from any context.
    func close()

    /// What the system reports about the connection's network path, for one consumer.
    /// Finishes when the transport is closed.
    var pathEvents: AsyncStream<TransportPathEvent> { get }
}

/// A change in a connection's network path (Network.framework viability and better-path
/// updates).
public enum TransportPathEvent: Sendable, Equatable {
    /// The path can carry data (true) or cannot right now (false). Not viable is not failed:
    /// the connection may recover.
    case viabilityChanged(Bool)
    /// A better path is available, such as Ethernet while the connection uses Wi-Fi.
    case betterPathAvailable
}

/// Why a transport call failed.
public enum TransportError: Error, Equatable {
    /// The connection could not be made: refused, unreachable, unknown host. Another endpoint
    /// may work.
    case connectFailed(String)
    /// The system gave up waiting for the network before the connection was up.
    case timedOut
    /// The connection is gone: `close()` was called, or it was lost (reset, timed out) after it
    /// was up.
    case closed
    /// TLS could not be started or failed.
    case tls(String)
    /// The server's certificate was not accepted.
    case untrusted(ServerCertificateProblem)
    /// The call is not allowed now: a mistake in the caller's call order, such as a second
    /// `receive()` while one is outstanding, never a network condition.
    case invalidCall(String)
}

extension Logger {
    /// The package's log category.
    static let xmppCore = Logger(subsystem: "eu.xippi.Xippi", category: "XMPPCore")
}
