import Foundation

enum TestInputError: Error {
    case badHex(String)
    case missingResource(String)
}

/// Bytes from a hex string. Whitespace is ignored, so long values can span lines.
func bytes(_ hex: String) throws -> [UInt8] {
    let digits = Array(hex.filter { !$0.isWhitespace })
    guard digits.count.isMultiple(of: 2) else { throw TestInputError.badHex(hex) }
    var result: [UInt8] = []
    result.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
        guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
            throw TestInputError.badHex(hex)
        }
        result.append(byte)
    }
    return result
}

func data(_ hex: String) throws -> Data {
    Data(try bytes(hex))
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// SplitMix64, so the randomised tests use the same inputs on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &self) }
    }
}

/// a + b for little-endian byte strings of the same length; the carry out of the top byte is
/// dropped.
func addLittleEndian(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: a.count)
    var carry = 0
    for index in a.indices {
        let sum = Int(a[index]) + Int(b[index]) + carry
        result[index] = UInt8(sum & 0xFF)
        carry = sum >> 8
    }
    return result
}

/// L, the order of the Ed25519 base point, little-endian.
let groupOrderHex = "edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010"

/// p = 2^255 - 19, little-endian.
let fieldPrimeHex = "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"

/// The vectors written by scripts/omemo-vectors/generate.py (python-xeddsa 1.2.0).
struct PythonVectors: Decodable {
    struct Signature: Decodable {
        let privateKey: String
        let publicKey: String
        let message: String
        let random: String
        let signature: String
        let edwardsSignBit: Int
    }

    struct LibsignalSignature: Decodable {
        let publicKey: String
        let message: String
        let signature: String
        let edwardsSignBit: Int
    }

    struct SeedConversion: Decodable {
        let seed: String
        let montgomeryPrivate: String
        let edwardsPublic: String
        let montgomeryPublic: String
    }

    struct MontgomeryToEdwards: Decodable {
        let montgomeryPublic: String
        let signBit: UInt8
        let edwardsPublic: String
    }

    struct ScalarReduction: Decodable {
        let input: String
        let output: String
    }

    struct ScalarMultiplyAdd: Decodable {
        let a: String
        let b: String
        let c: String
        let output: String
    }

    let xeddsaVersion: String
    let signatures: [Signature]
    let libsignalSignatures: [LibsignalSignature]
    let seedConversions: [SeedConversion]
    let montgomeryToEdwards: [MontgomeryToEdwards]
    let scalarReductions: [ScalarReduction]
    let scalarMultiplyAdds: [ScalarMultiplyAdd]

    static func load() throws -> PythonVectors {
        guard let url = Bundle.module.url(forResource: "xeddsa-vectors", withExtension: "json")
        else {
            throw TestInputError.missingResource("xeddsa-vectors.json")
        }
        return try JSONDecoder().decode(PythonVectors.self, from: Data(contentsOf: url))
    }
}
