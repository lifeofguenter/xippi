/// How long to wait before the next try after failed ones (spec 7.3): 1 s, doubling with each
/// failure, at most 60 s, with jitter.
public enum Backoff {
    public static let initial: Duration = .seconds(1)
    public static let maximum: Duration = .seconds(60)

    /// The wait after `attempt` failures in a row (1 or more; 0 or less waits nothing).
    /// `jitter` takes the exponential delay and returns the one to use, which is kept between
    /// zero and `maximum`.
    public static func delay(attempt: Int, jitter: (Duration) -> Duration = { $0 }) -> Duration {
        guard attempt >= 1 else { return .zero }
        // 2^6 s is past the maximum already; a larger shift would only overflow.
        let exponential = initial * (1 << min(attempt - 1, 6))
        let jittered = jitter(min(exponential, maximum))
        return min(max(jittered, .zero), maximum)
    }

    /// A random 80 to 100 % of the delay, so clients cut off together do not come back
    /// together.
    public static let liveJitter: @Sendable (Duration) -> Duration = { delay in
        delay * Double.random(in: 0.8...1.0)
    }
}
