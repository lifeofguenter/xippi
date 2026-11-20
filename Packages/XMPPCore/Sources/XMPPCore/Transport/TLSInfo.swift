import CryptoKit
import Foundation

/// What a connection learned from its TLS session.
public struct TLSInfo: Sendable, Equatable {
    /// The server's certificates, DER encoded, leaf first.
    public var serverCertificateChain: [Data]
    /// The `tls-exporter` channel binding (RFC 9266): 32 bytes of TLS exporter output for the
    /// label "EXPORTER-Channel-Binding" and an empty context. Only on TLS 1.3, in both TLS
    /// modes; nil otherwise.
    public var exporterBinding: Data?

    public init(serverCertificateChain: [Data], exporterBinding: Data? = nil) {
        self.serverCertificateChain = serverCertificateChain
        self.exporterBinding = exporterBinding
    }

    /// The `tls-server-end-point` channel binding (RFC 5929 section 4.1): the hash of the leaf
    /// certificate's DER, with the hash function of the certificate's signature algorithm, where
    /// MD5 and SHA-1 become SHA-256.
    ///
    /// Empty when the binding is undefined: no certificate, a certificate that cannot be read,
    /// or a signature algorithm without exactly one hash function (Ed25519, Ed448). A SASL
    /// mechanism must not offer `-PLUS` with an empty binding.
    public func tlsServerEndPointBinding() -> Data {
        guard let leaf = serverCertificateChain.first,
            let hash = CertificateSignatureHash(certificateDER: leaf)
        else { return Data() }
        switch hash {
        case .sha256: return Data(SHA256.hash(data: leaf))
        case .sha384: return Data(SHA384.hash(data: leaf))
        case .sha512: return Data(SHA512.hash(data: leaf))
        }
    }
}

/// The hash `tls-server-end-point` uses for a certificate, from its outer `signatureAlgorithm`.
enum CertificateSignatureHash {
    case sha256, sha384, sha512

    init?(certificateDER der: Data) {
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm AlgorithmIdentifier, signature }
        // AlgorithmIdentifier ::= SEQUENCE { algorithm OBJECT IDENTIFIER, parameters ANY OPTIONAL }
        var reader = DERReader(der)
        guard var certificate = reader.read(tag: DERReader.sequence),
            certificate.read(tag: DERReader.sequence) != nil,
            var algorithm = certificate.read(tag: DERReader.sequence),
            let oid = algorithm.read(tag: DERReader.objectIdentifier)
        else { return nil }
        if oid.bytes == Self.rsassaPSS {
            self.init(pssParameters: algorithm)
        } else if let hash = Self.signatureAlgorithms[oid.bytes] {
            self = hash
        } else {
            return nil
        }
    }

    /// RSASSA-PSS-params (RFC 4055): `hashAlgorithm [0] AlgorithmIdentifier DEFAULT sha1`, the
    /// rest ignored.
    private init?(pssParameters algorithm: DERReader) {
        var algorithm = algorithm
        guard var parameters = algorithm.read(tag: DERReader.sequence) else { return nil }
        guard var explicit = parameters.read(tag: 0xA0) else {
            self = .sha256
            return
        }
        guard var hashAlgorithm = explicit.read(tag: DERReader.sequence),
            let oid = hashAlgorithm.read(tag: DERReader.objectIdentifier),
            let hash = Self.hashAlgorithms[oid.bytes]
        else { return nil }
        self = hash
    }

    /// Content bytes of the signature algorithm OIDs with a single hash.
    private static let signatureAlgorithms: [[UInt8]: CertificateSignatureHash] = [
        // md5WithRSAEncryption, sha1WithRSAEncryption 1.2.840.113549.1.1.4 and .5
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x04]: .sha256,
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05]: .sha256,
        // sha256, sha384, sha512WithRSAEncryption 1.2.840.113549.1.1.11 to .13
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]: .sha256,
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C]: .sha384,
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D]: .sha512,
        // ecdsa-with-SHA1 1.2.840.10045.4.1
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x01]: .sha256,
        // ecdsa-with-SHA256, SHA384, SHA512 1.2.840.10045.4.3.2 to .4
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]: .sha256,
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03]: .sha384,
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]: .sha512,
        // dsa-with-sha1 1.2.840.10040.4.3, dsa-with-sha256 2.16.840.1.101.3.4.3.2
        [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x03]: .sha256,
        [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x02]: .sha256,
    ]

    /// id-RSASSA-PSS 1.2.840.113549.1.1.10
    private static let rsassaPSS: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0A]

    /// Content bytes of the hash algorithm OIDs RSASSA-PSS names.
    private static let hashAlgorithms: [[UInt8]: CertificateSignatureHash] = [
        // id-sha1 1.3.14.3.2.26
        [0x2B, 0x0E, 0x03, 0x02, 0x1A]: .sha256,
        // id-sha256, id-sha384, id-sha512 2.16.840.1.101.3.4.2.1 to .3
        [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]: .sha256,
        [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02]: .sha384,
        [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03]: .sha512,
    ]
}

/// Reads DER elements one after another from a byte range, bounds checked. Only what a
/// certificate's signature algorithm needs: single-byte tags and definite lengths.
struct DERReader {
    static let sequence: UInt8 = 0x30
    static let objectIdentifier: UInt8 = 0x06

    private let storage: [UInt8]
    private var position: Int
    private let end: Int

    init(_ data: Data) {
        storage = [UInt8](data)
        position = 0
        end = storage.count
    }

    private init(storage: [UInt8], range: Range<Int>) {
        self.storage = storage
        position = range.lowerBound
        end = range.upperBound
    }

    /// The bytes not read yet.
    var bytes: [UInt8] { Array(storage[position..<end]) }

    /// Reads the next element if it has `tag`, returning a reader over its content.
    mutating func read(tag expected: UInt8) -> DERReader? {
        guard position < end, storage[position] == expected, expected & 0x1F != 0x1F else {
            return nil
        }
        var index = position + 1
        guard index < end else { return nil }
        let first = Int(storage[index])
        index += 1
        var length = 0
        if first < 0x80 {
            length = first
        } else {
            // Long form with up to four length bytes; 0x80 (indefinite) is not DER.
            let count = first & 0x7F
            guard (1...4).contains(count), end - index >= count else { return nil }
            for _ in 0..<count {
                length = length << 8 | Int(storage[index])
                index += 1
            }
        }
        guard length <= end - index else { return nil }
        let content = DERReader(storage: storage, range: index..<(index + length))
        position = index + length
        return content
    }
}
