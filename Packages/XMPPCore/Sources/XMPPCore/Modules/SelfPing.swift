/// What a self-ping says about the user's place in a room.
public enum SelfPingResult: Sendable, Hashable {
    /// Still joined: nothing to do.
    case joined
    /// No longer joined: rejoin.
    case notJoined
    /// No answer, or the room's server cannot be reached: mark the room unreachable and ping
    /// again with backoff.
    case unreachable
    /// The session ended before an answer came, or there was none: nothing was learned about
    /// the room. The session's own events decide what happens to it (a new session rejoins
    /// every room).
    case noSession
}

/// XEP-0410 MUC Self-Ping: whether the user is still joined to a room, found by pinging the
/// user's own occupant JID.
public enum SelfPing {
    /// Pings `occupant`, the user's own occupant JID (`room@service/nick`), and classifies the
    /// answer with `classify`. A JID without a nick cannot be pinged this way (the room itself
    /// would answer) and gives `.notJoined`, so the room is joined afresh.
    public static func check(
        occupant: JID, timeout: Duration = .seconds(30), via sender: any StanzaSending
    ) async -> SelfPingResult {
        guard occupant.resourcepart != nil else { return .notJoined }
        let ping = Element.iq(
            type: .get, to: occupant, payload: Element("ping", namespace: Ping.namespace))
        do {
            return classify(
                .success(try await sender.request(ping, timeout: timeout)), occupant: occupant)
        } catch {
            return classify(.failure(error), occupant: occupant)
        }
    }

    /// The answer to a self-ping, classified as XEP-0410 1.1.0 section 3.2 says (ruling R35;
    /// spec 7.4 follows it):
    ///
    /// - `result`: `.joined`.
    /// - `service-unavailable`, `feature-not-implemented`: `.joined`; the ping reached a client
    ///   of the user's that does not answer pings.
    /// - `item-not-found`: `.joined`; another client of the user's has just changed the
    ///   occupant's nick.
    /// - `remote-server-not-found`, `remote-server-timeout`: `.unreachable`; the room's server
    ///   cannot be reached, which decides nothing ("treat like a timeout").
    /// - A timeout: `.unreachable`.
    /// - `not-acceptable` (what a room answers a non-occupant) and any other error:
    ///   `.notJoined`.
    /// - The session ended, or none was online: `.noSession`.
    ///
    /// Every answer here comes from the occupant JID: the connection matches an IQ answer only
    /// when it comes from the JID the request went to (`IQTracker`), so a reply from any other
    /// JID never ends the request and counts as no answer. A `result` whose `from` is not
    /// `occupant` is held to the same rule here.
    ///
    /// XEP-0410 section 4: do not self-ping a room between asking for a nick change and the
    /// room's answer to it, since the old nick may already be gone.
    public static func classify(_ outcome: Result<Element, IQError>, occupant: JID)
        -> SelfPingResult
    {
        switch outcome {
        case .success(let result):
            return result.from == occupant ? .joined : .unreachable
        case .failure(.timeout):
            return .unreachable
        case .failure(.sessionEnded), .failure(.notConnected):
            return .noSession
        case .failure(.malformedResponse):
            return .notJoined
        case .failure(.error(let error)):
            switch error.condition {
            case .serviceUnavailable, .featureNotImplemented, .itemNotFound: return .joined
            case .remoteServerNotFound, .remoteServerTimeout: return .unreachable
            default: return .notJoined
            }
        }
    }
}
