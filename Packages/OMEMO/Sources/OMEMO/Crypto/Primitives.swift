import CommonCrypto
import CryptoKit
import Foundation

/// The primitives the protocol is built from: system randomness, X25519, AES-CBC with PKCS#7
/// padding (CommonCrypto), and constant-time comparison.
enum Primitives {
    /// Bytes from the system's cryptographically secure generator.
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(capacity: count + 8)
        while bytes.count < count {
            withUnsafeBytes(of: generator.next() as UInt64) { bytes.append(contentsOf: $0) }
        }
        return bytes.prefix(count)
    }

    /// X25519 of a 32-byte private key (clamped as RFC 7748 clamps) and a 32-byte public key.
    /// Nil for a key of the wrong length and for a public key of small order, whose shared secret
    /// would be all zeros.
    static func x25519(privateKey: Data, publicKey: Data) -> Data? {
        guard privateKey.count == 32, publicKey.count == 32,
            let ownKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
            let otherKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
            let secret = try? ownKey.sharedSecretFromKeyAgreement(with: otherKey)
        else {
            return nil
        }
        let shared = secret.withUnsafeBytes { Data($0) }
        guard shared.count == 32, !isAllZero(shared) else { return nil }
        return shared
    }

    /// The X25519 public key of a 32-byte private key.
    static func x25519PublicKey(privateKey: Data) -> Data? {
        guard privateKey.count == 32,
            let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        else {
            return nil
        }
        return key.publicKey.rawRepresentation
    }

    /// AES-256-CBC with PKCS#7 padding. Nil only for a key or IV of the wrong length.
    static func aesCBCEncrypt(_ plaintext: Data, key: Data, iv: Data) -> Data? {
        aesCBC(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv)
    }

    /// AES-256-CBC decryption with PKCS#7 padding removed. Nil for a ciphertext that is not whole
    /// blocks or whose padding is wrong.
    static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        return aesCBC(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv)
    }

    private static func aesCBC(_ operation: CCOperation, _ input: Data, key: Data, iv: Data)
        -> Data?
    {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { return nil }
        // CommonCrypto wants a pointer even for empty input.
        let source = input.isEmpty ? Data([0]) : Data(input)
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            source.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), written <= capacity else { return nil }
        return output.prefix(written)
    }

    /// Compares in time that depends only on the lengths, which are public here (MAC lengths).
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    static func isAllZero(_ bytes: Data) -> Bool {
        var accumulated: UInt8 = 0
        for byte in bytes {
            accumulated |= byte
        }
        return accumulated == 0
    }
}
