import Testing

@testable import CurveMath

@Suite struct FieldElementTests {
    static let zero = [UInt8](repeating: 0, count: 32)
    static let one = [1] + [UInt8](repeating: 0, count: 31)

    private func element(_ value: UInt8) -> FieldElement {
        FieldElement(bytes: [value] + [UInt8](repeating: 0, count: 31))
    }

    @Test func canonicalBytesRoundTrip() {
        var generator = SeededGenerator(seed: 1)
        for _ in 0..<64 {
            var value = generator.bytes(32)
            value[31] &= 0x3F
            #expect(FieldElement(bytes: value).bytes == value)
        }
    }

    @Test func unreducedBytesReduce() throws {
        let p = try bytes(fieldPrimeHex)
        #expect(FieldElement(bytes: p).bytes == Self.zero)
        #expect(FieldElement(bytes: addLittleEndian(p, Self.one)).bytes == Self.one)
        // 2^255 - 1 = p + 18.
        var allOnes = [UInt8](repeating: 0xFF, count: 32)
        allOnes[31] = 0x7F
        #expect(FieldElement(bytes: allOnes).bytes == [18] + [UInt8](repeating: 0, count: 31))
    }

    @Test func topBitIsIgnored() {
        var generator = SeededGenerator(seed: 2)
        var value = generator.bytes(32)
        value[31] &= 0x3F
        var marked = value
        marked[31] |= 0x80
        #expect(FieldElement(bytes: marked).bytes == value)
    }

    @Test func inverseTimesValueIsOne() {
        var generator = SeededGenerator(seed: 3)
        for _ in 0..<16 {
            let value = FieldElement(bytes: generator.bytes(32))
            #expect((value * value.inverted()).bytes == Self.one)
        }
        #expect(FieldElement.zero.inverted().bytes == Self.zero)
    }

    @Test func squaresMatchProducts() {
        var generator = SeededGenerator(seed: 4)
        for _ in 0..<16 {
            let value = FieldElement(bytes: generator.bytes(32))
            let product = value * value
            #expect(value.squared().bytes == product.bytes)
            #expect(value.doubledSquare().bytes == (product + product).bytes)
            #expect(value.squared(times: 3).bytes == value.squared().squared().squared().bytes)
        }
    }

    /// y = x^((p - 5) / 8), so y^8 x^4 = x^(p - 1) = 1.
    @Test func pow22523() {
        var generator = SeededGenerator(seed: 5)
        for _ in 0..<8 {
            let value = FieldElement(bytes: generator.bytes(32))
            let power = value.pow22523()
            #expect((power.squared(times: 3) * value.squared(times: 2)).bytes == Self.one)
        }
    }

    @Test func constants() {
        // d = -121665 / 121666.
        let d121666 =
            FieldElement.d * FieldElement(bytes: [0x42, 0xDB, 0x01] + Self.zero.prefix(29))
        #expect(
            (d121666 + FieldElement(bytes: [0x41, 0xDB, 0x01] + Self.zero.prefix(29))).bytes
                == Self.zero)
        #expect(FieldElement.d2.bytes == (FieldElement.d + FieldElement.d).bytes)
        #expect((FieldElement.sqrtMinusOne.squared() + .one).bytes == Self.zero)
    }

    @Test func times121666() {
        var generator = SeededGenerator(seed: 6)
        let factor = FieldElement(bytes: [0x42, 0xDB, 0x01] + Self.zero.prefix(29))
        for _ in 0..<8 {
            let value = FieldElement(bytes: generator.bytes(32))
            #expect(value.times121666().bytes == (value * factor).bytes)
        }
    }

    @Test func negationAndSubtraction() {
        var generator = SeededGenerator(seed: 7)
        let a = FieldElement(bytes: generator.bytes(32))
        let b = FieldElement(bytes: generator.bytes(32))
        #expect((a - b + b).bytes == a.bytes)
        #expect((-a + a).bytes == Self.zero)
        #expect(element(3).isNegative == 1)
        #expect(element(4).isNegative == 0)
        #expect(FieldElement.zero.isZero)
        #expect(!FieldElement.one.isZero)
    }

    @Test func conditionalMoveAndSwap() {
        let a = element(5)
        let b = element(9)
        var kept = a
        kept.conditionalMove(b, flag: 0)
        #expect(kept.bytes == a.bytes)
        var moved = a
        moved.conditionalMove(b, flag: 1)
        #expect(moved.bytes == b.bytes)

        var first = a
        var second = b
        FieldElement.conditionalSwap(&first, &second, flag: 0)
        #expect(first.bytes == a.bytes && second.bytes == b.bytes)
        FieldElement.conditionalSwap(&first, &second, flag: 1)
        #expect(first.bytes == b.bytes && second.bytes == a.bytes)
    }
}
