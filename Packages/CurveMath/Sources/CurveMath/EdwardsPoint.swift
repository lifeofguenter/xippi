// Points on edwards25519, -x^2 + y^2 = 1 + d x^2 y^2 over GF(2^255 - 19).
//
// Ported from the ref10 implementation of Ed25519 in SUPERCOP (public domain): ge_add.h,
// ge_p2_dbl.h, ge_p1p1_to_p2.c, ge_p1p1_to_p3.c, ge_p3_to_cached.c, ge_p3_tobytes.c,
// ge_frombytes.c and the recoding and table selection of ge_scalarmult_base.c, written anew in
// Swift. The coordinate systems are ref10's:
//
// - EdwardsPoint is ge_p3, extended coordinates (X:Y:Z:T) with x = X/Z, y = Y/Z, xy = T/Z.
// - ProjectivePoint is ge_p2, (X:Y:Z).
// - CompletedPoint is ge_p1p1, ((X:Z), (Y:T)) with x = X/Z, y = Y/T.
// - CachedPoint is ge_cached, (Y+X, Y-X, Z, 2dT), the second operand of an addition.
//
// ref10 multiplies the base point with a precomputed table of 256 of its multiples. multiply
// instead builds the eight multiples 1P to 8P of whatever point it is given, then runs ref10's
// signed radix-16 recoding and constant-time table selection over them, so one routine serves
// the base point and every other point.
//
// Constant time: multiply and encoded() run the same operations for every scalar and point. A
// table entry is taken by scanning all eight entries with masked moves, never by indexing with
// a digit. decode, isIdentity and hasPrimeOrder branch on their input and are only used on
// public keys and signatures.

struct EdwardsPoint: Sendable {
    var x: FieldElement
    var y: FieldElement
    var z: FieldElement
    var t: FieldElement

    static let identity = EdwardsPoint(x: .zero, y: .one, z: .one, t: .zero)

    /// The base point B: y = 4/5, x even.
    static let base: EdwardsPoint = {
        let x = FieldElement(bytes: [
            0x1A, 0xD5, 0x25, 0x8F, 0x60, 0x2D, 0x56, 0xC9, 0xB2, 0xA7, 0x25, 0x95, 0x60, 0xC7,
            0x2C, 0x69, 0x5C, 0xDC, 0xD6, 0xFD, 0x31, 0xE2, 0xA4, 0xC0, 0xFE, 0x53, 0x6E, 0xCD,
            0xD3, 0x36, 0x69, 0x21,
        ])
        let y = FieldElement(bytes: [0x58] + [UInt8](repeating: 0x66, count: 31))
        return EdwardsPoint(x: x, y: y, z: .one, t: x * y)
    }()

    /// ref10 ge_p3_to_p2.
    var projective: ProjectivePoint { ProjectivePoint(x: x, y: y, z: z) }

    /// ref10 ge_p3_to_cached.
    var cached: CachedPoint { CachedPoint(yPlusX: y + x, yMinusX: y - x, z: z, t2d: t * .d2) }

    /// -P = (-x, y).
    func negated() -> EdwardsPoint {
        EdwardsPoint(x: -x, y: y, z: z, t: -t)
    }

    /// 2P (ref10 ge_p3_dbl).
    func doubled() -> CompletedPoint {
        projective.doubled()
    }

    /// P + Q (ref10 ge_add). The formulas are complete on edwards25519: they also hold for
    /// P = Q and for the identity.
    static func + (p: EdwardsPoint, q: CachedPoint) -> CompletedPoint {
        let a = (p.y + p.x) * q.yPlusX
        let b = (p.y - p.x) * q.yMinusX
        let c = q.t2d * p.t
        let zz = p.z * q.z
        let d = zz + zz
        return CompletedPoint(x: a - b, y: a + b, z: d + c, t: d - c)
    }

    /// The 32-byte encoding: y, with the parity of x in the top bit (ref10 ge_p3_tobytes).
    func encoded() -> [UInt8] {
        let inverse = z.inverted()
        var s = (y * inverse).bytes
        s[31] ^= (x * inverse).isNegative << 7
        return s
    }

    /// The point a 32-byte encoding names (ref10 ge_frombytes_negate_vartime, without the
    /// negation). nil unless the encoding is canonical (y < p, and no sign bit on x = 0) and the
    /// point is on the curve, as RFC 8032 section 5.1.3 requires. Variable time.
    static func decode(_ s: [UInt8]) -> EdwardsPoint? {
        guard s.count == 32 else { return nil }
        let y = FieldElement(bytes: s)
        let sign = s[31] >> 7
        var canonical = y.bytes
        canonical[31] |= sign << 7
        guard canonical == s else { return nil }

        // x^2 = u/v with u = y^2 - 1, v = d y^2 + 1; x = u v^3 (u v^7)^((p - 5) / 8).
        let yy = y.squared()
        let u = yy - .one
        let v = yy * .d + .one
        let v3 = v.squared() * v
        var x = (v3.squared() * v * u).pow22523() * v3 * u
        let vxx = x.squared() * v
        if !(vxx - u).isZero {
            guard (vxx + u).isZero else { return nil }
            x = x * .sqrtMinusOne
        }
        if x.isZero && sign == 1 {
            return nil
        }
        if x.isNegative != sign {
            x = -x
        }
        return EdwardsPoint(x: x, y: y, z: .one, t: x * y)
    }

    /// The point with y = (u - 1) / (u + 1) and the given sign bit, the Edwards form of an
    /// X25519 public key, with its encoding. nil unless u is canonical (below p, top bit clear)
    /// and the point is on the curve and of prime order. Variable time.
    static func fromMontgomery(
        _ u: [UInt8], signBit: UInt8
    ) -> (point: EdwardsPoint, encoding: [UInt8])? {
        guard u.count == 32, signBit <= 1 else { return nil }
        let uValue = FieldElement(bytes: u)
        guard uValue.bytes == u else { return nil }
        var encoding = ((uValue - .one) * (uValue + .one).inverted()).bytes
        encoding[31] |= signBit << 7
        guard let point = decode(encoding), point.hasPrimeOrder else { return nil }
        return (point, encoding)
    }

    /// Whether this is (0, 1). Variable time.
    var isIdentity: Bool { x.isZero && (y - z).isZero }

    /// Whether the point generates the subgroup of order L: L P is the identity and P is not.
    /// Rejects the small-order points and those with a small-order component. Variable time.
    var hasPrimeOrder: Bool {
        !isIdentity && Self.multiply(Scalar.order, self).isIdentity
    }

    /// a B for the base point B. See multiply(_:_:).
    static func multiplyBase(_ a: [UInt8]) -> EdwardsPoint {
        multiply(a, base)
    }

    /// a P for a 32-byte little-endian scalar a with a[31] <= 127. Constant time in a and P.
    ///
    /// With a written as sum e[i] 16^i, e[i] in -8...8, the result is accumulated from the top
    /// digit down: 16 times the running total, plus e[i] P taken from a table of 1P to 8P.
    static func multiply(_ a: [UInt8], _ point: EdwardsPoint) -> EdwardsPoint {
        let first = point.cached
        var multiples = [first]
        multiples.reserveCapacity(8)
        var current = point
        for _ in 1..<8 {
            current = (current + first).extended
            multiples.append(current.cached)
        }

        let digits = signedRadix16(a)
        var result = identity
        for index in stride(from: 63, through: 0, by: -1) {
            var projective = result.doubled().projective
            projective = projective.doubled().projective
            projective = projective.doubled().projective
            result = projective.doubled().extended
            result = (result + select(multiples, digits[index])).extended
        }
        return result
    }

    /// The 64 signed radix-16 digits of a, each in -8...8 (ref10 ge_scalarmult_base). Needs
    /// a[31] <= 127 so that the top digit stays within 8.
    private static func signedRadix16(_ a: [UInt8]) -> [Int8] {
        var digits = [Int8](repeating: 0, count: 64)
        for index in 0..<32 {
            digits[2 * index] = Int8(truncatingIfNeeded: a[index] & 15)
            digits[2 * index + 1] = Int8(truncatingIfNeeded: (a[index] &>> 4) & 15)
        }
        var carry: Int8 = 0
        for index in 0..<63 {
            digits[index] &+= carry
            carry = (digits[index] &+ 8) &>> 4
            digits[index] &-= carry &<< 4
        }
        digits[63] &+= carry
        return digits
    }

    /// b P from the table of 1P to 8P, for b in -8...8 (ref10 select). Every entry is read and
    /// the one wanted is kept by masked moves; a negative b negates the result the same way.
    private static func select(_ multiples: [CachedPoint], _ b: Int8) -> CachedPoint {
        let value = Int64(b)
        let negative = Int64(bitPattern: UInt64(bitPattern: value) >> 63)
        let magnitude = value &- (((0 &- negative) & value) &<< 1)
        var result = CachedPoint.identity
        for index in 0..<8 {
            result.conditionalMove(multiples[index], flag: equal(magnitude, Int64(index + 1)))
        }
        let negated = result.negated()
        result.conditionalMove(negated, flag: negative)
        return result
    }

    /// 1 when a == b, else 0, for a and b in 0...255, without a comparison (ref10 equal).
    private static func equal(_ a: Int64, _ b: Int64) -> Int64 {
        let difference = UInt64(bitPattern: a ^ b)
        return Int64(bitPattern: (difference &- 1) >> 63)
    }
}

/// ref10 ge_p2.
struct ProjectivePoint: Sendable {
    var x: FieldElement
    var y: FieldElement
    var z: FieldElement

    /// 2P (ref10 ge_p2_dbl).
    func doubled() -> CompletedPoint {
        let xx = x.squared()
        let yy = y.squared()
        let zz2 = z.doubledSquare()
        let sumSquared = (x + y).squared()
        let yyPlusXX = yy + xx
        let yyMinusXX = yy - xx
        return CompletedPoint(
            x: sumSquared - yyPlusXX, y: yyPlusXX, z: yyMinusXX, t: zz2 - yyMinusXX)
    }
}

/// ref10 ge_p1p1.
struct CompletedPoint: Sendable {
    var x: FieldElement
    var y: FieldElement
    var z: FieldElement
    var t: FieldElement

    /// ref10 ge_p1p1_to_p2.
    var projective: ProjectivePoint { ProjectivePoint(x: x * t, y: y * z, z: z * t) }

    /// ref10 ge_p1p1_to_p3.
    var extended: EdwardsPoint { EdwardsPoint(x: x * t, y: y * z, z: z * t, t: x * y) }
}

/// ref10 ge_cached.
struct CachedPoint: Sendable {
    var yPlusX: FieldElement
    var yMinusX: FieldElement
    var z: FieldElement
    var t2d: FieldElement

    static let identity = CachedPoint(yPlusX: .one, yMinusX: .one, z: .one, t2d: .zero)

    /// -P: x changes sign, so Y+X and Y-X trade places and T changes sign.
    func negated() -> CachedPoint {
        CachedPoint(yPlusX: yMinusX, yMinusX: yPlusX, z: z, t2d: -t2d)
    }

    /// Replaces self with `other` when flag is 1 and keeps it when flag is 0.
    mutating func conditionalMove(_ other: CachedPoint, flag: Int64) {
        yPlusX.conditionalMove(other.yPlusX, flag: flag)
        yMinusX.conditionalMove(other.yMinusX, flag: flag)
        z.conditionalMove(other.z, flag: flag)
        t2d.conditionalMove(other.t2d, flag: flag)
    }
}
