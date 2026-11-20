import Foundation
import Security
import XMPPCore
import XippiStore

/// How an account's file transfers decide on HTTPS certificates (ruling R61): the
/// certificates the user trusted for the account (its pins) count for the hosts of the
/// account's own domain and its subdomains, such as its upload service, and for no other
/// host. Every host gets the system's trust as well (and the test CA's on a test launch).
public struct AccountHostTrust: TrustEvaluator {
    /// The account's domain, lowercased, without a trailing dot.
    public let domain: String
    private let ownHosts: SystemTrustEvaluator
    private let otherHosts: SystemTrustEvaluator

    /// - Parameters:
    ///   - domain: the account's domain (its JID's domainpart).
    ///   - pinnedSHA256: the account's trusted certificates, SHA-256 of the leaf in hex.
    ///   - extraAnchors: roots beside the system's, for the test CA only.
    public init(domain: String, pinnedSHA256: Set<String>, extraAnchors: [SecCertificate] = []) {
        self.domain = Self.normalized(domain)
        ownHosts = SystemTrustEvaluator(pinnedSHA256: pinnedSHA256, extraAnchors: extraAnchors)
        otherHosts = SystemTrustEvaluator(pinnedSHA256: [], extraAnchors: extraAnchors)
    }

    public func evaluate(_ trust: SecTrust, host: String) async -> TrustDecision {
        let evaluator = Self.isOwn(host, of: domain) ? ownHosts : otherHosts
        return await evaluator.evaluate(trust, host: host)
    }

    /// Whether `host` is `domain` or one of its subdomains, compared by labels in A-label
    /// form, without case or a trailing dot. An empty domain owns nothing.
    static func isOwn(_ host: String, of domain: String) -> Bool {
        let host = normalized(host)
        guard !domain.isEmpty, !host.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    /// Lowercased, without a trailing dot, and in A-labels (IDNA ToASCII): a domain in
    /// Unicode matches the host names TLS challenges carry. A name that cannot be converted
    /// stays as it is and matches no A-label, so it fails closed.
    private static func normalized(_ name: String) -> String {
        var name = name.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.unicodeScalars.allSatisfy(\.isASCII) else { return name }
        var components = URLComponents()
        components.scheme = "https"
        components.host = name
        return components.url?.host()?.lowercased() ?? name
    }
}

extension MediaEnvironment {
    /// The account transport the app passes (R61): an account with pinned certificates gets
    /// a transport that trusts them on its own domain's hosts; one without pins gets
    /// `shared`, unchanged.
    public static func pinnedTransports(
        shared: any MediaTransport, extraAnchors: [SecCertificate] = []
    ) -> @Sendable (AccountRecord) -> any MediaTransport {
        { account in
            guard !account.pinnedCertSHA256.isEmpty, let jid = try? JID(account.jid) else {
                return shared
            }
            return URLSessionMediaTransport(
                trust: AccountHostTrust(
                    domain: jid.domainpart, pinnedSHA256: Set(account.pinnedCertSHA256),
                    extraAnchors: extraAnchors))
        }
    }
}
