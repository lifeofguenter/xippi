import CryptoKit
import Foundation
import Testing

@testable import CurveMath

@Suite struct ConversionTests {
    /// RFC 8032 section 7.1, TEST 1.
    static let rfcSeed = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    static let rfcPublicKey = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"

    /// The X25519 key of an Ed25519 key pair: the public key converted with the birational map
    /// equals X25519 of the clamped first half of SHA-512(seed).
    @Test func rfc8032PublicKeyMatchesX25519OfClampedSeedHash() throws {
        let seed = try data(Self.rfcSeed)
        let converted = try KeyConversion.montgomeryPublic(fromEdwards: try data(Self.rfcPublicKey))

        var clamped = Array(SHA512.hash(data: seed).prefix(32))
        clamped[0] &= 248
        clamped[31] &= 127
        clamped[31] |= 64
        let cryptoKit = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clamped)
        #expect(converted == cryptoKit.publicKey.rawRepresentation)

        let base = [9] + [UInt8](repeating: 0, count: 31)
        #expect(Array(converted) == X25519.scalarMultiply(clamped, base))
        #expect(KeyConversion.montgomeryPrivate(fromEd25519Seed: seed) == Data(clamped))
    }

    @Test func pythonSeedConversions() throws {
        for (index, vector) in try PythonVectors.load().seedConversions.enumerated() {
            let privateKey = KeyConversion.montgomeryPrivate(fromEd25519Seed: try data(vector.seed))
            #expect(privateKey.hex == vector.montgomeryPrivate, "vector \(index)")
            let publicKey = try KeyConversion.montgomeryPublic(
                fromEdwards: try data(vector.edwardsPublic))
            #expect(publicKey.hex == vector.montgomeryPublic, "vector \(index)")
        }
    }

    @Test func pythonMontgomeryToEdwards() throws {
        for (index, vector) in try PythonVectors.load().montgomeryToEdwards.enumerated() {
            let edwards = try KeyConversion.edwardsPublic(
                fromMontgomery: try data(vector.montgomeryPublic), signBit: vector.signBit)
            #expect(edwards.hex == vector.edwardsPublic, "vector \(index)")
        }
    }

    /// CryptoKit Ed25519 key pairs: the converted public key is the X25519 public key of the
    /// converted private key, and converting back with the original sign bit restores the key.
    @Test func cryptoKitEd25519KeysConvert() throws {
        var generator = SeededGenerator(seed: 25519)
        for _ in 0..<12 {
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: generator.bytes(32))
            let edwardsPublic = signing.publicKey.rawRepresentation
            let montgomeryPublic = try KeyConversion.montgomeryPublic(fromEdwards: edwardsPublic)
            let agreement = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: KeyConversion.montgomeryPrivate(
                    fromEd25519Seed: signing.rawRepresentation))
            #expect(montgomeryPublic == agreement.publicKey.rawRepresentation)

            let signBit = edwardsPublic[edwardsPublic.startIndex + 31] >> 7
            let back = try KeyConversion.edwardsPublic(
                fromMontgomery: montgomeryPublic, signBit: signBit)
            #expect(back == edwardsPublic)
        }
    }

    @Test func cryptoKitX25519KeysRoundTrip() throws {
        var generator = SeededGenerator(seed: 25520)
        for _ in 0..<12 {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: generator.bytes(32))
            let montgomery = key.publicKey.rawRepresentation
            for signBit: UInt8 in [0, 1] {
                let edwards = try KeyConversion.edwardsPublic(
                    fromMontgomery: montgomery, signBit: signBit)
                #expect(edwards[edwards.startIndex + 31] >> 7 == signBit)
                #expect(try KeyConversion.montgomeryPublic(fromEdwards: edwards) == montgomery)
                #expect((try? Curve25519.Signing.PublicKey(rawRepresentation: edwards)) != nil)
            }
        }
    }

    @Test func wrongLengthsAndSignBitsThrow() throws {
        let edwards = try data(Self.rfcPublicKey)
        let montgomery = try KeyConversion.montgomeryPublic(fromEdwards: edwards)
        #expect(throws: CurveMathError.invalidKeyLength) {
            try KeyConversion.montgomeryPublic(fromEdwards: edwards.dropLast())
        }
        #expect(throws: CurveMathError.invalidKeyLength) {
            try KeyConversion.montgomeryPublic(fromEdwards: edwards + [0])
        }
        #expect(throws: CurveMathError.invalidKeyLength) {
            try KeyConversion.edwardsPublic(fromMontgomery: montgomery.dropLast(), signBit: 0)
        }
        #expect(throws: CurveMathError.invalidSignBit) {
            try KeyConversion.edwardsPublic(fromMontgomery: montgomery, signBit: 2)
        }
        #expect(throws: CurveMathError.invalidSignBit) {
            try KeyConversion.edwardsPublic(fromMontgomery: montgomery, signBit: 0x80)
        }
    }

    /// Encodings that are not a key of prime order on edwards25519.
    @Test(arguments: [
        // Identity.
        "0100000000000000000000000000000000000000000000000000000000000000",
        // (0, -1), order 2.
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        // A point of order 8.
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
        // The base point plus a point of order 8.
        "98519eadf35b995233b51b5cd23e9cc5a28b639b5a4af0ec903cb960d81b7819",
        // y = 2 is not on the curve.
        "0200000000000000000000000000000000000000000000000000000000000000",
        // y = p + 3, an unreduced encoding of y = 3.
        "f0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        // x = 0 with the sign bit set.
        "0100000000000000000000000000000000000000000000000000000000000080",
    ])
    func invalidEdwardsKeysThrow(key: String) throws {
        #expect(throws: CurveMathError.invalidPublicKey) {
            try KeyConversion.montgomeryPublic(fromEdwards: try data(key))
        }
    }

    /// u-coordinates that are not the key of a prime-order point.
    @Test(arguments: [
        // 0, 1 and p - 1: small order.
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        // A point of order 8.
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        // The base point plus a point of order 8.
        "bb72312170e8156f7a836313f85bee9b1fdce926ba9804a29e8d137ec67f2533",
        // u = 2 lies on the twist.
        "0200000000000000000000000000000000000000000000000000000000000000",
        // p + 9, an unreduced encoding of the base point's u = 9.
        "f6ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        // u = 9 with the top bit set.
        "0900000000000000000000000000000000000000000000000000000000000080",
    ])
    func invalidMontgomeryKeysThrow(key: String) throws {
        for signBit: UInt8 in [0, 1] {
            #expect(throws: CurveMathError.invalidPublicKey) {
                try KeyConversion.edwardsPublic(fromMontgomery: try data(key), signBit: signBit)
            }
        }
    }

    @Test func baseConvertsBothWays() throws {
        let edwardsBase = try data(
            "5866666666666666666666666666666666666666666666666666666666666666")
        let montgomeryBase = try data(
            "0900000000000000000000000000000000000000000000000000000000000000")
        #expect(try KeyConversion.montgomeryPublic(fromEdwards: edwardsBase) == montgomeryBase)
        #expect(
            try KeyConversion.edwardsPublic(fromMontgomery: montgomeryBase, signBit: 0)
                == edwardsBase)
    }
}
