import CryptoKit
import Foundation

/// The key derivations of X3DH and the Double Ratchet, with each version's HKDF info strings.
///
/// Legacy OMEMO uses libsignal's strings ("WhisperText", "WhisperRatchet", "WhisperMessageKeys"),
/// OMEMO 2 those of XEP-0384 section 4 ("OMEMO X3DH", "OMEMO Root Chain",
/// "OMEMO Message Key Material", "OMEMO Payload"). Both hash with SHA-256.
enum KDF {
    /// 256 zero bits, the HKDF salt wherever the protocol has no other.
    static let zeroSalt = Data(count: 32)

    static func hkdf(_ inputKeyMaterial: Data, salt: Data, info: Data, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: count
        ).withUnsafeBytes { Data($0) }
    }

    static func hmac(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// X3DH: HKDF over 32 0xFF bytes followed by the Diffie-Hellman outputs DH1 to DH4.
    static func x3dhSharedSecret(_ dhOutputs: [Data], version: OMEMOVersion) -> Data {
        var inputKeyMaterial = Data(repeating: 0xFF, count: 32)
        for output in dhOutputs {
            inputKeyMaterial.append(output)
        }
        return hkdf(inputKeyMaterial, salt: zeroSalt, info: version.x3dhInfo, count: 32)
    }

    /// KDF_RK: HKDF with the root key as salt and the Diffie-Hellman output as input keying
    /// material; 64 bytes, the new root key followed by the new chain key.
    static func rootStep(
        rootKey: Data, dhOutput: Data, version: OMEMOVersion
    ) -> (rootKey: Data, chainKey: Data) {
        let output = hkdf(dhOutput, salt: rootKey, info: version.rootChainInfo, count: 64)
        return (Data(output.prefix(32)), Data(output.suffix(32)))
    }

    /// KDF_CK: HMAC-SHA-256 keyed with the chain key, of 0x02 for the next chain key and of 0x01
    /// for the message key.
    static func chainStep(_ chainKey: Data) -> (chainKey: Data, messageKey: Data) {
        (hmac(key: chainKey, Data([0x02])), hmac(key: chainKey, Data([0x01])))
    }

    /// A message key expanded into the AES-256-CBC key, the HMAC key and the IV.
    static func messageKeys(
        _ messageKey: Data, version: OMEMOVersion
    ) -> (encryptionKey: Data, authenticationKey: Data, iv: Data) {
        split80(hkdf(messageKey, salt: zeroSalt, info: version.messageKeyInfo, count: 80))
    }

    /// OMEMO 2's payload key expanded into the AES-256-CBC key, the HMAC key and the IV.
    static func payloadKeys(_ key: Data) -> (encryptionKey: Data, authenticationKey: Data, iv: Data)
    {
        split80(hkdf(key, salt: zeroSalt, info: Data("OMEMO Payload".utf8), count: 80))
    }

    private static func split80(_ output: Data) -> (Data, Data, Data) {
        let bytes = Array(output)
        return (Data(bytes[0..<32]), Data(bytes[32..<64]), Data(bytes[64..<80]))
    }
}
