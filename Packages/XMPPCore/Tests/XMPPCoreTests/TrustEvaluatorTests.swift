import CryptoKit
import Foundation
import Security
import Testing

@testable import XMPPCore

@Suite struct TrustEvaluatorTests {
    static let selfSignedA = "988d7927aa12ff507e84d34d670661b003f514ae3448bdd925afe3fe21e5c057"
    static let selfSignedB = "5455d5f74f1cd59ee0370f25858d7c909ea1acbdcc5b313cc55e4dab821ce316"

    @Test(.enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"))
    func chainFromTheTestCAIsTrustedWithExtraAnchors() async throws {
        let evaluator = SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
        let trust = try makeTrust([try TLSFixtures.devCertificate("server.pem")])
        #expect(await evaluator.evaluate(trust, host: "prosody.test") == .trusted)
    }

    @Test(.enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"))
    func chainFromTheTestCAIsRejectedWithoutExtraAnchors() async throws {
        let trust = try makeTrust([try TLSFixtures.devCertificate("server.pem")])
        let problem = try #require(
            await SystemTrustEvaluator(pinnedSHA256: []).evaluate(trust, host: "prosody.test")
                .problem)
        #expect(problem.reason == "not trusted")
    }

    @Test(.enabled(if: TLSFixtures.testCAAvailable, "make certs writes dev/certs"))
    func otherNameIsRejected() async throws {
        let evaluator = SystemTrustEvaluator(
            pinnedSHA256: [], extraAnchors: [try TLSFixtures.devCertificate("test-ca.pem")])
        let trust = try makeTrust([try TLSFixtures.devCertificate("server.pem")])
        let problem = try #require(await evaluator.evaluate(trust, host: "other.test").problem)
        #expect(problem.reason == "name mismatch")
        #expect(problem.host == "other.test")
    }

    @Test func selfSignedLeafIsRejected() async throws {
        let der = try TLSFixtures.der("self-signed-a")
        let trust = try makeTrust([try TLSFixtures.certificate(der: der)])
        let decision = await SystemTrustEvaluator(pinnedSHA256: []).evaluate(
            trust, host: "selfsigned.test")
        #expect(
            decision
                == .rejected(
                    ServerCertificateProblem(
                        host: "selfsigned.test", leafDER: der, sha256: Self.selfSignedA,
                        reason: "not trusted")))
    }

    @Test func emptyHostIsRejected() async throws {
        let trust = try makeTrust([try TLSFixtures.certificate("self-signed-a")])
        let decision = await SystemTrustEvaluator(pinnedSHA256: []).evaluate(trust, host: "")
        #expect(decision.problem?.reason == "name mismatch")
    }

    @Test func pinnedLeafIsTrusted() async throws {
        let trust = try makeTrust([try TLSFixtures.certificate("self-signed-a")])
        let evaluator = SystemTrustEvaluator(pinnedSHA256: [Self.selfSignedA])
        #expect(await evaluator.evaluate(trust, host: "selfsigned.test") == .trusted)
    }

    @Test func pinIsCheckedWhateverTheName() async throws {
        let trust = try makeTrust([try TLSFixtures.certificate("self-signed-a")])
        let evaluator = SystemTrustEvaluator(pinnedSHA256: [Self.selfSignedA])
        #expect(await evaluator.evaluate(trust, host: "elsewhere.test") == .trusted)
    }

    @Test func pinsAreReadInAnyCaseAndWithColons() async throws {
        let trust = try makeTrust([try TLSFixtures.certificate("self-signed-a")])
        let openSSLStyle = stride(from: 0, to: Self.selfSignedA.count, by: 2).map { offset in
            let start = Self.selfSignedA.index(Self.selfSignedA.startIndex, offsetBy: offset)
            return Self.selfSignedA[start..<Self.selfSignedA.index(start, offsetBy: 2)].uppercased()
        }.joined(separator: ":")
        let evaluator = SystemTrustEvaluator(pinnedSHA256: [openSSLStyle])
        #expect(await evaluator.evaluate(trust, host: "selfsigned.test") == .trusted)
    }

    @Test func changedPinnedCertificateIsRejected() async throws {
        let derB = try TLSFixtures.der("self-signed-b")
        let trust = try makeTrust([try TLSFixtures.certificate(der: derB)])
        let evaluator = SystemTrustEvaluator(pinnedSHA256: [Self.selfSignedA])
        let decision = await evaluator.evaluate(trust, host: "selfsigned.test")
        #expect(
            decision
                == .rejected(
                    ServerCertificateProblem(
                        host: "selfsigned.test", leafDER: derB, sha256: Self.selfSignedB,
                        reason: "not trusted")))
    }

    @Test func problemCarriesTheLeafHash() throws {
        let der = try TLSFixtures.der("self-signed-b")
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        #expect(hex == Self.selfSignedB)
    }

    private func makeTrust(_ certificates: [SecCertificate]) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificates as CFArray, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }
}

extension TrustDecision {
    var problem: ServerCertificateProblem? {
        if case .rejected(let problem) = self { problem } else { nil }
    }
}
