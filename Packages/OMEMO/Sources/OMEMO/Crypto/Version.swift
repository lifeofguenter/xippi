import Foundation

/// The two OMEMO versions, named by their XML namespace.
///
/// - `v03`: legacy OMEMO (XEP-0384 0.3), as Conversations, Monal and Dino speak it through
///   libsignal: X25519 identity keys signed with XEdDSA, Signal's WhisperMessage and
///   PreKeyWhisperMessage, AES-128-GCM payloads.
/// - `v2`: OMEMO 2 (XEP-0384 0.8 and later): Ed25519 identity keys, the OMEMOMessage,
///   OMEMOAuthenticatedMessage and OMEMOKeyExchange protobuf messages, AES-256-CBC payloads
///   with an HMAC-SHA-256 tag.
public enum OMEMOVersion: String, Sendable, Codable, CaseIterable {
    case v03 = "eu.siacs.conversations.axolotl"
    case v2 = "urn:xmpp:omemo:2"

    /// The public key as bundles and key exchanges carry it: legacy OMEMO puts libsignal's type
    /// byte 0x05 (Curve25519) in front of the 32 key bytes, OMEMO 2 sends the 32 bytes.
    public func encodePublicKey(_ key: Data) -> Data {
        switch self {
        case .v03: Data([Self.curve25519KeyType]) + key
        case .v2: Data(key)
        }
    }

    /// The 32 key bytes of a public key as bundles and key exchanges carry it.
    ///
    /// - Throws: `MessageFormatError.invalidKey` unless the encoding has the length, and for
    ///   legacy OMEMO the type byte, of `encodePublicKey(_:)`.
    public func decodePublicKey(_ encoded: Data) throws(MessageFormatError) -> Data {
        switch self {
        case .v03:
            guard encoded.count == 33, encoded.first == Self.curve25519KeyType else {
                throw .invalidKey
            }
            return Data(encoded.dropFirst())
        case .v2:
            guard encoded.count == 32 else { throw .invalidKey }
            return Data(encoded)
        }
    }

    /// libsignal's key type byte for Curve25519 (Curve.DJB_TYPE).
    static let curve25519KeyType: UInt8 = 0x05

    /// libsignal's message version byte: version 3 in both nibbles.
    static let legacyVersionByte: UInt8 = 0x33

    /// The HKDF info of the X3DH shared secret.
    var x3dhInfo: Data {
        switch self {
        case .v03: Data("WhisperText".utf8)
        case .v2: Data("OMEMO X3DH".utf8)
        }
    }

    /// The HKDF info of the root chain (KDF_RK).
    var rootChainInfo: Data {
        switch self {
        case .v03: Data("WhisperRatchet".utf8)
        case .v2: Data("OMEMO Root Chain".utf8)
        }
    }

    /// The HKDF info that expands a message key into cipher key, MAC key and IV.
    var messageKeyInfo: Data {
        switch self {
        case .v03: Data("WhisperMessageKeys".utf8)
        case .v2: Data("OMEMO Message Key Material".utf8)
        }
    }

    /// Bytes of HMAC-SHA-256 kept as a message's authentication tag.
    var macLength: Int {
        switch self {
        case .v03: 8
        case .v2: 16
        }
    }

    /// Bytes of the X3DH associated data: both encoded identity keys.
    var associatedDataLength: Int {
        switch self {
        case .v03: 66
        case .v2: 64
        }
    }
}
