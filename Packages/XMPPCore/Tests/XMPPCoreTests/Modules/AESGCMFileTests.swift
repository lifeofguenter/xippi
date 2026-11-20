import CryptoKit
import Foundation
import Testing

@testable import XMPPCore

@Suite struct AESGCMFileTests {
    @Test func oneMebibyteRoundTrips() throws {
        var bytes = [UInt8](repeating: 0, count: 1 << 20)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8) }
        let plain = Data(bytes)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try plain.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let (encrypted, key, iv) = try AESGCMFile.encrypt(file: source)
        defer { try? FileManager.default.removeItem(at: encrypted) }
        #expect(iv.count == 12)
        #expect(key.count == 32)
        let cipher = try Data(contentsOf: encrypted)
        #expect(cipher.count == plain.count + 16)
        #expect(cipher.prefix(plain.count) != plain)

        let get = try #require(URL(string: "https://dl.example/abc/file.bin"))
        let link = try AESGCMFile.url(get: get, key: key, iv: iv)
        #expect(link.scheme == "aesgcm")
        let fragment = try #require(link.fragment)
        #expect(fragment.count == 88)
        #expect(fragment.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(try AESGCMFile.decrypt(data: cipher, fragment: fragment) == plain)

        let parsed = try AESGCMFile.parse(link)
        #expect(parsed.get == get)
        #expect(parsed.iv == iv)
        #expect(parsed.key == key)
    }

    @Test func sixteenByteIVIsAccepted() throws {
        let key = SymmetricKey(size: .bits256)
        let iv = Data((0..<16).map { UInt8($0) })
        let sealed = try AES.GCM.seal(
            Data("hi".utf8), using: key, nonce: try AES.GCM.Nonce(data: iv))
        let keyData = key.withUnsafeBytes { Data($0) }
        let fragment = AESGCMFile.hex(iv + keyData)
        #expect(fragment.count == 96)
        #expect(
            try AESGCMFile.decrypt(data: sealed.ciphertext + sealed.tag, fragment: fragment)
                == Data("hi".utf8))
    }

    @Test func badInputIsRefused() throws {
        #expect(throws: AESGCMFileError.invalidFragment) {
            try AESGCMFile.decrypt(data: Data(count: 32), fragment: "abcd")
        }
        #expect(throws: AESGCMFileError.invalidFragment) {
            try AESGCMFile.decrypt(
                data: Data(count: 32), fragment: String(repeating: "zz", count: 44))
        }
        #expect(throws: AESGCMFileError.decryptionFailed) {
            try AESGCMFile.decrypt(
                data: Data(count: 32), fragment: String(repeating: "ab", count: 44))
        }
        #expect(throws: AESGCMFileError.decryptionFailed) {
            try AESGCMFile.decrypt(
                data: Data(count: 3), fragment: String(repeating: "ab", count: 44))
        }
        #expect(throws: AESGCMFileError.invalidURL) {
            try AESGCMFile.url(
                get: URL(string: "http://x.example/a")!, key: Data(count: 32), iv: Data(count: 12))
        }
        #expect(throws: AESGCMFileError.invalidURL) {
            try AESGCMFile.parse(URL(string: "https://x.example/a#00")!)
        }
    }

    @Test func tamperedCiphertextFails() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try Data("secret".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let (encrypted, key, iv) = try AESGCMFile.encrypt(file: source)
        defer { try? FileManager.default.removeItem(at: encrypted) }
        var cipher = try Data(contentsOf: encrypted)
        cipher[0] ^= 1
        #expect(throws: AESGCMFileError.decryptionFailed) {
            try AESGCMFile.decrypt(data: cipher, fragment: AESGCMFile.hex(iv + key))
        }
    }

    @Test func encryptRefusesAFileOverTheCapWithoutReadingIt() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: source) }
        let handle = try FileHandle(forWritingTo: source)
        // Sparse: uses no memory or disk.
        try handle.truncate(atOffset: UInt64(AESGCMFile.maxSize) + 1)
        try handle.close()
        #expect(throws: AESGCMFileError.tooLarge) { try AESGCMFile.encrypt(file: source) }
    }

    @Test func limitsAreEnforcedOnBothSides() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try Data(count: 100).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(throws: AESGCMFileError.tooLarge) {
            try AESGCMFile.encrypt(file: source, limit: 99)
        }
        let (encrypted, key, iv) = try AESGCMFile.encrypt(file: source, limit: 100)
        defer { try? FileManager.default.removeItem(at: encrypted) }
        let cipher = try Data(contentsOf: encrypted)
        let fragment = AESGCMFile.hex(iv + key)
        #expect(throws: AESGCMFileError.tooLarge) {
            try AESGCMFile.decrypt(data: cipher, fragment: fragment, limit: 99)
        }
        #expect(try AESGCMFile.decrypt(data: cipher, fragment: fragment, limit: 100).count == 100)
    }
}
