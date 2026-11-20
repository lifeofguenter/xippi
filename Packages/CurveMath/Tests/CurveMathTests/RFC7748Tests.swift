import CryptoKit
import Foundation
import Testing

@testable import CurveMath

/// X25519 through our Montgomery ladder, against RFC 7748 and CryptoKit.
@Suite struct RFC7748Tests {
    struct Vector {
        let scalar: String
        let u: String
        let output: String
    }

    /// RFC 7748 section 5.2, X25519. The second u-coordinate has its top bit set, which X25519
    /// must ignore.
    static let vectors = [
        Vector(
            scalar: "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
            u: "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
            output: "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
        ),
        Vector(
            scalar: "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
            u: "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
            output: "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"
        ),
    ]

    static let basePoint = "0900000000000000000000000000000000000000000000000000000000000000"

    @Test func section52Vectors() throws {
        for vector in Self.vectors {
            let result = X25519.scalarMultiply(try bytes(vector.scalar), try bytes(vector.u))
            #expect(result.hex == vector.output)
        }
    }

    @Test func section52VectorsAgreeWithCryptoKit() throws {
        for vector in Self.vectors {
            let scalar = try bytes(vector.scalar)
            let u = try bytes(vector.u)
            let cryptoKit = try cryptoKitX25519(scalar: scalar, u: u)
            #expect(X25519.scalarMultiply(scalar, u) == cryptoKit)
            #expect(cryptoKit.hex == vector.output)
        }
    }

    /// Section 5.2: k and u start at 9; each round k becomes X25519(k, u) and u the old k.
    @Test(arguments: [
        (1, "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"),
        (1_000, "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"),
    ])
    func section52Iterations(rounds: Int, expected: String) throws {
        var k = try bytes(Self.basePoint)
        var u = k
        for _ in 0..<rounds {
            (k, u) = (X25519.scalarMultiply(k, u), k)
        }
        #expect(k.hex == expected)
    }

    /// Section 6.1.
    @Test func section61DiffieHellman() throws {
        let alicePrivate = try bytes(
            "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let bobPrivate = try bytes(
            "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let base = try bytes(Self.basePoint)

        let alicePublic = X25519.scalarMultiply(alicePrivate, base)
        let bobPublic = X25519.scalarMultiply(bobPrivate, base)
        #expect(
            alicePublic.hex == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        #expect(bobPublic.hex == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")

        let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
        #expect(X25519.scalarMultiply(alicePrivate, bobPublic).hex == shared)
        #expect(X25519.scalarMultiply(bobPrivate, alicePublic).hex == shared)
    }

    @Test func randomInputsAgreeWithCryptoKit() throws {
        var generator = SeededGenerator(seed: 7748)
        for _ in 0..<48 {
            let scalar = generator.bytes(32)
            let u = generator.bytes(32)
            #expect(
                X25519.scalarMultiply(scalar, u) == (try cryptoKitX25519(scalar: scalar, u: u)),
                "scalar \(scalar.hex), u \(u.hex)"
            )
        }
    }

    @Test func publicKeysAgreeWithCryptoKit() throws {
        var generator = SeededGenerator(seed: 7749)
        let base = try bytes(Self.basePoint)
        for _ in 0..<16 {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: generator.bytes(32))
            let ours = X25519.scalarMultiply(Array(key.rawRepresentation), base)
            #expect(ours == Array(key.publicKey.rawRepresentation))
        }
    }

    private func cryptoKitX25519(scalar: [UInt8], u: [UInt8]) throws -> [UInt8] {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: u)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.withUnsafeBytes { Array($0) }
    }
}
