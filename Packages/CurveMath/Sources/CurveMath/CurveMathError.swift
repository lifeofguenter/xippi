/// Why XEdDSA or KeyConversion refused an input.
public enum CurveMathError: Error, Sendable, Equatable {
    /// A key that is not 32 bytes.
    case invalidKeyLength
    /// Signing input that is not 64 random bytes.
    case invalidRandomLength
    /// A sign bit other than 0 or 1.
    case invalidSignBit
    /// A public key that is not canonically encoded, not on the curve, or not of prime order.
    case invalidPublicKey
}
