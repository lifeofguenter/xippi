/// What an `XMPPConnection` uses from the world, so tests can replace all of it.
public struct ConnectionEnvironment: Sendable {
    /// Every deadline and timer. A clock that keeps counting while the Mac sleeps
    /// (`ContinuousClock`), so timers set before sleep are due at once on wake.
    public var clock: any Clock<Duration>
    public var resolver: any EndpointResolver
    public var trust: any TrustEvaluator
    public var makeTransport: @Sendable (ServerEndpoint, any TrustEvaluator) -> any XMPPTransport
    /// Turns a backoff delay into the one to wait (`Backoff.delay(attempt:jitter:)`).
    public var jitter: @Sendable (Duration) -> Duration

    public init(
        clock: any Clock<Duration>, resolver: any EndpointResolver, trust: any TrustEvaluator,
        makeTransport:
            @escaping @Sendable (ServerEndpoint, any TrustEvaluator) -> any XMPPTransport,
        jitter: @escaping @Sendable (Duration) -> Duration
    ) {
        self.clock = clock
        self.resolver = resolver
        self.trust = trust
        self.makeTransport = makeTransport
        self.jitter = jitter
    }

    /// The system's clock, DNS, Network.framework and random jitter. `trust` is the account's
    /// own evaluator, with its own pinned certificates only.
    public static func live(trust: any TrustEvaluator) -> Self {
        ConnectionEnvironment(
            clock: ContinuousClock(), resolver: DNSSRVResolver(), trust: trust,
            makeTransport: { endpoint, trust in TCPTransport(endpoint: endpoint, trust: trust) },
            jitter: Backoff.liveJitter)
    }
}

/// The injected clock as time since a fixed start. Deadlines are kept as such offsets, since
/// `any Clock<Duration>` has no instant type a stored property can name.
struct ElapsedClock: Sendable {
    /// Time since the start.
    let now: @Sendable () -> Duration
    /// Sleeps until `now()` reaches the offset; at once when it already has.
    let sleep: @Sendable (_ until: Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self = Self.starting(clock)
    }

    private init(
        now: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    private static func starting<C: Clock<Duration>>(_ clock: C) -> ElapsedClock {
        let start = clock.now
        return ElapsedClock(
            now: { start.duration(to: clock.now) },
            sleep: { offset in
                try await clock.sleep(until: start.advanced(by: offset), tolerance: nil)
            })
    }
}
