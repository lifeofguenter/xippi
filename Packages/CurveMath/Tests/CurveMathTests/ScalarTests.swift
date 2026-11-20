import Foundation
import Testing

@testable import CurveMath

/// Arithmetic modulo L, against Python integers.
@Suite struct ScalarTests {
    @Test func reductionsMatchPython() throws {
        for vector in try PythonVectors.load().scalarReductions {
            #expect(Scalar.reduce(try bytes(vector.input)).hex == vector.output, "\(vector.input)")
        }
    }

    @Test func multiplyAddsMatchPython() throws {
        for vector in try PythonVectors.load().scalarMultiplyAdds {
            let result = Scalar.multiplyAdd(
                try bytes(vector.a), try bytes(vector.b), try bytes(vector.c))
            #expect(result.hex == vector.output, "\(vector.a) \(vector.b) \(vector.c)")
        }
    }

    @Test func negationAddsToZero() throws {
        var generator = SeededGenerator(seed: 252)
        let one = [1] + [UInt8](repeating: 0, count: 31)
        let zero = [UInt8](repeating: 0, count: 32)
        for _ in 0..<16 {
            let value = generator.bytes(32)
            let sum = Scalar.multiplyAdd(one, value, Scalar.negate(value))
            #expect(sum == zero, "\(value.hex)")
        }
    }

    @Test func canonicalMeansBelowL() throws {
        let order = try bytes(groupOrderHex)
        var belowOrder = order
        belowOrder[0] -= 1
        #expect(Scalar.isCanonical([UInt8](repeating: 0, count: 32)))
        #expect(Scalar.isCanonical(belowOrder))
        #expect(!Scalar.isCanonical(order))
        #expect(!Scalar.isCanonical(addLittleEndian(order, [1] + [UInt8](repeating: 0, count: 31))))
        #expect(!Scalar.isCanonical([UInt8](repeating: 0xFF, count: 32)))
    }

    @Test func selectPicksByFlag() {
        let a = [UInt8](repeating: 0xA5, count: 32)
        let b = [UInt8](repeating: 0x3C, count: 32)
        #expect(Scalar.select(a, b, flag: 1) == a)
        #expect(Scalar.select(a, b, flag: 0) == b)
    }
}
