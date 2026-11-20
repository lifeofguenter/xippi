import Foundation

/// Conversions between Ed25519 keys and X25519 keys. OMEMO 2 publishes Ed25519 identity keys
/// and needs their X25519 form for X3DH; legacy OMEMO publishes X25519 identity keys.
public enum KeyConversion {
    /// The X25519 public key of an Ed25519 public key: u = (1 + y) / (1 - y).
    ///
    /// - Throws: `CurveMathError.invalidKeyLength` unless 32 bytes; `.invalidPublicKey` for an
    ///   encoding that is not canonical, a point that is not on the curve, or one that is not of
    ///   prime order.
    public static func montgomeryPublic(fromEdwards edwardsPublicKey: Data) throws -> Data {
        guard edwardsPublicKey.count == 32 else { throw CurveMathError.invalidKeyLength }
        guard let point = EdwardsPoint.decode(Array(edwardsPublicKey)), point.hasPrimeOrder else {
            throw CurveMathError.invalidPublicKey
        }
        // decode returns Z = 1, so point.y is the affine y; y = 1 is the identity, refused above.
        let u = (FieldElement.one + point.y) * (FieldElement.one - point.y).inverted()
        return Data(u.bytes)
    }

    /// The Ed25519 public key of an X25519 public key: y = (u - 1) / (u + 1), with the sign bit
    /// given, since u does not determine it.
    ///
    /// - Throws: `CurveMathError.invalidKeyLength` unless 32 bytes; `.invalidSignBit` unless the
    ///   sign bit is 0 or 1; `.invalidPublicKey` for u at or above p (top bit included), or a u
    ///   whose point is not on edwards25519 or not of prime order.
    public static func edwardsPublic(
        fromMontgomery montgomeryPublicKey: Data, signBit: UInt8
    ) throws -> Data {
        guard montgomeryPublicKey.count == 32 else { throw CurveMathError.invalidKeyLength }
        guard signBit <= 1 else { throw CurveMathError.invalidSignBit }
        guard
            let (_, encoding) = EdwardsPoint.fromMontgomery(
                Array(montgomeryPublicKey), signBit: signBit)
        else {
            throw CurveMathError.invalidPublicKey
        }
        return Data(encoding)
    }

    /// The X25519 private key of an Ed25519 seed: the first half of SHA-512(seed), clamped. Its
    /// X25519 public key is `montgomeryPublic(fromEdwards:)` of the seed's Ed25519 public key.
    /// A seed is 32 bytes; other lengths are hashed as given.
    public static func montgomeryPrivate(fromEd25519Seed seed: Data) -> Data {
        Data(Ed25519.expand(seed: Array(seed)).scalar)
    }
}
