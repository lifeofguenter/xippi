import CryptoKit
import Foundation

/// Why a payload could not be encrypted or decrypted.
public enum PayloadError: Error, Sendable, Equatable {
    /// Key material of a length the version does not use.
    case invalidKeyMaterial
    /// A legacy payload without an IV of 12 or 16 bytes.
    case invalidIV
    /// The tag does not match: the payload was altered, or the key is not its key.
    case authenticationFailed
    /// The tag matched but the ciphertext did not decrypt (bad padding).
    case decryptionFailed
    /// The plaintext could not be encrypted.
    case encryptionFailed
}

/// An encrypted `<payload>`, and the key material each recipient's ratchet encrypts.
public struct EncryptedPayload: Sendable {
    /// The `<payload>` content.
    public let ciphertext: Data
    /// The legacy `<iv>` content; nil for OMEMO 2, whose IV is derived from the key.
    public let iv: Data?
    /// The plaintext of every recipient's ratchet message: key and tag. Secret.
    public let keyMaterial: Data
}

extension EncryptedPayload: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var description: String { "EncryptedPayload(\(ciphertext.count) bytes)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["ciphertext": ciphertext, "iv": iv as Any])
    }
}

/// The message body cipher of each version.
///
/// - Legacy OMEMO: AES-128-GCM with a random 16-byte key and 12-byte IV; the key material is the
///   key followed by the 16-byte tag.
/// - OMEMO 2: a random 32-byte key expanded by HKDF-SHA-256 (zero salt, info "OMEMO Payload")
///   into an AES-256-CBC key, an HMAC-SHA-256 key and an IV; the key material is the key
///   followed by the HMAC of the ciphertext truncated to 16 bytes.
public enum PayloadCipher {
    public static func encrypt(
        _ plaintext: Data, version: OMEMOVersion
    ) throws(PayloadError) -> EncryptedPayload {
        switch version {
        case .v03:
            try encrypt(
                plaintext, version: version, key: Primitives.randomBytes(16),
                iv: Primitives.randomBytes(12))
        case .v2:
            try encrypt(plaintext, version: version, key: Primitives.randomBytes(32), iv: nil)
        }
    }

    static func encrypt(
        _ plaintext: Data, version: OMEMOVersion, key: Data, iv: Data?
    ) throws(PayloadError) -> EncryptedPayload {
        switch version {
        case .v03:
            guard key.count == 16 else { throw .invalidKeyMaterial }
            guard let iv, iv.count == 12 || iv.count == 16 else { throw .invalidIV }
            guard let nonce = try? AES.GCM.Nonce(data: iv),
                let sealed = try? AES.GCM.seal(
                    plaintext, using: SymmetricKey(data: key), nonce: nonce)
            else {
                throw .encryptionFailed
            }
            return EncryptedPayload(
                ciphertext: sealed.ciphertext, iv: Data(iv), keyMaterial: key + sealed.tag)
        case .v2:
            guard key.count == 32 else { throw .invalidKeyMaterial }
            let keys = KDF.payloadKeys(key)
            guard
                let ciphertext = Primitives.aesCBCEncrypt(
                    plaintext, key: keys.encryptionKey, iv: keys.iv)
            else {
                throw .encryptionFailed
            }
            let tag = KDF.hmac(key: keys.authenticationKey, ciphertext).prefix(16)
            return EncryptedPayload(ciphertext: ciphertext, iv: nil, keyMaterial: key + tag)
        }
    }

    /// Decrypts a `<payload>` with the key material a ratchet message carried.
    ///
    /// Legacy key material of 16 bytes, with the tag at the end of the payload, and 16-byte IVs
    /// are accepted too: older Conversations releases sent them. `iv` is ignored for OMEMO 2.
    public static func decrypt(
        _ ciphertext: Data, iv: Data?, keyMaterial: Data, version: OMEMOVersion
    ) throws(PayloadError) -> Data {
        switch version {
        case .v03:
            guard let iv, iv.count == 12 || iv.count == 16 else { throw .invalidIV }
            let key: Data
            let body: Data
            let tag: Data
            switch keyMaterial.count {
            case 32:
                key = Data(keyMaterial.prefix(16))
                tag = Data(keyMaterial.suffix(16))
                body = ciphertext
            case 16:
                guard ciphertext.count >= 16 else { throw .authenticationFailed }
                key = Data(keyMaterial)
                tag = Data(ciphertext.suffix(16))
                body = Data(ciphertext.dropLast(16))
            default:
                throw .invalidKeyMaterial
            }
            guard let nonce = try? AES.GCM.Nonce(data: iv),
                let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
                let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key))
            else {
                throw .authenticationFailed
            }
            return plaintext
        case .v2:
            guard keyMaterial.count == 48 else { throw .invalidKeyMaterial }
            let keys = KDF.payloadKeys(Data(keyMaterial.prefix(32)))
            let expected = KDF.hmac(key: keys.authenticationKey, ciphertext).prefix(16)
            guard Primitives.constantTimeEqual(Data(expected), Data(keyMaterial.suffix(16))) else {
                throw .authenticationFailed
            }
            guard
                let plaintext = Primitives.aesCBCDecrypt(
                    ciphertext, key: keys.encryptionKey, iv: keys.iv)
            else {
                throw .decryptionFailed
            }
            return plaintext
        }
    }
}
