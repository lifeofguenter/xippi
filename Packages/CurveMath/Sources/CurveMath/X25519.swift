// The X25519 function of RFC 7748.
//
// Ported from the ref10 implementation of crypto_scalarmult in SUPERCOP (public domain):
// scalarmult.c and the generated montgomery.h, written anew in Swift.
//
// The app does X25519 with CryptoKit. This ladder exists so that RFC 7748's vectors and
// CryptoKit check the field arithmetic that XEdDSA and the key conversions stand on.
//
// Constant time: the ladder runs 255 identical steps whatever the scalar, and each scalar bit
// only reaches the conditional swaps as a mask.

enum X25519 {
    /// X25519(k, u). The scalar is clamped and the top bit of u ignored, as RFC 7748 section 5
    /// says.
    static func scalarMultiply(_ scalar: [UInt8], _ u: [UInt8]) -> [UInt8] {
        var k = scalar
        k[0] &= 248
        k[31] &= 127
        k[31] |= 64

        let x1 = FieldElement(bytes: u)
        var x2 = FieldElement.one
        var z2 = FieldElement.zero
        var x3 = x1
        var z3 = FieldElement.one
        var swap: Int64 = 0
        for position in stride(from: 254, through: 0, by: -1) {
            let bit = Int64((k[position >> 3] &>> UInt8(position & 7)) & 1)
            swap ^= bit
            FieldElement.conditionalSwap(&x2, &x3, flag: swap)
            FieldElement.conditionalSwap(&z2, &z3, flag: swap)
            swap = bit

            let a = x2 + z2
            let aa = a.squared()
            let b = x2 - z2
            let bb = b.squared()
            let e = aa - bb
            let c = x3 + z3
            let d = x3 - z3
            let da = d * a
            let cb = c * b
            x3 = (da + cb).squared()
            z3 = x1 * (da - cb).squared()
            x2 = aa * bb
            z2 = e * (bb + e.times121666())
        }
        FieldElement.conditionalSwap(&x2, &x3, flag: swap)
        FieldElement.conditionalSwap(&z2, &z3, flag: swap)
        return (x2 * z2.inverted()).bytes
    }
}
