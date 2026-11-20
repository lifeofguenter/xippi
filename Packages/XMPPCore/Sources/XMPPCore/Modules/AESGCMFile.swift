import CryptoKit
import Foundation

public enum AESGCMFileError: Error, Equatable {
    case tooLarge
    case invalidFragment
    case invalidURL
    case decryptionFailed
}

/// XEP-0454 file encryption as `aesgcm://` links: the file is AES-256-GCM encrypted with the tag
/// appended to the ciphertext, uploaded, and the IV and key travel in the link's fragment as
/// hex (12-byte IV then 32-byte key: 88 characters). A 16-byte IV (older clients) gives 96.
///
/// CryptoKit seals in one call, so a file is held in memory whole, plus its ciphertext. Files
/// over `maxSize` (100 MiB) are refused instead of risking memory.
public enum AESGCMFile {
    public static let scheme = "aesgcm"
    public static let maxSize = 100 * 1024 * 1024
    static let ivLength = 12
    static let legacyIVLength = 16
    static let keyLength = 32
    static let tagLength = 16

    /// Encrypts `file` into a new temporary file (ciphertext, then tag). The caller deletes it
    /// after the upload.
    public static func encrypt(file: URL, limit: Int = maxSize) throws -> (URL, key: Data, iv: Data)
    {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        if let size = attributes[.size] as? NSNumber, size.intValue > limit {
            throw AESGCMFileError.tooLarge
        }
        let plain = try Data(contentsOf: file, options: .mappedIfSafe)
        guard plain.count <= limit else { throw AESGCMFileError.tooLarge }
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".aesgcm")
        try (sealed.ciphertext + sealed.tag).write(to: out, options: .atomic)
        return (out, key.withUnsafeBytes { Data($0) }, Data(nonce))
    }

    /// The `aesgcm://` link for an upload's GET address. Only an `https` address qualifies.
    public static func url(get: URL, key: Data, iv: Data) throws(AESGCMFileError) -> URL {
        guard get.scheme?.lowercased() == "https", key.count == keyLength,
            iv.count == ivLength || iv.count == legacyIVLength,
            var parts = URLComponents(url: get, resolvingAgainstBaseURL: false)
        else { throw .invalidURL }
        parts.scheme = scheme
        parts.fragment = hex(iv + key)
        guard let url = parts.url else { throw .invalidURL }
        return url
    }

    /// The `https` address, IV and key of an `aesgcm://` link.
    public static func parse(_ url: URL) throws -> (get: URL, iv: Data, key: Data) {
        guard url.scheme?.lowercased() == scheme,
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let fragment = parts.fragment
        else { throw AESGCMFileError.invalidURL }
        let (iv, key) = try split(fragment: fragment)
        parts.scheme = "https"
        parts.fragment = nil
        guard let get = parts.url else { throw AESGCMFileError.invalidURL }
        return (get, iv, key)
    }

    /// Decrypts a download (ciphertext, then tag) with the IV and key of `fragment`.
    public static func decrypt(data: Data, fragment: String, limit: Int = maxSize) throws -> Data {
        let (iv, key) = try split(fragment: fragment)
        guard data.count >= tagLength, data.count - tagLength <= limit else {
            throw data.count < tagLength ? AESGCMFileError.decryptionFailed : .tooLarge
        }
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(
                nonce: nonce, ciphertext: data.dropLast(tagLength), tag: data.suffix(tagLength))
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw AESGCMFileError.decryptionFailed
        }
    }

    static func split(fragment: String) throws -> (iv: Data, key: Data) {
        guard let bytes = bytes(hex: fragment) else { throw AESGCMFileError.invalidFragment }
        let ivLength = bytes.count - keyLength
        guard ivLength == Self.ivLength || ivLength == legacyIVLength else {
            throw AESGCMFileError.invalidFragment
        }
        return (Data(bytes.prefix(ivLength)), Data(bytes.suffix(keyLength)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }
}
