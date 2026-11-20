import CryptoKit
import Foundation
import Testing

@testable import CurveMath

@Suite struct XEdDSATests {
    /// python-xeddsa signs with the same private key, message and random input: the signature
    /// must be identical, for keys whose Edwards form has either sign bit.
    @Test func pythonSignaturesMatchByteForByte() throws {
        let vectors = try PythonVectors.load()
        #expect(Set(vectors.signatures.map(\.edwardsSignBit)) == [0, 1])
        for (index, vector) in vectors.signatures.enumerated() {
            let signature = try XEdDSA.sign(
                message: try data(vector.message),
                montgomeryPrivateKey: try data(vector.privateKey),
                random: try data(vector.random)
            )
            #expect(signature.hex == vector.signature, "vector \(index)")
        }
    }

    @Test func pythonSignaturesVerify() throws {
        let vectors = try PythonVectors.load()
        for (index, vector) in vectors.signatures.enumerated() {
            let valid = XEdDSA.verify(
                signature: try data(vector.signature),
                message: try data(vector.message),
                montgomeryPublicKey: try data(vector.publicKey)
            )
            #expect(valid, "vector \(index)")
        }
    }

    /// libsignal (and with it Conversations, Monal and Dino) signs without negating the key and
    /// carries the Edwards sign bit in the top bit of the signature. Legacy OMEMO bundles are
    /// signed this way.
    @Test func libsignalSignaturesVerify() throws {
        let vectors = try PythonVectors.load()
        #expect(Set(vectors.libsignalSignatures.map(\.edwardsSignBit)) == [0, 1])
        for (index, vector) in vectors.libsignalSignatures.enumerated() {
            let valid = XEdDSA.verify(
                signature: try data(vector.signature),
                message: try data(vector.message),
                montgomeryPublicKey: try data(vector.publicKey)
            )
            #expect(valid, "vector \(index)")
        }
    }

    @Test func signatureVerifiesInCryptoKit() throws {
        var generator = SeededGenerator(seed: 15)
        var signBits: Set<UInt8> = []
        for length in [0, 1, 33, 64, 100, 500, 0, 7, 32, 1_000, 2, 3] {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: generator.bytes(32))
            let message = Data(generator.bytes(length))
            let signature = try XEdDSA.sign(
                message: message,
                montgomeryPrivateKey: key.rawRepresentation,
                random: Data(generator.bytes(64))
            )
            #expect(signature.count == 64)
            #expect(signature[signature.startIndex + 63] & 0x80 == 0)

            let edwards = try KeyConversion.edwardsPublic(
                fromMontgomery: key.publicKey.rawRepresentation, signBit: 0)
            let cryptoKit = try Curve25519.Signing.PublicKey(rawRepresentation: edwards)
            #expect(cryptoKit.isValidSignature(signature, for: message))
            #expect(
                XEdDSA.verify(
                    signature: signature,
                    message: message,
                    montgomeryPublicKey: key.publicKey.rawRepresentation
                ))

            let edwardsOfPrivate = EdwardsPoint.multiplyBase(clamped(key.rawRepresentation))
            signBits.insert(edwardsOfPrivate.encoded()[31] >> 7)
        }
        #expect(signBits == [0, 1])
    }

    @Test func flippedBitFails() throws {
        var generator = SeededGenerator(seed: 16)
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: generator.bytes(32))
        let publicKey = key.publicKey.rawRepresentation
        let message = Data("signed pre-key".utf8)
        let signature = try XEdDSA.sign(
            message: message, montgomeryPrivateKey: key.rawRepresentation,
            random: Data(generator.bytes(64)))
        #expect(
            XEdDSA.verify(signature: signature, message: message, montgomeryPublicKey: publicKey))

        for bit in [0, 7, 128, 255, 256, 300, 503, 511] {
            var altered = signature
            altered[altered.startIndex + bit / 8] ^= 1 << UInt8(bit % 8)
            #expect(
                !XEdDSA.verify(
                    signature: altered, message: message, montgomeryPublicKey: publicKey),
                "bit \(bit)")
        }
        var alteredMessage = message
        alteredMessage[alteredMessage.startIndex] ^= 1
        #expect(
            !XEdDSA.verify(
                signature: signature, message: alteredMessage, montgomeryPublicKey: publicKey)
        )
        var alteredKey = publicKey
        alteredKey[alteredKey.startIndex] ^= 1
        #expect(
            !XEdDSA.verify(signature: signature, message: message, montgomeryPublicKey: alteredKey))
    }

    @Test func sameRandomGivesSameSignatureAndOtherRandomDoesNot() throws {
        var generator = SeededGenerator(seed: 17)
        let privateKey = Data(generator.bytes(32))
        let random = Data(generator.bytes(64))
        let message = Data("message".utf8)
        let first = try XEdDSA.sign(
            message: message, montgomeryPrivateKey: privateKey, random: random)
        let second = try XEdDSA.sign(
            message: message, montgomeryPrivateKey: privateKey, random: random)
        let third = try XEdDSA.sign(
            message: message, montgomeryPrivateKey: privateKey, random: Data(generator.bytes(64)))
        #expect(first == second)
        #expect(first != third)
    }

    /// The scalar s + L verifies the same equation; only s < L is accepted.
    @Test func nonCanonicalScalarIsRejected() throws {
        let vector = try #require(try PythonVectors.load().signatures.first)
        let signature = try bytes(vector.signature)
        let s = Array(signature[32...])
        let malleated = Array(signature[..<32]) + addLittleEndian(s, try bytes(groupOrderHex))
        #expect(malleated[63] & 0x80 == 0)
        #expect(
            !XEdDSA.verify(
                signature: Data(malleated),
                message: try data(vector.message),
                montgomeryPublicKey: try data(vector.publicKey)
            ))
    }

    /// u + p names the same point as u; only the canonical encoding is accepted.
    @Test func nonCanonicalPublicKeyIsRejected() throws {
        let vector = try #require(try PythonVectors.load().signatures.first)
        let publicKey = try bytes(vector.publicKey)
        let signature = try data(vector.signature)
        let message = try data(vector.message)

        var topBitSet = publicKey
        topBitSet[31] |= 0x80
        #expect(
            !XEdDSA.verify(
                signature: signature, message: message, montgomeryPublicKey: Data(topBitSet)))

        // p + 9 encodes the X25519 base point's u-coordinate, 9, without being reduced.
        let pPlusNine = addLittleEndian(
            try bytes(fieldPrimeHex), [9] + [UInt8](repeating: 0, count: 31))
        #expect(
            !XEdDSA.verify(
                signature: signature, message: message, montgomeryPublicKey: Data(pPlusNine)))
    }

    /// Small-order u-coordinates (0, 1 and p - 1) and a point on the twist name no usable key.
    @Test func degeneratePublicKeysAreRejected() throws {
        let vector = try #require(try PythonVectors.load().signatures.first)
        let signature = try data(vector.signature)
        let message = try data(vector.message)
        let keys = [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
            "0200000000000000000000000000000000000000000000000000000000000000",
        ]
        for key in keys {
            #expect(
                !XEdDSA.verify(
                    signature: signature, message: message, montgomeryPublicKey: try data(key)),
                "\(key)")
        }
    }

    @Test func wrongLengthsThrowOrFail() throws {
        let key = Data(repeating: 7, count: 32)
        let random = Data(repeating: 9, count: 64)
        #expect(throws: CurveMathError.invalidKeyLength) {
            try XEdDSA.sign(message: Data(), montgomeryPrivateKey: key.dropLast(), random: random)
        }
        #expect(throws: CurveMathError.invalidKeyLength) {
            try XEdDSA.sign(message: Data(), montgomeryPrivateKey: key + [0], random: random)
        }
        #expect(throws: CurveMathError.invalidRandomLength) {
            try XEdDSA.sign(message: Data(), montgomeryPrivateKey: key, random: random.dropLast())
        }

        let vector = try #require(try PythonVectors.load().signatures.first)
        let signature = try data(vector.signature)
        let message = try data(vector.message)
        let publicKey = try data(vector.publicKey)
        #expect(
            !XEdDSA.verify(
                signature: signature.dropLast(), message: message, montgomeryPublicKey: publicKey))
        #expect(
            !XEdDSA.verify(
                signature: signature + [0], message: message, montgomeryPublicKey: publicKey))
        #expect(
            !XEdDSA.verify(
                signature: signature, message: message, montgomeryPublicKey: publicKey.dropLast()))
    }

    /// Inputs may be slices whose indices do not start at zero.
    @Test func dataSlicesWork() throws {
        let vector = try #require(try PythonVectors.load().signatures.first)
        let padded = Data([0xAA]) + (try data(vector.privateKey))
        let paddedRandom = Data([0xAA, 0xBB]) + (try data(vector.random))
        let signature = try XEdDSA.sign(
            message: try data(vector.message),
            montgomeryPrivateKey: padded.dropFirst(),
            random: paddedRandom.dropFirst(2)
        )
        #expect(signature.hex == vector.signature)
        let paddedSignature = Data([0xAA]) + signature
        let paddedKey = Data([0xAA]) + (try data(vector.publicKey))
        #expect(
            XEdDSA.verify(
                signature: paddedSignature.dropFirst(),
                message: try data(vector.message),
                montgomeryPublicKey: paddedKey.dropFirst()
            ))
    }

    private func clamped(_ key: Data) -> [UInt8] {
        var scalar = Array(key)
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        return scalar
    }
}
