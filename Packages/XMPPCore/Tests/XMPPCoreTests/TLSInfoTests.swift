import Foundation
import Security
import Testing

@testable import XMPPCore

// The fixture certificates in Fixtures/tls are self-signed and were made once with openssl;
// their keys were thrown away. Each expected hash below is
// `openssl x509 -in <file> -noout -fingerprint -<hash>` with the colons removed, where <hash> is
// the one RFC 5929 section 4.1 picks for the certificate's signature algorithm.
//
//   ecdsa-sha256    openssl req -x509 -sha256, P-256 key            -> SHA-256
//   ecdsa-sha384    openssl req -x509 -sha384, P-384 key            -> SHA-384
//   rsa-sha1        openssl req -x509 -sha1, RSA 2048 key           -> SHA-256 (SHA-1 is upgraded)
//   rsa-pss-sha512  openssl req -x509 -sha512 -sigopt rsa_padding_mode:pss
//                   -sigopt rsa_pss_saltlen:64 -sigopt rsa_mgf1_md:sha512   -> SHA-512
//   rsa-pss-sha1    openssl req -x509 -sha1 -sigopt rsa_padding_mode:pss
//                   -sigopt rsa_pss_saltlen:20; every PSS parameter is the default, so DER
//                   leaves `hashAlgorithm` out and the SHA-1 default applies -> SHA-256
//   ed25519         openssl req -x509, Ed25519 key                  -> no single hash, undefined
//   self-signed-a/b openssl req -x509 -sha256, P-256 key, SAN selfsigned.test (TrustEvaluatorTests).
//                   Valid for 100 years, so they cannot expire under the tests. Apple therefore
//                   rejects them for an over-long validity (errSecCertificateValidityPeriodTooLong)
//                   as well as for the untrusted root; both are "not trusted". The root case on
//                   its own is `chainFromTheTestCAIsRejectedWithoutExtraAnchors`.

@Suite struct TLSInfoTests {
    @Test(arguments: [
        ("ecdsa-sha256", "D6EC64350688A14860C057E6C6B0D866576A1C812738189F2644B4E7D92EF3DA"),
        (
            "ecdsa-sha384",
            "51D1DDC36B4FA9D90CD49B8D44A941EFC54A5BD13FF28D57F3599BC37402A122CF0ED507D5F657A22C49482997B7038A"
        ),
        ("rsa-sha1", "13DC63C5559A5FD37EB3D59F6BE52DEF2EC6B098B10D110C8CDA0BC3F406FD00"),
        ("rsa-pss-sha1", "576C424E6B7290FECF4EB7ED0AA396D99C7A5F2760FA67F7D839AD6265AFA604"),
        (
            "rsa-pss-sha512",
            "5B7C4CEEA87AC9226664140FFD0FA8735891A71110C345B1D1F249F36B05C57276DAAD2DDFA4D99BBE4AEDF4FE386F34E05A9B466854FC72E7F2BA958A096348"
        ),
    ])
    func tlsServerEndPointMatchesOpenSSL(fixture: String, expectedHex: String) throws {
        let info = TLSInfo(serverCertificateChain: [try TLSFixtures.der(fixture)])
        #expect(info.tlsServerEndPointBinding().hexUppercased == expectedHex)
    }

    @Test func onlyTheLeafIsHashed() throws {
        let leaf = try TLSFixtures.der("ecdsa-sha256")
        let other = try TLSFixtures.der("ecdsa-sha384")
        #expect(
            TLSInfo(serverCertificateChain: [leaf, other]).tlsServerEndPointBinding()
                == TLSInfo(serverCertificateChain: [leaf]).tlsServerEndPointBinding())
    }

    @Test func ed25519HasNoBinding() throws {
        #expect(
            TLSInfo(serverCertificateChain: [try TLSFixtures.der("ed25519")])
                .tlsServerEndPointBinding().isEmpty)
    }

    @Test func exporterBindingIsOnlyWhatTheConnectionProvides() {
        #expect(TLSInfo(serverCertificateChain: []).exporterBinding == nil)
        let info = TLSInfo(
            serverCertificateChain: [], exporterBinding: Data(repeating: 7, count: 32))
        #expect(info.exporterBinding == Data(repeating: 7, count: 32))
        #expect(
            ChannelBinding.tlsExporter(info)
                == ChannelBinding(type: "tls-exporter", data: Data(repeating: 7, count: 32)))
        #expect(ChannelBinding.tlsExporter(TLSInfo(serverCertificateChain: [])) == nil)
        #expect(
            ChannelBinding.tlsExporter(TLSInfo(serverCertificateChain: [], exporterBinding: Data()))
                == nil)
    }

    @Test func emptyChainHasNoBinding() {
        #expect(TLSInfo(serverCertificateChain: []).tlsServerEndPointBinding().isEmpty)
    }

    @Test func malformedCertificateHasNoBinding() throws {
        let der = try TLSFixtures.der("rsa-pss-sha512")
        for length in 0..<der.count {
            #expect(
                TLSInfo(serverCertificateChain: [der.prefix(length)]).tlsServerEndPointBinding()
                    .isEmpty)
        }
        #expect(
            TLSInfo(serverCertificateChain: [Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])])
                .tlsServerEndPointBinding().isEmpty)
        #expect(
            TLSInfo(serverCertificateChain: [Data([0x30, 0x80, 0x00, 0x00])])
                .tlsServerEndPointBinding().isEmpty)
        #expect(
            TLSInfo(serverCertificateChain: [Data(repeating: 0x30, count: 64)])
                .tlsServerEndPointBinding().isEmpty)
    }
}

/// Fixture certificates bundled with the tests, and the test CA from `make certs`.
enum TLSFixtures {
    struct Missing: Error {
        let name: String
    }

    /// The DER bytes of `Fixtures/tls/<name>.pem`.
    static func der(_ name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "pem", subdirectory: "Fixtures/tls")
        else { throw Missing(name: name) }
        return try derFromPEM(at: url)
    }

    static func certificate(_ name: String) throws -> SecCertificate {
        try certificate(der: der(name))
    }

    static func certificate(der: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Missing(name: "certificate")
        }
        return certificate
    }

    static func derFromPEM(at url: URL) throws -> Data {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else {
            throw Missing(name: url.lastPathComponent)
        }
        return der
    }

    /// `dev/certs` in the repository, found by walking up from this file.
    static let devCerts: URL? = {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()
        while directory.path() != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "dev/make-certs.sh").path())
            {
                return directory.appending(path: "dev/certs")
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    /// Whether `make certs` has written the test CA and the server certificate it issued.
    static var testCAAvailable: Bool {
        guard let devCerts else { return false }
        return ["test-ca.pem", "server.pem"].allSatisfy {
            FileManager.default.fileExists(atPath: devCerts.appending(path: $0).path())
        }
    }

    /// A certificate from `dev/certs` (`test-ca.pem` or `server.pem`).
    static func devCertificate(_ file: String) throws -> SecCertificate {
        guard let devCerts else { throw Missing(name: file) }
        return try certificate(der: derFromPEM(at: devCerts.appending(path: file)))
    }
}

extension Data {
    var hexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
