import CryptoKit

/// Ed25519 (RFC 8032) on this module's arithmetic. The app signs and verifies Ed25519 with
/// CryptoKit; this exists so the RFC 8032 vectors exercise the Edwards code, and its
/// verification equation is the one XEdDSA uses.
enum Ed25519 {
    /// The clamped secret scalar and the nonce prefix: the two halves of SHA-512(seed).
    static func expand(seed: [UInt8]) -> (scalar: [UInt8], prefix: [UInt8]) {
        let digest = sha512(seed)
        var scalar = Array(digest[0..<32])
        scalar[0] &= 248
        scalar[31] &= 127
        scalar[31] |= 64
        return (scalar, Array(digest[32..<64]))
    }

    static func publicKey(seed: [UInt8]) -> [UInt8] {
        EdwardsPoint.multiplyBase(expand(seed: seed).scalar).encoded()
    }

    /// RFC 8032 section 5.1.6.
    static func sign(message: [UInt8], seed: [UInt8]) -> [UInt8] {
        let (scalar, prefix) = expand(seed: seed)
        let publicKey = EdwardsPoint.multiplyBase(scalar).encoded()
        let r = Scalar.reduce(sha512(prefix, message))
        let encodedR = EdwardsPoint.multiplyBase(r).encoded()
        let h = Scalar.reduce(sha512(encodedR, publicKey, message))
        return encodedR + Scalar.multiplyAdd(h, scalar, r)
    }

    /// RFC 8032 section 5.1.7, without the cofactor.
    static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count == 64, let point = EdwardsPoint.decode(publicKey) else {
            return false
        }
        return verify(
            r: Array(signature[0..<32]),
            s: Array(signature[32..<64]),
            publicKey: point,
            encodedPublicKey: publicKey,
            message: message
        )
    }

    /// Whether s B = R + h A with h = SHA-512(R || A || M) mod L, compared as encodings, and
    /// s < L. All inputs are public.
    static func verify(
        r: [UInt8], s: [UInt8], publicKey: EdwardsPoint, encodedPublicKey: [UInt8],
        message: [UInt8]
    ) -> Bool {
        guard Scalar.isCanonical(s) else { return false }
        let h = Scalar.reduce(sha512(r, encodedPublicKey, message))
        let sB = EdwardsPoint.multiplyBase(s)
        let hMinusA = EdwardsPoint.multiply(h, publicKey.negated())
        return (sB + hMinusA.cached).extended.encoded() == r
    }
}

/// SHA-512 of the concatenated parts.
func sha512(_ parts: [UInt8]...) -> [UInt8] {
    var hasher = SHA512()
    for part in parts {
        hasher.update(data: part)
    }
    return Array(hasher.finalize())
}
