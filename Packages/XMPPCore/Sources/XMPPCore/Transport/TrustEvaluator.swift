import CryptoKit
import Foundation
import Security

/// Decides whether a server's certificate is accepted for an XMPP domain.
public protocol TrustEvaluator: Sendable {
    /// `host` is the XMPP domain the certificate must be valid for. The evaluator may change the
    /// trust's policies and anchors.
    func evaluate(_ trust: SecTrust, host: String) async -> TrustDecision
}

public enum TrustDecision: Sendable, Equatable {
    case trusted
    case rejected(ServerCertificateProblem)
}

/// A certificate that was not accepted, with what a person needs to decide whether to accept it
/// anyway.
public struct ServerCertificateProblem: Error, Sendable, Equatable {
    /// The XMPP domain the certificate was checked against.
    public var host: String
    /// The leaf certificate, DER encoded; empty when the server sent none.
    public var leafDER: Data
    /// SHA-256 of `leafDER` in lowercase hex, the value to pin when the person accepts it.
    public var sha256: String
    /// "not trusted", "expired", "not yet valid", "name mismatch", "revoked" or "no certificate".
    public var reason: String

    public init(host: String, leafDER: Data, sha256: String, reason: String) {
        self.host = host
        self.leafDER = leafDER
        self.sha256 = sha256
        self.reason = reason
    }
}

/// Trusts a certificate the system trusts for the host, or one whose leaf the person accepted
/// before (pinned by its SHA-256). A pin is per certificate: when the server's certificate
/// changes, the new one is checked on its own again.
///
/// A pin holds for whatever host it is checked against. Build one evaluator per account, from
/// that account's pins only: an evaluator shared by accounts would let a certificate accepted for
/// one domain (a captive portal's, say) stand in for another.
public struct SystemTrustEvaluator: TrustEvaluator {
    private let pinnedSHA256: Set<String>
    private let extraAnchors: [SecCertificate]

    /// - Parameters:
    ///   - pinnedSHA256: SHA-256 of accepted leaf certificates, hex in either case, colons allowed.
    ///   - extraAnchors: roots trusted beside the system's, for the test CA only.
    public init(pinnedSHA256: Set<String>, extraAnchors: [SecCertificate] = []) {
        self.pinnedSHA256 = Set(pinnedSHA256.map { $0.lowercased().filter { $0 != ":" } })
        self.extraAnchors = extraAnchors
    }

    public func evaluate(_ trust: SecTrust, host: String) async -> TrustDecision {
        guard !host.isEmpty else {
            let leafDER = Self.leafDER(of: trust)
            return .rejected(
                ServerCertificateProblem(
                    host: host, leafDER: leafDER, sha256: Self.sha256(leafDER),
                    reason: "name mismatch"))
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if !extraAnchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, extraAnchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
        }
        let failure = await Self.evaluateOffTheCallerThread(trust)
        let leafDER = Self.leafDER(of: trust)
        let sha256 = Self.sha256(leafDER)
        guard let failure else { return .trusted }
        if !leafDER.isEmpty && pinnedSHA256.contains(sha256) {
            return .trusted
        }
        let reason = leafDER.isEmpty ? "no certificate" : Self.reason(for: failure)
        return .rejected(
            ServerCertificateProblem(host: host, leafDER: leafDER, sha256: sha256, reason: reason))
    }

    private static func sha256(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func leafDER(of trust: SecTrust) -> Data {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else {
            return Data()
        }
        return SecCertificateCopyData(leaf) as Data
    }

    /// The error code of a failed evaluation, or nil when the trust passed. Evaluation can wait
    /// on the network (intermediates, revocation), so it runs on a queue of its own.
    private static func evaluateOffTheCallerThread(_ trust: SecTrust) async -> Int? {
        let handOver = TrustHandOver(trust: trust)
        return await withCheckedContinuation { continuation in
            evaluationQueue.async {
                let status = SecTrustEvaluateAsyncWithError(handOver.trust, evaluationQueue) {
                    _, trusted, error in
                    continuation.resume(
                        returning: trusted ? nil : error.map { CFErrorGetCode($0) } ?? -1)
                }
                if status != errSecSuccess {
                    continuation.resume(returning: Int(status))
                }
            }
        }
    }

    private static let evaluationQueue = DispatchQueue(label: "eu.xippi.Xippi.trust")

    private static func reason(for code: Int) -> String {
        switch OSStatus(truncatingIfNeeded: code) {
        case errSecCertificateExpired: "expired"
        case errSecCertificateNotValidYet: "not yet valid"
        case errSecHostNameMismatch: "name mismatch"
        case errSecCertificateRevoked: "revoked"
        default: "not trusted"
        }
    }
}

/// Carries a `SecTrust` to the evaluation queue.
///
/// `@unchecked Sendable`: `SecTrust` is not marked Sendable. The trust is handed over whole: the
/// caller does not touch it until the evaluation has called back, so it is never used from two
/// threads at once.
private struct TrustHandOver: @unchecked Sendable {
    let trust: SecTrust
}
