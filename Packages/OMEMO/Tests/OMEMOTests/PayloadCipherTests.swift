import CryptoKit
import Foundation
import Testing

@testable import OMEMO

@Suite struct PayloadCipherTests {
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func roundTrip(version: OMEMOVersion) throws {
        for length in [0, 1, 15, 16, 17, 64, 1_000] {
            let plaintext = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
            let encrypted = try PayloadCipher.encrypt(plaintext, version: version)
            switch version {
            case .v03:
                #expect(encrypted.keyMaterial.count == 32)
                #expect(encrypted.iv?.count == 12)
                #expect(encrypted.ciphertext.count == length)
            case .v2:
                #expect(encrypted.keyMaterial.count == 48)
                #expect(encrypted.iv == nil)
                #expect(encrypted.ciphertext.count == (length / 16 + 1) * 16)
            }
            let decrypted = try PayloadCipher.decrypt(
                encrypted.ciphertext, iv: encrypted.iv, keyMaterial: encrypted.keyMaterial,
                version: version)
            #expect(decrypted == plaintext)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func tamperingRejected(version: OMEMOVersion) throws {
        let encrypted = try PayloadCipher.encrypt(Data("secret text".utf8), version: version)
        for bit in [0, 9, encrypted.ciphertext.count * 8 - 1] {
            #expect(throws: PayloadError.authenticationFailed) {
                try PayloadCipher.decrypt(
                    flipping(bit: bit, of: encrypted.ciphertext), iv: encrypted.iv,
                    keyMaterial: encrypted.keyMaterial, version: version)
            }
        }
        for bit in [0, 130, encrypted.keyMaterial.count * 8 - 1] {
            #expect(throws: PayloadError.authenticationFailed) {
                try PayloadCipher.decrypt(
                    encrypted.ciphertext, iv: encrypted.iv,
                    keyMaterial: flipping(bit: bit, of: encrypted.keyMaterial), version: version)
            }
        }
        if let iv = encrypted.iv {
            #expect(throws: PayloadError.authenticationFailed) {
                try PayloadCipher.decrypt(
                    encrypted.ciphertext, iv: flipping(bit: 3, of: iv),
                    keyMaterial: encrypted.keyMaterial, version: version)
            }
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func wrongLengthsRejected(version: OMEMOVersion) throws {
        let encrypted = try PayloadCipher.encrypt(Data("x".utf8), version: version)
        let invalid = version == .v03 ? [0, 15, 17, 31, 33, 48] : [0, 16, 32, 47, 49]
        for length in invalid {
            #expect(throws: PayloadError.invalidKeyMaterial, "length \(length)") {
                try PayloadCipher.decrypt(
                    encrypted.ciphertext, iv: encrypted.iv,
                    keyMaterial: Data(count: length), version: version)
            }
        }
        if version == .v03 {
            for length in [0, 8, 11, 13, 32] {
                #expect(throws: PayloadError.invalidIV, "iv \(length)") {
                    try PayloadCipher.decrypt(
                        encrypted.ciphertext, iv: Data(count: length),
                        keyMaterial: encrypted.keyMaterial, version: .v03)
                }
            }
            #expect(throws: PayloadError.invalidIV) {
                try PayloadCipher.decrypt(
                    encrypted.ciphertext, iv: nil, keyMaterial: encrypted.keyMaterial,
                    version: .v03)
            }
        }
    }

    /// Older Conversations releases send a 16-byte key with the tag appended to the payload,
    /// and a 16-byte IV.
    @Test func legacyKeyWithTagInPayload() throws {
        let key = SymmetricKey(size: .bits128)
        let iv = Data((0..<16).map { UInt8($0) })
        let plaintext = Data("from an older client".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        let keyBytes = key.withUnsafeBytes { Data($0) }
        let decrypted = try PayloadCipher.decrypt(
            sealed.ciphertext + sealed.tag, iv: iv, keyMaterial: keyBytes, version: .v03)
        #expect(decrypted == plaintext)
        #expect(throws: PayloadError.self) {
            try PayloadCipher.decrypt(Data(count: 15), iv: iv, keyMaterial: keyBytes, version: .v03)
        }
    }

    @Test func descriptionHidesKeyMaterial() throws {
        let encrypted = try PayloadCipher.encrypt(Data("x".utf8), version: .v2)
        var dumped = ""
        dump(encrypted, to: &dumped)
        for text in [String(describing: encrypted), String(reflecting: encrypted), dumped] {
            #expect(!text.contains(encrypted.keyMaterial.hex))
            #expect(!text.contains(encrypted.keyMaterial.base64EncodedString()))
        }
    }
}
