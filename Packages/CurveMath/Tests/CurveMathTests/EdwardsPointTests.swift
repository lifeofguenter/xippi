import Testing

@testable import CurveMath

@Suite struct EdwardsPointTests {
    static let baseEncoding = "5866666666666666666666666666666666666666666666666666666666666666"
    static let identityEncoding = "0100000000000000000000000000000000000000000000000000000000000000"

    @Test func baseAndIdentityEncode() {
        #expect(EdwardsPoint.base.encoded().hex == Self.baseEncoding)
        #expect(EdwardsPoint.identity.encoded().hex == Self.identityEncoding)
        #expect(EdwardsPoint.identity.isIdentity)
        #expect(!EdwardsPoint.base.isIdentity)
    }

    @Test func decodeRoundTrips() throws {
        var generator = SeededGenerator(seed: 10)
        for _ in 0..<8 {
            var scalar = generator.bytes(32)
            scalar[31] &= 0x7F
            let encoding = EdwardsPoint.multiplyBase(scalar).encoded()
            let decoded = try #require(EdwardsPoint.decode(encoding))
            #expect(decoded.encoded() == encoding)
        }
        let base = try #require(EdwardsPoint.decode(try bytes(Self.baseEncoding)))
        #expect(base.encoded().hex == Self.baseEncoding)
    }

    @Test func unreducedEncodingIsRejected() throws {
        // y = 3 is on the curve; y = p + 3 encodes the same value unreduced.
        #expect(EdwardsPoint.decode([3] + [UInt8](repeating: 0, count: 31)) != nil)
        let pPlusThree = addLittleEndian(
            try bytes(fieldPrimeHex), [3] + [UInt8](repeating: 0, count: 31))
        #expect(EdwardsPoint.decode(pPlusThree) == nil)
    }

    @Test func orderAndPrimeOrderCheck() throws {
        let order = try bytes(groupOrderHex)
        #expect(EdwardsPoint.multiply(order, .base).isIdentity)
        #expect(EdwardsPoint.base.hasPrimeOrder)
        #expect(!EdwardsPoint.identity.hasPrimeOrder)
        let mixed = try #require(
            EdwardsPoint.decode(
                try bytes("98519eadf35b995233b51b5cd23e9cc5a28b639b5a4af0ec903cb960d81b7819")))
        #expect(!mixed.hasPrimeOrder)
    }

    /// (a b + c) B = a (b B) + c B, with the scalar arithmetic done by Scalar.
    @Test func scalarMultiplicationIsLinear() {
        var generator = SeededGenerator(seed: 11)
        let zero = [UInt8](repeating: 0, count: 32)
        for _ in 0..<6 {
            let a = Scalar.reduce(generator.bytes(64))
            let b = Scalar.reduce(generator.bytes(64))
            let c = Scalar.reduce(generator.bytes(64))
            let left = EdwardsPoint.multiplyBase(Scalar.multiplyAdd(a, b, c))
            let bB = EdwardsPoint.multiplyBase(b)
            let right = EdwardsPoint.multiply(a, bB) + EdwardsPoint.multiplyBase(c).cached
            #expect(left.encoded() == right.extended.encoded())
            #expect(EdwardsPoint.multiply(zero, bB).isIdentity)
        }
    }

    @Test func pointPlusNegationIsIdentity() {
        var generator = SeededGenerator(seed: 12)
        var scalar = generator.bytes(32)
        scalar[31] &= 0x7F
        let point = EdwardsPoint.multiplyBase(scalar)
        #expect((point + point.negated().cached).extended.isIdentity)
        #expect((point + point.cached).extended.encoded() == point.doubled().extended.encoded())
    }
}
