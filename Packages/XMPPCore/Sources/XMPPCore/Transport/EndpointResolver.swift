/// Finds the endpoints of an XMPP domain's client service.
public protocol EndpointResolver: Sendable {
    /// The endpoints to try, in order (RFC 6120 3.2, XEP-0368). Never fails: when neither
    /// lookup finds a record (or both fail), the answer is the domain itself on port 5222 with
    /// STARTTLS. Empty when the domain publishes SRV records and none of them can be used,
    /// such as "." (no service) for both kinds, or "." for one and nothing for the other.
    func endpoints(for domain: String) async -> [ServerEndpoint]
}

/// One DNS SRV record (RFC 2782). A `target` of "." means the service is not offered.
public struct SRVRecord: Sendable, Equatable {
    public var priority: UInt16
    public var weight: UInt16
    public var port: UInt16
    /// A host name without the trailing dot, or "." for the root.
    public var target: String

    public init(priority: UInt16, weight: UInt16, port: UInt16, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }
}

/// Turns the answers for `_xmpps-client._tcp` and `_xmpp-client._tcp` into a connection order.
///
/// Direct TLS endpoints come first, then STARTTLS endpoints (XEP-0368 lets a client prefer one
/// kind), each ordered by priority and then by weight as RFC 2782 describes. A target of "."
/// means that kind of service is not offered.
///
/// The domain itself on port 5222 with STARTTLS (RFC 6120 3.2.2) is the answer only when
/// neither lookup returned any record. Once the domain has published SRV records, there is no
/// A/AAAA fallback: RFC 6120 3.2.1 says not to fall back after an SRV answer, and XEP-0368
/// section 5 forbids it when `_xmpps-client` is ".".
public enum EndpointOrdering {
    public static let fallbackPort = 5222

    public static func order(directTLS: [SRVRecord], startTLS: [SRVRecord], domain: String)
        -> [ServerEndpoint]
    {
        var generator = SystemRandomNumberGenerator()
        return order(directTLS: directTLS, startTLS: startTLS, domain: domain, using: &generator)
    }

    /// `generator` picks among records of equal priority, in proportion to their weights.
    public static func order(
        directTLS: [SRVRecord], startTLS: [SRVRecord], domain: String,
        using generator: inout some RandomNumberGenerator
    ) -> [ServerEndpoint] {
        var endpoints: [ServerEndpoint] = []
        for record in weighted(usable(directTLS), using: &generator) {
            endpoints.append(
                ServerEndpoint(host: record.target, port: Int(record.port), directTLS: true))
        }
        for record in weighted(usable(startTLS), using: &generator) {
            endpoints.append(
                ServerEndpoint(host: record.target, port: Int(record.port), directTLS: false))
        }
        var seen = Set<ServerEndpoint>()
        endpoints = endpoints.filter { seen.insert($0).inserted }
        if directTLS.isEmpty && startTLS.isEmpty {
            return [ServerEndpoint(host: domain, port: fallbackPort, directTLS: false)]
        }
        return endpoints
    }

    private static func usable(_ records: [SRVRecord]) -> [SRVRecord] {
        records.filter { $0.target != "." && !$0.target.isEmpty && $0.port != 0 }
    }

    /// RFC 2782: ascending priority; within one priority, records with weight 0 first, then
    /// repeatedly pick one at random with a chance proportional to its weight.
    private static func weighted(
        _ records: [SRVRecord], using generator: inout some RandomNumberGenerator
    )
        -> [SRVRecord]
    {
        let groups = Dictionary(grouping: records, by: \.priority).sorted { $0.key < $1.key }
        var ordered: [SRVRecord] = []
        ordered.reserveCapacity(records.count)
        for (_, group) in groups {
            var remaining = group.filter { $0.weight == 0 } + group.filter { $0.weight != 0 }
            while !remaining.isEmpty {
                let total = remaining.reduce(UInt64(0)) { $0 + UInt64($1.weight) }
                let pick = UInt64.random(in: 0...total, using: &generator)
                var running: UInt64 = 0
                var index = remaining.count - 1
                for (offset, record) in remaining.enumerated() {
                    running += UInt64(record.weight)
                    if running >= pick {
                        index = offset
                        break
                    }
                }
                ordered.append(remaining.remove(at: index))
            }
        }
        return ordered
    }
}
