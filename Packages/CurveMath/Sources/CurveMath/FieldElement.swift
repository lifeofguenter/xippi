// Arithmetic in GF(p), p = 2^255 - 19.
//
// Ported from the ref10 implementation of Ed25519 in SUPERCOP (public domain): fe_*.c,
// pow225521.h, pow22523.h, d.h, d2.h and sqrtm1.h. The limb layout, carry chains, exponent
// chains and bounds are ref10's; the code is written anew in Swift.
//
// An element is v0 + 2^26 v1 + 2^51 v2 + 2^77 v3 + 2^102 v4 + 2^128 v5 + 2^153 v6 + 2^179 v7
// + 2^204 v8 + 2^230 v9: ten signed limbs of alternately 26 and 25 bits (radix 2^25.5). ref10
// keeps limbs in Int32 and widens to Int64 for products; here they are stored as Int64, which
// changes no result.
//
// Constant time: no operation branches on an element's value or uses it as an index.
// Selection goes through masks (conditionalMove, conditionalSwap). All arithmetic uses the
// wrapping operators, so the compiler emits no overflow checks; ref10's bounds guarantee that
// nothing wraps.

struct FieldElement: Sendable {
    var v0: Int64
    var v1: Int64
    var v2: Int64
    var v3: Int64
    var v4: Int64
    var v5: Int64
    var v6: Int64
    var v7: Int64
    var v8: Int64
    var v9: Int64

    init(
        _ v0: Int64, _ v1: Int64, _ v2: Int64, _ v3: Int64, _ v4: Int64,
        _ v5: Int64, _ v6: Int64, _ v7: Int64, _ v8: Int64, _ v9: Int64
    ) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
        self.v3 = v3
        self.v4 = v4
        self.v5 = v5
        self.v6 = v6
        self.v7 = v7
        self.v8 = v8
        self.v9 = v9
    }

    static let zero = FieldElement(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    static let one = FieldElement(1, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// d = -121665/121666, the constant of edwards25519 (ref10 d.h).
    static let d = FieldElement(
        -10_913_610, 13_857_413, -15_372_611, 6_949_391, 114_729,
        -8_787_816, -6_275_908, -3_247_719, -18_696_448, -12_055_116)

    /// 2d (ref10 d2.h).
    static let d2 = FieldElement(
        -21_827_239, -5_839_606, -30_745_221, 13_898_782, 229_458,
        15_978_800, -12_551_817, -6_495_438, 29_715_968, 9_444_199)

    /// A square root of -1 (ref10 sqrtm1.h).
    static let sqrtMinusOne = FieldElement(
        -32_595_792, -7_943_725, 9_377_950, 3_500_415, 12_389_472,
        -272_473, -25_146_209, -2_005_654, 326_686, 11_406_482)

    /// Reads 32 little-endian bytes (ref10 fe_frombytes). The top bit is ignored and the value
    /// need not be below p.
    init(bytes s: [UInt8]) {
        func load3(_ index: Int) -> Int64 {
            Int64(s[index]) | Int64(s[index + 1]) &<< 8 | Int64(s[index + 2]) &<< 16
        }
        func load4(_ index: Int) -> Int64 {
            load3(index) | Int64(s[index + 3]) &<< 24
        }
        self = Self.carryLinear(
            load4(0),
            load3(4) &<< 6,
            load3(7) &<< 5,
            load3(10) &<< 3,
            load3(13) &<< 2,
            load4(16),
            load3(20) &<< 7,
            load3(23) &<< 5,
            load3(26) &<< 4,
            (load3(29) & 8_388_607) &<< 2
        )
    }

    /// The canonical encoding: 32 little-endian bytes of the value reduced below p, top bit
    /// clear (ref10 fe_tobytes).
    var bytes: [UInt8] {
        var h0 = v0
        var h1 = v1
        var h2 = v2
        var h3 = v3
        var h4 = v4
        var h5 = v5
        var h6 = v6
        var h7 = v7
        var h8 = v8
        var h9 = v9

        // q = floor(h / p), which is 0 or 1 for the bounded limbs.
        var q = (19 &* h9 &+ (1 &<< 24)) &>> 25
        q = (h0 &+ q) &>> 26
        q = (h1 &+ q) &>> 25
        q = (h2 &+ q) &>> 26
        q = (h3 &+ q) &>> 25
        q = (h4 &+ q) &>> 26
        q = (h5 &+ q) &>> 25
        q = (h6 &+ q) &>> 26
        q = (h7 &+ q) &>> 25
        q = (h8 &+ q) &>> 26
        q = (h9 &+ q) &>> 25

        // h - p q, then carry without rounding; the carry out of h9 is the dropped 2^255 q.
        h0 &+= 19 &* q
        Self.floorCarry(&h0, &h1, 26)
        Self.floorCarry(&h1, &h2, 25)
        Self.floorCarry(&h2, &h3, 26)
        Self.floorCarry(&h3, &h4, 25)
        Self.floorCarry(&h4, &h5, 26)
        Self.floorCarry(&h5, &h6, 25)
        Self.floorCarry(&h6, &h7, 26)
        Self.floorCarry(&h7, &h8, 25)
        Self.floorCarry(&h8, &h9, 26)
        h9 &-= (h9 &>> 25) &<< 25

        func byte(_ value: Int64) -> UInt8 { UInt8(truncatingIfNeeded: value) }
        return [
            byte(h0), byte(h0 &>> 8), byte(h0 &>> 16), byte((h0 &>> 24) | (h1 &<< 2)),
            byte(h1 &>> 6), byte(h1 &>> 14), byte((h1 &>> 22) | (h2 &<< 3)),
            byte(h2 &>> 5), byte(h2 &>> 13), byte((h2 &>> 21) | (h3 &<< 5)),
            byte(h3 &>> 3), byte(h3 &>> 11), byte((h3 &>> 19) | (h4 &<< 6)),
            byte(h4 &>> 2), byte(h4 &>> 10), byte(h4 &>> 18),
            byte(h5), byte(h5 &>> 8), byte(h5 &>> 16), byte((h5 &>> 24) | (h6 &<< 1)),
            byte(h6 &>> 7), byte(h6 &>> 15), byte((h6 &>> 23) | (h7 &<< 3)),
            byte(h7 &>> 5), byte(h7 &>> 13), byte((h7 &>> 21) | (h8 &<< 4)),
            byte(h8 &>> 4), byte(h8 &>> 12), byte((h8 &>> 20) | (h9 &<< 6)),
            byte(h9 &>> 2), byte(h9 &>> 10), byte(h9 &>> 18),
        ]
    }

    /// 1 when the canonical value is odd, 0 when even (ref10 fe_isnegative).
    var isNegative: UInt8 { bytes[0] & 1 }

    /// Whether the value is 0 mod p. Reads every byte; the caller branches on the result, so it
    /// is for public values only.
    var isZero: Bool { bytes.reduce(0, |) == 0 }

    static func + (f: FieldElement, g: FieldElement) -> FieldElement {
        FieldElement(
            f.v0 &+ g.v0, f.v1 &+ g.v1, f.v2 &+ g.v2, f.v3 &+ g.v3, f.v4 &+ g.v4,
            f.v5 &+ g.v5, f.v6 &+ g.v6, f.v7 &+ g.v7, f.v8 &+ g.v8, f.v9 &+ g.v9)
    }

    static func - (f: FieldElement, g: FieldElement) -> FieldElement {
        FieldElement(
            f.v0 &- g.v0, f.v1 &- g.v1, f.v2 &- g.v2, f.v3 &- g.v3, f.v4 &- g.v4,
            f.v5 &- g.v5, f.v6 &- g.v6, f.v7 &- g.v7, f.v8 &- g.v8, f.v9 &- g.v9)
    }

    static prefix func - (f: FieldElement) -> FieldElement {
        FieldElement(
            0 &- f.v0, 0 &- f.v1, 0 &- f.v2, 0 &- f.v3, 0 &- f.v4,
            0 &- f.v5, 0 &- f.v6, 0 &- f.v7, 0 &- f.v8, 0 &- f.v9)
    }

    /// ref10 fe_mul: schoolbook multiplication. A limb pair whose indices add up to 10 or more
    /// wraps around with a factor 19 (2^255 = 19 mod p); a pair of two odd limbs (both 25 bits)
    /// carries an extra factor 2.
    static func * (f: FieldElement, g: FieldElement) -> FieldElement {
        let f0 = f.v0
        let f1 = f.v1
        let f2 = f.v2
        let f3 = f.v3
        let f4 = f.v4
        let f5 = f.v5
        let f6 = f.v6
        let f7 = f.v7
        let f8 = f.v8
        let f9 = f.v9
        let g0 = g.v0
        let g1 = g.v1
        let g2 = g.v2
        let g3 = g.v3
        let g4 = g.v4
        let g5 = g.v5
        let g6 = g.v6
        let g7 = g.v7
        let g8 = g.v8
        let g9 = g.v9
        let g1x19 = 19 &* g1
        let g2x19 = 19 &* g2
        let g3x19 = 19 &* g3
        let g4x19 = 19 &* g4
        let g5x19 = 19 &* g5
        let g6x19 = 19 &* g6
        let g7x19 = 19 &* g7
        let g8x19 = 19 &* g8
        let g9x19 = 19 &* g9
        let f1x2 = 2 &* f1
        let f3x2 = 2 &* f3
        let f5x2 = 2 &* f5
        let f7x2 = 2 &* f7
        let f9x2 = 2 &* f9

        let h0 =
            f0 &* g0 &+ f1x2 &* g9x19 &+ f2 &* g8x19 &+ f3x2 &* g7x19 &+ f4 &* g6x19
            &+ f5x2 &* g5x19 &+ f6 &* g4x19 &+ f7x2 &* g3x19 &+ f8 &* g2x19 &+ f9x2 &* g1x19
        let h1 =
            f0 &* g1 &+ f1 &* g0 &+ f2 &* g9x19 &+ f3 &* g8x19 &+ f4 &* g7x19
            &+ f5 &* g6x19 &+ f6 &* g5x19 &+ f7 &* g4x19 &+ f8 &* g3x19 &+ f9 &* g2x19
        let h2 =
            f0 &* g2 &+ f1x2 &* g1 &+ f2 &* g0 &+ f3x2 &* g9x19 &+ f4 &* g8x19
            &+ f5x2 &* g7x19 &+ f6 &* g6x19 &+ f7x2 &* g5x19 &+ f8 &* g4x19 &+ f9x2 &* g3x19
        let h3 =
            f0 &* g3 &+ f1 &* g2 &+ f2 &* g1 &+ f3 &* g0 &+ f4 &* g9x19
            &+ f5 &* g8x19 &+ f6 &* g7x19 &+ f7 &* g6x19 &+ f8 &* g5x19 &+ f9 &* g4x19
        let h4 =
            f0 &* g4 &+ f1x2 &* g3 &+ f2 &* g2 &+ f3x2 &* g1 &+ f4 &* g0
            &+ f5x2 &* g9x19 &+ f6 &* g8x19 &+ f7x2 &* g7x19 &+ f8 &* g6x19 &+ f9x2 &* g5x19
        let h5 =
            f0 &* g5 &+ f1 &* g4 &+ f2 &* g3 &+ f3 &* g2 &+ f4 &* g1
            &+ f5 &* g0 &+ f6 &* g9x19 &+ f7 &* g8x19 &+ f8 &* g7x19 &+ f9 &* g6x19
        let h6 =
            f0 &* g6 &+ f1x2 &* g5 &+ f2 &* g4 &+ f3x2 &* g3 &+ f4 &* g2
            &+ f5x2 &* g1 &+ f6 &* g0 &+ f7x2 &* g9x19 &+ f8 &* g8x19 &+ f9x2 &* g7x19
        let h7 =
            f0 &* g7 &+ f1 &* g6 &+ f2 &* g5 &+ f3 &* g4 &+ f4 &* g3
            &+ f5 &* g2 &+ f6 &* g1 &+ f7 &* g0 &+ f8 &* g9x19 &+ f9 &* g8x19
        let h8 =
            f0 &* g8 &+ f1x2 &* g7 &+ f2 &* g6 &+ f3x2 &* g5 &+ f4 &* g4
            &+ f5x2 &* g3 &+ f6 &* g2 &+ f7x2 &* g1 &+ f8 &* g0 &+ f9x2 &* g9x19
        let h9 =
            f0 &* g9 &+ f1 &* g8 &+ f2 &* g7 &+ f3 &* g6 &+ f4 &* g5
            &+ f5 &* g4 &+ f6 &* g3 &+ f7 &* g2 &+ f8 &* g1 &+ f9 &* g0

        return carryProduct(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// self^2 (ref10 fe_sq).
    func squared() -> FieldElement {
        square(doubling: false)
    }

    /// 2 self^2 (ref10 fe_sq2).
    func doubledSquare() -> FieldElement {
        square(doubling: true)
    }

    /// self^(2^count).
    func squared(times count: Int) -> FieldElement {
        var result = self
        for _ in 0..<count {
            result = result.square(doubling: false)
        }
        return result
    }

    /// The products of fe_sq: fe_mul's with f = g, each cross product computed once and doubled.
    /// `doubling` is fixed at each call site, never data.
    private func square(doubling: Bool) -> FieldElement {
        let f0 = v0
        let f1 = v1
        let f2 = v2
        let f3 = v3
        let f4 = v4
        let f5 = v5
        let f6 = v6
        let f7 = v7
        let f8 = v8
        let f9 = v9
        let f0x2 = 2 &* f0
        let f1x2 = 2 &* f1
        let f2x2 = 2 &* f2
        let f3x2 = 2 &* f3
        let f4x2 = 2 &* f4
        let f5x2 = 2 &* f5
        let f6x2 = 2 &* f6
        let f7x2 = 2 &* f7
        let f5x38 = 38 &* f5
        let f6x19 = 19 &* f6
        let f7x38 = 38 &* f7
        let f8x19 = 19 &* f8
        let f9x38 = 38 &* f9

        var h0 =
            f0 &* f0 &+ f1x2 &* f9x38 &+ f2x2 &* f8x19 &+ f3x2 &* f7x38 &+ f4x2 &* f6x19
            &+ f5 &* f5x38
        var h1 = f0x2 &* f1 &+ f2 &* f9x38 &+ f3x2 &* f8x19 &+ f4 &* f7x38 &+ f5x2 &* f6x19
        var h2 =
            f0x2 &* f2 &+ f1x2 &* f1 &+ f3x2 &* f9x38 &+ f4x2 &* f8x19 &+ f5x2 &* f7x38
            &+ f6 &* f6x19
        var h3 = f0x2 &* f3 &+ f1x2 &* f2 &+ f4 &* f9x38 &+ f5x2 &* f8x19 &+ f6 &* f7x38
        var h4 =
            f0x2 &* f4 &+ f1x2 &* f3x2 &+ f2 &* f2 &+ f5x2 &* f9x38 &+ f6x2 &* f8x19
            &+ f7 &* f7x38
        var h5 = f0x2 &* f5 &+ f1x2 &* f4 &+ f2x2 &* f3 &+ f6 &* f9x38 &+ f7x2 &* f8x19
        var h6 =
            f0x2 &* f6 &+ f1x2 &* f5x2 &+ f2x2 &* f4 &+ f3x2 &* f3 &+ f7x2 &* f9x38
            &+ f8 &* f8x19
        var h7 = f0x2 &* f7 &+ f1x2 &* f6 &+ f2x2 &* f5 &+ f3x2 &* f4 &+ f8 &* f9x38
        var h8 =
            f0x2 &* f8 &+ f1x2 &* f7x2 &+ f2x2 &* f6 &+ f3x2 &* f5x2 &+ f4 &* f4
            &+ f9 &* f9x38
        var h9 = f0x2 &* f9 &+ f1x2 &* f8 &+ f2x2 &* f7 &+ f3x2 &* f6 &+ f4x2 &* f5

        if doubling {
            h0 &+= h0
            h1 &+= h1
            h2 &+= h2
            h3 &+= h3
            h4 &+= h4
            h5 &+= h5
            h6 &+= h6
            h7 &+= h7
            h8 &+= h8
            h9 &+= h9
        }
        return Self.carryProduct(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// self * 121666, (A + 2) / 4 for Curve25519's A = 486662 (ref10 fe_mul121666).
    func times121666() -> FieldElement {
        Self.carryLinear(
            v0 &* 121_666, v1 &* 121_666, v2 &* 121_666, v3 &* 121_666, v4 &* 121_666,
            v5 &* 121_666, v6 &* 121_666, v7 &* 121_666, v8 &* 121_666, v9 &* 121_666)
    }

    /// self^(p - 2), which is 1/self for nonzero self and 0 for 0 (ref10 fe_invert).
    func inverted() -> FieldElement {
        let (power250, power11) = powerTwo250MinusOne()
        return power250.squared(times: 5) * power11  // 2^255 - 21 = p - 2
    }

    /// self^((p - 5) / 8) = self^(2^252 - 3), the core of the square root in point decoding
    /// (ref10 fe_pow22523).
    func pow22523() -> FieldElement {
        let (power250, _) = powerTwo250MinusOne()
        return power250.squared(times: 2) * self  // 2^252 - 3
    }

    /// The addition chain shared by inverted() and pow22523(): self^(2^250 - 1), and self^11 on
    /// the way. Comments give the exponent reached.
    private func powerTwo250MinusOne() -> (FieldElement, FieldElement) {
        let power2 = squared()  // 2
        let power9 = self * power2.squared(times: 2)  // 9
        let power11 = power2 * power9  // 11
        let run5 = power9 * power11.squared()  // 2^5 - 1
        let run10 = run5.squared(times: 5) * run5  // 2^10 - 1
        let run20 = run10.squared(times: 10) * run10  // 2^20 - 1
        let run40 = run20.squared(times: 20) * run20  // 2^40 - 1
        let run50 = run40.squared(times: 10) * run10  // 2^50 - 1
        let run100 = run50.squared(times: 50) * run50  // 2^100 - 1
        let run200 = run100.squared(times: 100) * run100  // 2^200 - 1
        let run250 = run200.squared(times: 50) * run50  // 2^250 - 1
        return (run250, power11)
    }

    /// Replaces self with `other` when flag is 1 and keeps it when flag is 0 (ref10 fe_cmov).
    /// flag must be 0 or 1.
    mutating func conditionalMove(_ other: FieldElement, flag: Int64) {
        let mask = 0 &- flag
        v0 ^= (v0 ^ other.v0) & mask
        v1 ^= (v1 ^ other.v1) & mask
        v2 ^= (v2 ^ other.v2) & mask
        v3 ^= (v3 ^ other.v3) & mask
        v4 ^= (v4 ^ other.v4) & mask
        v5 ^= (v5 ^ other.v5) & mask
        v6 ^= (v6 ^ other.v6) & mask
        v7 ^= (v7 ^ other.v7) & mask
        v8 ^= (v8 ^ other.v8) & mask
        v9 ^= (v9 ^ other.v9) & mask
    }

    /// Swaps f and g when flag is 1 and leaves them when flag is 0 (ref10 fe_cswap). flag must be
    /// 0 or 1.
    static func conditionalSwap(_ f: inout FieldElement, _ g: inout FieldElement, flag: Int64) {
        let mask = 0 &- flag
        let x0 = (f.v0 ^ g.v0) & mask
        let x1 = (f.v1 ^ g.v1) & mask
        let x2 = (f.v2 ^ g.v2) & mask
        let x3 = (f.v3 ^ g.v3) & mask
        let x4 = (f.v4 ^ g.v4) & mask
        let x5 = (f.v5 ^ g.v5) & mask
        let x6 = (f.v6 ^ g.v6) & mask
        let x7 = (f.v7 ^ g.v7) & mask
        let x8 = (f.v8 ^ g.v8) & mask
        let x9 = (f.v9 ^ g.v9) & mask
        f = FieldElement(
            f.v0 ^ x0, f.v1 ^ x1, f.v2 ^ x2, f.v3 ^ x3, f.v4 ^ x4,
            f.v5 ^ x5, f.v6 ^ x6, f.v7 ^ x7, f.v8 ^ x8, f.v9 ^ x9)
        g = FieldElement(
            g.v0 ^ x0, g.v1 ^ x1, g.v2 ^ x2, g.v3 ^ x3, g.v4 ^ x4,
            g.v5 ^ x5, g.v6 ^ x6, g.v7 ^ x7, g.v8 ^ x8, g.v9 ^ x9)
    }

    /// Moves the bits of `low` above `width` into `high`, rounding so that `low` ends up signed
    /// and at most 2^(width - 1) in magnitude.
    private static func carry(_ low: inout Int64, _ high: inout Int64, _ width: Int64) {
        let carry = (low &+ (1 &<< (width &- 1))) &>> width
        high &+= carry
        low &-= carry &<< width
    }

    /// As carry(_:_:_:), rounding down, so that `low` ends up in [0, 2^width).
    private static func floorCarry(_ low: inout Int64, _ high: inout Int64, _ width: Int64) {
        let carry = low &>> width
        high &+= carry
        low &-= carry &<< width
    }

    /// The carry from h9 back into h0: 2^255 = 19 mod p.
    private static func carryTop(_ h9: inout Int64, _ h0: inout Int64) {
        let carry = (h9 &+ (1 &<< 24)) &>> 25
        h0 &+= carry &* 19
        h9 &-= carry &<< 25
    }

    /// The carry chain closing fe_mul, fe_sq and fe_sq2.
    private static func carryProduct(
        _ h0: Int64, _ h1: Int64, _ h2: Int64, _ h3: Int64, _ h4: Int64,
        _ h5: Int64, _ h6: Int64, _ h7: Int64, _ h8: Int64, _ h9: Int64
    ) -> FieldElement {
        var h0 = h0
        var h1 = h1
        var h2 = h2
        var h3 = h3
        var h4 = h4
        var h5 = h5
        var h6 = h6
        var h7 = h7
        var h8 = h8
        var h9 = h9
        carry(&h0, &h1, 26)
        carry(&h4, &h5, 26)
        carry(&h1, &h2, 25)
        carry(&h5, &h6, 25)
        carry(&h2, &h3, 26)
        carry(&h6, &h7, 26)
        carry(&h3, &h4, 25)
        carry(&h7, &h8, 25)
        carry(&h4, &h5, 26)
        carry(&h8, &h9, 26)
        carryTop(&h9, &h0)
        carry(&h0, &h1, 26)
        return FieldElement(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }

    /// The carry chain closing fe_frombytes and fe_mul121666.
    private static func carryLinear(
        _ h0: Int64, _ h1: Int64, _ h2: Int64, _ h3: Int64, _ h4: Int64,
        _ h5: Int64, _ h6: Int64, _ h7: Int64, _ h8: Int64, _ h9: Int64
    ) -> FieldElement {
        var h0 = h0
        var h1 = h1
        var h2 = h2
        var h3 = h3
        var h4 = h4
        var h5 = h5
        var h6 = h6
        var h7 = h7
        var h8 = h8
        var h9 = h9
        carryTop(&h9, &h0)
        carry(&h1, &h2, 25)
        carry(&h3, &h4, 25)
        carry(&h5, &h6, 25)
        carry(&h7, &h8, 25)
        carry(&h0, &h1, 26)
        carry(&h2, &h3, 26)
        carry(&h4, &h5, 26)
        carry(&h6, &h7, 26)
        carry(&h8, &h9, 26)
        return FieldElement(h0, h1, h2, h3, h4, h5, h6, h7, h8, h9)
    }
}
