import CryptoKit
import CurveMath
import Foundation

/// Why a key agreement, or a key, was refused.
public enum X3DHError: Error, Sendable, Equatable {
    /// A key of the wrong length, a public key that is not a usable point (small order, not on
    /// the curve), or a Diffie-Hellman output of all zeros.
    case invalidKey
    /// The bundle's signed pre key signature does not verify against its identity key.
    case invalidSignature
    /// The bundle has no pre key with the requested id.
    case unknownPreKey
    /// The identity key pair belongs to the other OMEMO version.
    case versionMismatch
}

/// A device's long-term identity key pair.
///
/// Legacy OMEMO holds an X25519 key pair and signs with XEdDSA. OMEMO 2 holds an Ed25519 seed
/// (`privateKey`) and its public key, signs with Ed25519, and converts both halves to X25519 for
/// X3DH. Either way the public key is the one bundles publish (without legacy's 0x05 type byte).
public struct IdentityKeyPair: Sendable {
    public let privateKey: Data
    public let publicKey: Data
    public let version: OMEMOVersion

    /// - Throws: `X3DHError.invalidKey` unless `privateKey` is 32 bytes.
    public init(privateKey: Data, version: OMEMOVersion) throws(X3DHError) {
        guard privateKey.count == 32 else { throw .invalidKey }
        let publicKey: Data
        switch version {
        case .v03:
            guard let key = Primitives.x25519PublicKey(privateKey: privateKey) else {
                throw .invalidKey
            }
            publicKey = key
        case .v2:
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
                throw .invalidKey
            }
            publicKey = key.publicKey.rawRepresentation
        }
        self.init(privateKey: Data(privateKey), publicKey: publicKey, version: version)
    }

    private init(privateKey: Data, publicKey: Data, version: OMEMOVersion) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.version = version
    }

    /// A new key pair from the system's secure random generator.
    public static func generate(version: OMEMOVersion) -> IdentityKeyPair {
        switch version {
        case .v03:
            let key = Curve25519.KeyAgreement.PrivateKey()
            return IdentityKeyPair(
                privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation,
                version: version)
        case .v2:
            let key = Curve25519.Signing.PrivateKey()
            return IdentityKeyPair(
                privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation,
                version: version)
        }
    }

    /// The X25519 private key X3DH uses: the key itself for legacy OMEMO, the clamped first half
    /// of SHA-512 of the seed for OMEMO 2.
    var agreementPrivateKey: Data {
        switch version {
        case .v03: privateKey
        case .v2: KeyConversion.montgomeryPrivate(fromEd25519Seed: privateKey)
        }
    }

    /// Signs `message`: XEdDSA for legacy OMEMO, Ed25519 for OMEMO 2.
    public func sign(_ message: Data) throws(X3DHError) -> Data {
        switch version {
        case .v03:
            guard
                let signature = try? XEdDSA.sign(
                    message: message, montgomeryPrivateKey: privateKey,
                    random: Primitives.randomBytes(64))
            else {
                throw .invalidKey
            }
            return signature
        case .v2:
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
                let signature = try? key.signature(for: message)
            else {
                throw .invalidKey
            }
            return signature
        }
    }

    /// The signature a bundle publishes for a signed pre key: over the key as bundles carry it,
    /// so with the 0x05 type byte for legacy OMEMO.
    public func signPreKey(_ publicKey: Data) throws(X3DHError) -> Data {
        guard publicKey.count == 32 else { throw .invalidKey }
        return try sign(version.encodePublicKey(publicKey))
    }
}

extension IdentityKeyPair: Codable {
    private enum CodingKeys: String, CodingKey {
        case privateKey, publicKey, version
    }

    /// Refuses a stored pair whose public key is not the private key's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(OMEMOVersion.self, forKey: .version)
        let privateKey = try container.decode(Data.self, forKey: .privateKey)
        let publicKey = try container.decode(Data.self, forKey: .publicKey)
        guard let pair = try? IdentityKeyPair(privateKey: privateKey, version: version),
            pair.publicKey == publicKey
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey, in: container,
                debugDescription: "The identity key pair does not match")
        }
        self = pair
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privateKey, forKey: .privateKey)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(version, forKey: .version)
    }
}

extension IdentityKeyPair: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var description: String { "IdentityKeyPair(\(version.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["version": version, "publicKey": publicKey])
    }
}

/// An X25519 key pair: a signed pre key, a pre key, an X3DH ephemeral key or a ratchet key.
public struct X25519KeyPair: Sendable {
    public let privateKey: Data
    public let publicKey: Data

    /// - Throws: `X3DHError.invalidKey` unless `privateKey` is 32 bytes.
    public init(privateKey: Data) throws(X3DHError) {
        guard let publicKey = Primitives.x25519PublicKey(privateKey: privateKey) else {
            throw .invalidKey
        }
        self.privateKey = Data(privateKey)
        self.publicKey = publicKey
    }

    private init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    /// A new key pair from the system's secure random generator.
    public static func generate() -> X25519KeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return X25519KeyPair(
            privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }
}

extension X25519KeyPair: Codable {
    private enum CodingKeys: String, CodingKey {
        case privateKey, publicKey
    }

    /// Refuses a stored pair whose public key is not the private key's.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let privateKey = try container.decode(Data.self, forKey: .privateKey)
        let publicKey = try container.decode(Data.self, forKey: .publicKey)
        guard let pair = try? X25519KeyPair(privateKey: privateKey), pair.publicKey == publicKey
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .publicKey, in: container, debugDescription: "The key pair does not match")
        }
        self = pair
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(privateKey, forKey: .privateKey)
        try container.encode(publicKey, forKey: .publicKey)
    }
}

extension X25519KeyPair: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "X25519KeyPair" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["publicKey": publicKey]) }
}

/// The public keys a device publishes so that others can start a session with it. Keys are the
/// 32 key bytes (`OMEMOVersion.decodePublicKey(_:)` removes legacy's type byte); the signature is
/// as published, for legacy OMEMO with the Edwards sign bit in its top bit as libsignal writes it.
public struct PreKeyBundle: Sendable {
    public var identityKey: Data
    public var signedPreKeyID: UInt32
    public var signedPreKey: Data
    public var signedPreKeySignature: Data
    public var preKeys: [(id: UInt32, key: Data)]

    public init(
        identityKey: Data, signedPreKeyID: UInt32, signedPreKey: Data,
        signedPreKeySignature: Data, preKeys: [(id: UInt32, key: Data)]
    ) {
        self.identityKey = identityKey
        self.signedPreKeyID = signedPreKeyID
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.preKeys = preKeys
    }

    /// Whether the signed pre key signature verifies against the identity key: XEdDSA over the
    /// key with its 0x05 type byte for legacy OMEMO, Ed25519 over the key for OMEMO 2.
    public func hasValidSignature(version: OMEMOVersion) -> Bool {
        guard identityKey.count == 32, signedPreKey.count == 32,
            signedPreKeySignature.count == 64
        else {
            return false
        }
        let message = version.encodePublicKey(signedPreKey)
        switch version {
        case .v03:
            return XEdDSA.verify(
                signature: signedPreKeySignature, message: message,
                montgomeryPublicKey: identityKey)
        case .v2:
            // The conversion refuses keys that are not of prime order, which X3DH could not use.
            guard (try? KeyConversion.montgomeryPublic(fromEdwards: identityKey)) != nil,
                let key = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKey)
            else {
                return false
            }
            return key.isValidSignature(signedPreKeySignature, for: message)
        }
    }
}

/// X3DH as both OMEMO versions use it: the bundle must carry a pre key, DH1 to DH4 are all
/// computed, and the shared secret is 32 bytes of HKDF-SHA-256 over 32 0xFF bytes and the
/// outputs, with a zero salt and the version's info string. The associated data is the
/// initiator's encoded identity key followed by the responder's.
public enum X3DH {
    /// The initiator's side, with a fresh ephemeral key.
    ///
    /// - Returns: the shared secret, the ephemeral public key the key exchange message carries,
    ///   and the associated data.
    public static func initiate(
        own: IdentityKeyPair, bundle: PreKeyBundle, preKeyID: UInt32, version: OMEMOVersion
    ) throws(X3DHError) -> (sharedSecret: Data, ephemeral: Data, associatedData: Data) {
        try initiate(
            own: own, bundle: bundle, preKeyID: preKeyID, version: version,
            ephemeralPrivateKey: X25519KeyPair.generate().privateKey)
    }

    static func initiate(
        own: IdentityKeyPair, bundle: PreKeyBundle, preKeyID: UInt32, version: OMEMOVersion,
        ephemeralPrivateKey: Data
    ) throws(X3DHError) -> (sharedSecret: Data, ephemeral: Data, associatedData: Data) {
        guard own.version == version else { throw .versionMismatch }
        let ephemeral = try X25519KeyPair(privateKey: ephemeralPrivateKey)
        guard bundle.identityKey.count == 32, bundle.signedPreKey.count == 32 else {
            throw .invalidKey
        }
        guard bundle.hasValidSignature(version: version) else { throw .invalidSignature }
        guard let preKey = bundle.preKeys.first(where: { $0.id == preKeyID })?.key else {
            throw .unknownPreKey
        }
        let remoteIdentity = try agreementPublicKey(bundle.identityKey, version: version)
        let sharedSecret = KDF.x3dhSharedSecret(
            [
                try dh(own.agreementPrivateKey, bundle.signedPreKey),
                try dh(ephemeral.privateKey, remoteIdentity),
                try dh(ephemeral.privateKey, bundle.signedPreKey),
                try dh(ephemeral.privateKey, preKey),
            ], version: version)
        let associatedData =
            version.encodePublicKey(own.publicKey) + version.encodePublicKey(bundle.identityKey)
        return (sharedSecret, ephemeral.publicKey, associatedData)
    }

    /// The responder's side, from the key exchange message and its own keys: the signed pre key
    /// and the pre key the message names.
    public static func respond(
        own: IdentityKeyPair, signedPreKey: X25519KeyPair, preKey: X25519KeyPair,
        remoteIdentityKey: Data, remoteEphemeral: Data, version: OMEMOVersion
    ) throws(X3DHError) -> (sharedSecret: Data, associatedData: Data) {
        guard own.version == version else { throw .versionMismatch }
        guard remoteIdentityKey.count == 32, remoteEphemeral.count == 32 else {
            throw .invalidKey
        }
        let remoteIdentity = try agreementPublicKey(remoteIdentityKey, version: version)
        let sharedSecret = KDF.x3dhSharedSecret(
            [
                try dh(signedPreKey.privateKey, remoteIdentity),
                try dh(own.agreementPrivateKey, remoteEphemeral),
                try dh(signedPreKey.privateKey, remoteEphemeral),
                try dh(preKey.privateKey, remoteEphemeral),
            ], version: version)
        let associatedData =
            version.encodePublicKey(remoteIdentityKey) + version.encodePublicKey(own.publicKey)
        return (sharedSecret, associatedData)
    }

    /// The X25519 form of an identity public key.
    private static func agreementPublicKey(
        _ identityKey: Data, version: OMEMOVersion
    ) throws(X3DHError) -> Data {
        switch version {
        case .v03:
            return identityKey
        case .v2:
            guard let key = try? KeyConversion.montgomeryPublic(fromEdwards: identityKey) else {
                throw .invalidKey
            }
            return key
        }
    }

    private static func dh(_ privateKey: Data, _ publicKey: Data) throws(X3DHError) -> Data {
        guard let output = Primitives.x25519(privateKey: privateKey, publicKey: publicKey) else {
            throw .invalidKey
        }
        return output
    }
}
