import Foundation

/// What `XMPPConnection.events` reports, in the order it happened: lifecycle events and stanzas
/// interleaved exactly as they came.
///
/// Session lifecycle:
/// - Leaving `online` gives one `sessionEnded`. `resumable: true` means the session may come
///   back with `sessionResumed`; `resumable: false` means it is gone.
/// - A session that was left resumable and is then given up (the resumption failed or was cut
///   off, the user disconnected, the login failed) gives one `sessionEnded(resumable: false)`
///   at that point.
/// - When a session is ready, exactly one of `sessionResumed` and `sessionStarted` follows.
///   Module state is keyed to these events; there is no other reset path.
public enum ConnectionEvent: Sendable, Equatable {
    case state(ConnectionState)
    /// A new session. Stanzas that follow belong to it.
    case sessionStarted(NegotiationResult)
    /// The earlier session, resumed (XEP-0198). `carbonsEnabled` is the earlier session's.
    case sessionResumed(NegotiationResult)
    case sessionEnded(resumable: Bool)
    /// The server has the sent stanzas with these `id`s (stanzas without one are left out):
    /// with SM when the server acknowledges them (`<a/>`, or the `h` of `<resumed/>` and
    /// `<failed/>`), without SM once they are written. A stanza sent and never acknowledged
    /// when `sessionEnded(resumable: false)` comes was not delivered by this session: send it
    /// again after `sessionStarted`. Comes before the `sessionEnded` or `sessionResumed` its
    /// acknowledgement belongs to.
    case acknowledged(stanzaIDs: [String])
    /// A `<message/>`, `<presence/>` or `<iq/>` for the session. IQ results and errors that
    /// answer a `request` are not reported here. An IQ `get` or `set` is reported and not
    /// answered: the session's router answers every one.
    case stanza(Element)
}

/// One element on the wire, for the XML console (`XMPPConnection.setStreamTap`).
///
/// SASL exchanges, FAST tokens and passwords are replaced by "[redacted]".
public struct StreamTapEntry: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case incoming, outgoing
    }

    public var direction: Direction
    public var xml: String
    public var date: Date

    public init(direction: Direction, xml: String, date: Date) {
        self.direction = direction
        self.xml = xml
        self.date = date
    }
}
