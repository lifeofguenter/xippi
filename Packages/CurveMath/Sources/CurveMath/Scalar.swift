// Arithmetic modulo L = 2^252 + 27742317777372353535851937790883648493, the order of the
// edwards25519 base point.
//
// Ported from TweetNaCl (public domain): modL, reduce and the multiply-add inside crypto_sign,
// written anew in Swift. Scalars are 32-byte little-endian arrays.
//
// Constant time: loops have fixed bounds and the values only ever pass through arithmetic, never
// through a branch or an index.

enum Scalar {
    /// L, little-endian.
    static let order: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE,
        0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x10,
    ]

    /// L - 1, which is -1 mod L.
    private static let minusOne: [UInt8] = [0xEC] + order.dropFirst()

    private static let zero = [UInt8](repeating: 0, count: 32)

    private static let orderLimbs: [Int64] = order.map { Int64($0) }

    /// x mod L for a 64-byte little-endian x, such as a SHA-512 digest (TweetNaCl reduce).
    static func reduce(_ wide: [UInt8]) -> [UInt8] {
        var limbs = [Int64](repeating: 0, count: 64)
        for index in 0..<min(wide.count, 64) {
            limbs[index] = Int64(wide[index])
        }
        return modL(&limbs)
    }

    /// (a b + c) mod L for 32-byte a, b and c.
    static func multiplyAdd(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
        var limbs = [Int64](repeating: 0, count: 64)
        for index in 0..<32 {
            limbs[index] = Int64(c[index])
        }
        for i in 0..<32 {
            let ai = Int64(a[i])
            for j in 0..<32 {
                limbs[i + j] &+= ai &* Int64(b[j])
            }
        }
        return modL(&limbs)
    }

    /// -a mod L.
    static func negate(_ a: [UInt8]) -> [UInt8] {
        multiplyAdd(minusOne, a, zero)
    }

    /// a when flag is 1, b when flag is 0, chosen with a mask. flag must be 0 or 1.
    static func select(_ a: [UInt8], _ b: [UInt8], flag: UInt8) -> [UInt8] {
        let mask = 0 &- flag
        return (0..<32).map { b[$0] ^ ((a[$0] ^ b[$0]) & mask) }
    }

    /// Whether s < L, from the borrow of s - L.
    static func isCanonical(_ s: [UInt8]) -> Bool {
        guard s.count == 32 else { return false }
        var borrow: Int64 = 0
        for index in 0..<32 {
            borrow = ((Int64(s[index]) &- Int64(order[index]) &- borrow) &>> 8) & 1
        }
        return borrow == 1
    }

    /// Reduces 64 signed limbs of 8 bits, x = sum limbs[i] 2^(8 i), to 32 bytes below L
    /// (TweetNaCl modL).
    ///
    /// The top 32 limbs are folded in from the top down: 2^(8 i) is replaced by
    /// 2^(8 i) - 16 L 2^(8 (i - 32)), which removes it and subtracts a multiple of L's low
    /// 16 bytes further down. Then the multiple of L above 2^252 is subtracted and one L is
    /// added back if that went below zero.
    private static func modL(_ limbs: inout [Int64]) -> [UInt8] {
        for i in stride(from: 63, through: 32, by: -1) {
            let top = limbs[i]
            var carry: Int64 = 0
            var j = i - 32
            while j < i - 12 {
                let delta = carry &- 16 &* top &* orderLimbs[j - (i - 32)]
                limbs[j] &+= delta
                carry = (limbs[j] &+ 128) &>> 8
                limbs[j] &-= carry &<< 8
                j += 1
            }
            limbs[j] &+= carry
            limbs[i] = 0
        }

        let multiple = limbs[31] &>> 4
        var carry: Int64 = 0
        for j in 0..<32 {
            limbs[j] &+= carry &- multiple &* orderLimbs[j]
            carry = limbs[j] &>> 8
            limbs[j] &= 255
        }
        for j in 0..<32 {
            limbs[j] &-= carry &* orderLimbs[j]
        }

        var result = [UInt8](repeating: 0, count: 32)
        for index in 0..<32 {
            let carry = limbs[index] &>> 8
            limbs[index + 1] &+= carry
            result[index] = UInt8(truncatingIfNeeded: limbs[index])
        }
        return result
    }
}
