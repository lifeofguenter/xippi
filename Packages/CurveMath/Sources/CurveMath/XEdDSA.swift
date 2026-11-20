import Foundation

/// XEdDSA: Ed25519-compatible signatures made and checked with X25519 keys, as Signal
/// specifies it (https://signal.org/docs/specifications/xeddsa/). Legacy OMEMO signs signed
/// pre-keys with its X25519 identity key this way.
public enum XEdDSA {
    /// hash1's prefix: 2^256 - 2, little-endian.
    private static let hash1Prefix: [UInt8] = [0xFE] + [UInt8](repeating: 0xFF, count: 31)

    /// Signs `message` with an X25519 private key (xeddsa_sign).
    ///
    /// The key is clamped as X25519 clamps it, so it signs for the public key X25519 derives.
    /// The signature verifies as Ed25519 against the Edwards form of that public key with sign
    /// bit 0 (`KeyConversion.edwardsPublic(fromMontgomery:signBit: 0)`).
    ///
    /// - Parameters:
    ///   - montgomeryPrivateKey: 32 bytes.
    ///   - random: 64 bytes from a secure random generator, Z in the specification.
    /// - Returns: 64 bytes, R || s.
    /// - Throws: `CurveMathError.invalidKeyLength` or `.invalidRandomLength`.
    public static func sign(
        message: Data, montgomeryPrivateKey: Data, random: Data
    ) throws -> Data {
        guard montgomeryPrivateKey.count == 32 else { throw CurveMathError.invalidKeyLength }
        guard random.count == 64 else { throw CurveMathError.invalidRandomLength }

        var k = Array(montgomeryPrivateKey)
        k[0] &= 248
        k[31] &= 127
        k[31] |= 64

        // calculate_key_pair: E = kB. If E's sign bit is set, a = -k mod L, so that A = aB = -E
        // has sign bit 0. The choice is made with a mask; the sign bit is never branched on.
        var publicKey = EdwardsPoint.multiplyBase(k).encoded()
        let signBit = publicKey[31] >> 7
        publicKey[31] &= 0x7F
        let a = Scalar.select(Scalar.negate(k), k, flag: signBit)

        let m = Array(message)
        let r = Scalar.reduce(sha512(hash1Prefix, a, m, Array(random)))
        let encodedR = EdwardsPoint.multiplyBase(r).encoded()
        let h = Scalar.reduce(sha512(encodedR, publicKey, m))
        let s = Scalar.multiplyAdd(h, a, r)
        return Data(encodedR + s)
    }

    /// Verifies `signature` over `message` against an X25519 public key (xeddsa_verify).
    ///
    /// Refuses a public key that is not below p, not on the curve or not of prime order, and a
    /// signature whose s is not below L. The top bit of the signature's last byte, which a
    /// signature made by `sign` always has clear, is read as the sign bit of the Edwards public
    /// key: libsignal's curve25519_sign, which Conversations, Monal and Dino use for legacy
    /// OMEMO, signs without negating the key and stores the sign bit there.
    public static func verify(signature: Data, message: Data, montgomeryPublicKey: Data) -> Bool {
        guard signature.count == 64, montgomeryPublicKey.count == 32 else { return false }
        var bytes = Array(signature)
        let signBit = bytes[63] >> 7
        bytes[63] &= 0x7F
        guard
            let (point, encoding) = EdwardsPoint.fromMontgomery(
                Array(montgomeryPublicKey), signBit: signBit)
        else {
            return false
        }
        return Ed25519.verify(
            r: Array(bytes[0..<32]),
            s: Array(bytes[32..<64]),
            publicKey: point,
            encodedPublicKey: encoding,
            message: Array(message)
        )
    }
}
