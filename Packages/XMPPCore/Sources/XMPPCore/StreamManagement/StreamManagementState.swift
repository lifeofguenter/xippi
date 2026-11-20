/// What it takes to resume a Stream Management session (XEP-0198) on a new connection.
public struct SMResumeState: Sendable, Codable, Equatable {
    /// The SM-ID from the server's `<enabled/>`, sent back as `previd`.
    public var id: String
    /// Where the server wants the client to reconnect to resume, as host or host:port; nil
    /// when it named no place.
    public var location: String?
    /// How long the server keeps the session after a disconnect, in seconds, when it said.
    public var maxSeconds: Int?
    /// Stanzas received from the server since SM was enabled: the `h` sent in `<resume/>`.
    public var inboundH: UInt32
    /// Stanzas sent to the server since SM was enabled.
    public var outboundH: UInt32
    /// The full JID the session is bound to, which a resumed session keeps. Without it,
    /// `StreamNegotiator` binds a new session instead of resuming.
    public var boundJID: JID?
    /// What the server offered for the session. After an inline resumption the server sends no
    /// features (XEP-0198 9.2), so these stand in for the ones only sent after authentication.
    public var features: ServerFeatures?

    public init(
        id: String, location: String?, maxSeconds: Int?, inboundH: UInt32, outboundH: UInt32,
        boundJID: JID? = nil, features: ServerFeatures? = nil
    ) {
        self.id = id
        self.location = location
        self.maxSeconds = maxSeconds
        self.inboundH = inboundH
        self.outboundH = outboundH
        self.boundJID = boundJID
        self.features = features
    }
}

public enum SMError: Error, Equatable {
    /// The server acknowledged more stanzas than were sent, or fewer than it had already
    /// acknowledged.
    case ackOutOfRange
}

/// The client side of Stream Management (XEP-0198): the two counters and the queue of sent
/// stanzas the server has not acknowledged yet.
///
/// - Counting starts at `enabled(...)`. Every stanza sent from then on goes through
///   `willSend(_:)` and stays queued until acknowledged; every stanza received goes through
///   `received(stanza:)`. Only `<message/>`, `<presence/>` and `<iq/>` count; anything else
///   (SM's own `<a/>` and `<r/>`, stream features) is ignored by both.
/// - Before `enabled(...)` nothing is counted or queued.
/// - Both counters wrap from 2^32 - 1 to 0 (XEP-0198 section 5).
/// - `handleAck(h:)` drops what the server acknowledged. `resumed(serverH:)` does the same after
///   `<resumed/>` and returns what is left, to be sent again as it is: those stanzas are queued
///   and counted already, so they do not go through `willSend(_:)` again.
/// - After a failed resumption, apply its `h` (if any) with `handleAck(h:)`, take `unacked`,
///   then call `enabled(...)` for the new session, which starts over from zero.
public struct StreamManagementState: Sendable {
    public private(set) var isEnabled = false
    public private(set) var id: String?
    public private(set) var resumable = false
    public private(set) var location: String?
    public private(set) var maxSeconds: Int?
    public private(set) var boundJID: JID?
    public private(set) var features: ServerFeatures?
    /// Stanzas received and handled since SM was enabled.
    public internal(set) var inboundH: UInt32 = 0
    /// Stanzas sent since SM was enabled.
    public internal(set) var outboundH: UInt32 = 0
    /// Sent stanzas the server has not acknowledged, oldest first.
    public private(set) var unacked: [Element] = []

    public init() {}

    /// SM is on, from the server's `<enabled/>`: both counters start at zero and the queue is
    /// emptied. `boundJID` and `features` go into `resumeState`; without `boundJID` the session
    /// cannot be resumed. Prefer `enabled(from:)`, which sets all of them.
    public mutating func enabled(
        id: String?, resumable: Bool, location: String?, max: Int?, boundJID: JID? = nil,
        features: ServerFeatures? = nil
    ) {
        isEnabled = true
        self.id = id
        self.resumable = resumable && id != nil
        self.location = location
        maxSeconds = max.flatMap { $0 >= 0 ? $0 : nil }
        self.boundJID = boundJID
        self.features = features
        inboundH = 0
        outboundH = 0
        unacked = []
    }

    /// Starts SM for a new session from its negotiation: on when `result.smEnabled`, resumable
    /// when `result.sm` is set, with the session's id, location, max, full JID and features.
    /// Not for a resumed session: keep its state and call `resumed(serverH:)`.
    public mutating func enabled(from result: NegotiationResult) {
        guard result.smEnabled else {
            self = StreamManagementState()
            return
        }
        enabled(
            id: result.sm?.id, resumable: result.sm != nil, location: result.sm?.location,
            max: result.sm?.maxSeconds, boundJID: result.boundJID,
            features: result.sm?.features ?? result.features)
    }

    /// Counts and queues a stanza about to be sent.
    public mutating func willSend(_ stanza: Element) {
        guard isEnabled, Self.isStanza(stanza) else { return }
        unacked.append(stanza)
        outboundH &+= 1
    }

    /// Counts a stanza received from the server.
    public mutating func received(stanza: Element) {
        guard isEnabled, Self.isStanza(stanza) else { return }
        inboundH &+= 1
    }

    /// `<a h='…'/>` with the inbound count, the answer to the server's `<r/>`.
    public func ackElement() -> Element {
        Element("a", namespace: Self.namespace, attributes: ["h": String(inboundH)])
    }

    /// `<r/>`, asking the server for its count.
    public func requestElement() -> Element {
        Element("r", namespace: Self.namespace)
    }

    /// Drops the stanzas the server's `h` acknowledges and returns them, oldest first. An `h`
    /// beyond what was sent, or below the last acknowledged count, throws `.ackOutOfRange` and
    /// changes nothing.
    public mutating func handleAck(h: UInt32) throws(SMError) -> [Element] {
        let acknowledgedBefore = outboundH &- UInt32(truncatingIfNeeded: unacked.count)
        let newlyAcknowledged = Int(h &- acknowledgedBefore)
        guard newlyAcknowledged <= unacked.count else { throw .ackOutOfRange }
        let acknowledged = Array(unacked.prefix(newlyAcknowledged))
        unacked.removeFirst(newlyAcknowledged)
        return acknowledged
    }

    /// Applies the `h` of `<resumed/>` and returns the stanzas to send again, which stay
    /// queued until acknowledged.
    public mutating func resumed(serverH: UInt32) throws(SMError) -> [Element] {
        _ = try handleAck(h: serverH)
        return unacked
    }

    /// What resuming this session takes; nil unless SM is on and the server allowed resumption.
    public var resumeState: SMResumeState? {
        guard isEnabled, resumable, let id else { return nil }
        return SMResumeState(
            id: id, location: location, maxSeconds: maxSeconds, inboundH: inboundH,
            outboundH: outboundH, boundJID: boundJID, features: features)
    }

    static let namespace = "urn:xmpp:sm:3"

    /// `<message/>`, `<presence/>` or `<iq/>` in the client namespace (or none, as built locally).
    static func isStanza(_ element: Element) -> Bool {
        guard element.namespace == nil || element.namespace == "jabber:client" else { return false }
        return element.name == "message" || element.name == "presence" || element.name == "iq"
    }
}
