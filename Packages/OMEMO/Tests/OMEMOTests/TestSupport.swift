import Foundation

@testable import OMEMO

enum TestInputError: Error {
    case badHex(String)
    case missingResource(String)
    case missingValue(String)
}

/// Bytes from a hex string. Whitespace is ignored, so long values can span lines.
func data(_ hex: String) throws -> Data {
    let digits = Array(hex.filter { !$0.isWhitespace })
    guard digits.count.isMultiple(of: 2) else { throw TestInputError.badHex(hex) }
    var result = Data()
    result.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
        guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
            throw TestInputError.badHex(hex)
        }
        result.append(byte)
    }
    return result
}

func optionalData(_ hex: String?) throws -> Data? {
    guard let hex else { return nil }
    return try data(hex)
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The session state as stored, to compare a session before and after a failed operation.
func snapshot(_ session: RatchetSession) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(session)
}

/// Data with one bit flipped.
func flipping(bit: Int, of value: Data) -> Data {
    var bytes = Array(value)
    bytes[bit / 8] ^= UInt8(1 << (bit % 8))
    return Data(bytes)
}

// MARK: - Two parties

/// Alice and Bob with fresh keys, Bob's bundle, and Alice's first message decrypted by Bob.
struct Conversation {
    var alice: RatchetSession
    var bob: RatchetSession
    let version: OMEMOVersion

    init(version: OMEMOVersion) throws {
        self.version = version
        let aliceIdentity = IdentityKeyPair.generate(version: version)
        let bobIdentity = IdentityKeyPair.generate(version: version)
        let signedPreKey = X25519KeyPair.generate()
        let preKey = X25519KeyPair.generate()
        let bundle = PreKeyBundle(
            identityKey: bobIdentity.publicKey,
            signedPreKeyID: 7,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeySignature: try bobIdentity.signPreKey(signedPreKey.publicKey),
            preKeys: [
                (id: 3, key: X25519KeyPair.generate().publicKey), (id: 9, key: preKey.publicKey),
            ]
        )
        let agreement = try X3DH.initiate(
            own: aliceIdentity, bundle: bundle, preKeyID: 9, version: version)
        var alice = try RatchetSession.initiator(
            sharedSecret: agreement.sharedSecret,
            remoteRatchetKey: signedPreKey.publicKey,
            ad: agreement.associatedData,
            version: version
        )
        let first = try alice.encrypt(Data("first".utf8))
        let keyExchange = KeyExchangeMessage(
            preKeyID: 9,
            signedPreKeyID: 7,
            identityKey: aliceIdentity.publicKey,
            ephemeralKey: agreement.ephemeral,
            message: first
        )

        let received = try KeyExchangeMessage(serialized: keyExchange.serialized, version: version)
        let response = try X3DH.respond(
            own: bobIdentity,
            signedPreKey: signedPreKey,
            preKey: preKey,
            remoteIdentityKey: received.identityKey,
            remoteEphemeral: received.ephemeralKey,
            version: version
        )
        var bob = try RatchetSession.responder(
            sharedSecret: response.sharedSecret,
            ownRatchetKeyPair: signedPreKey,
            ad: response.associatedData,
            version: version
        )
        let plaintext = try bob.decrypt(received.message)
        guard plaintext == Data("first".utf8) else { throw TestInputError.missingValue("first") }
        self.alice = alice
        self.bob = bob
    }
}

/// Sends through the wire format, as the other side receives it.
func transmit(_ message: RatchetMessage) throws -> RatchetMessage {
    try RatchetMessage(serialized: message.serialized, version: message.version)
}

// MARK: - Python vectors

/// The vectors written by scripts/omemo-vectors/generate.py.
struct OMEMOVectors: Decodable {
    struct KeyPair: Decodable {
        let privateKey: String
        let publicKey: String
    }

    struct SignedPreKey: Decodable {
        let id: UInt32
        let privateKey: String
        let publicKey: String
        let signature: String
    }

    struct PreKey: Decodable {
        let id: UInt32
        let privateKey: String
        let publicKey: String
    }

    struct X3DHVector: Decodable {
        let aliceIdentity: KeyPair
        let bobIdentity: KeyPair
        let signedPreKey: SignedPreKey
        let preKeys: [PreKey]
        let usedPreKeyID: UInt32
        let ephemeral: KeyPair
        let sharedSecret: String
        let associatedData: String
    }

    struct KDFVector: Decodable {
        let rootKey: String
        let dhOutput: String
        let nextRootKey: String
        let newChainKey: String
        let chainKey: String
        let nextChainKey: String
        let chainMessageKey: String
        let messageKey: String
        let encryptionKey: String
        let authenticationKey: String
        let iv: String
    }

    struct PayloadVector: Decodable {
        let plaintext: String
        let key: String
        let ciphertext: String
        let keyMaterial: String
        let iv: String?
    }

    struct Party: Decodable {
        let deviceID: UInt32
        let identity: KeyPair
        let signedPreKey: SignedPreKey
        let preKeys: [PreKey]
    }

    struct Message: Decodable {
        let sender: String
        let keyExchange: Bool
        let key: String
        let keyMaterial: String
        let payload: String?
        let iv: String?
        let plaintext: String?
    }

    struct Event: Decodable {
        let encrypt: Int?
        let decrypt: Int?
    }

    struct Session: Decodable {
        let name: String
        let alice: Party
        let bob: Party
        let aliceEphemeralKey: String
        let ratchetKeys: [String: [String]]
        let messages: [Message]
        let events: [Event]
    }

    struct Version: Decodable {
        let x3dh: [X3DHVector]
        let kdf: [KDFVector]
        let payload: [PayloadVector]
        let sessions: [Session]
        /// Legacy only: older Conversations' layout, tag after the ciphertext.
        let legacyPayload: [PayloadVector]?
    }

    /// Field values and the bytes python's protobuf serialized them to. Which fields are set
    /// depends on `type`.
    struct ProtobufFixture: Decodable {
        let type: String
        let encoded: String
        let n: UInt32?
        let pn: UInt32?
        let dhPub: String?
        let ciphertext: String?
        let mac: String?
        let message: String?
        let pkID: UInt32?
        let spkID: UInt32?
        let ik: String?
        let ek: String?
        let counter: UInt32?
        let previousCounter: UInt32?
        let ratchetKey: String?
        let preKeyID: UInt32?
        let signedPreKeyID: UInt32?
        let registrationID: UInt32?
        let identityKey: String?
        let baseKey: String?
    }

    let versions: [String: String]
    let protobuf: [ProtobufFixture]
    let v03: Version
    let v2: Version

    func vectors(for version: OMEMOVersion) -> Version {
        switch version {
        case .v03: v03
        case .v2: v2
        }
    }

    static func load() throws -> OMEMOVectors {
        guard let url = Bundle.module.url(forResource: "omemo-vectors", withExtension: "json")
        else {
            throw TestInputError.missingResource("omemo-vectors.json")
        }
        return try JSONDecoder().decode(OMEMOVectors.self, from: Data(contentsOf: url))
    }
}

func require<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw TestInputError.missingValue(name) }
    return value
}

extension OMEMOVectors.KeyPair {
    func identity(version: OMEMOVersion) throws -> IdentityKeyPair {
        let pair = try IdentityKeyPair(privateKey: try data(privateKey), version: version)
        guard pair.publicKey == (try data(publicKey)) else {
            throw TestInputError.missingValue("identity public key")
        }
        return pair
    }
}

extension OMEMOVectors.SignedPreKey {
    func keyPair() throws -> X25519KeyPair {
        try X25519KeyPair(privateKey: try data(privateKey))
    }
}

extension OMEMOVectors.PreKey {
    func keyPair() throws -> X25519KeyPair {
        try X25519KeyPair(privateKey: try data(privateKey))
    }
}

extension OMEMOVectors.Party {
    func bundle() throws -> PreKeyBundle {
        PreKeyBundle(
            identityKey: try data(identity.publicKey),
            signedPreKeyID: signedPreKey.id,
            signedPreKey: try data(signedPreKey.publicKey),
            signedPreKeySignature: try data(signedPreKey.signature),
            preKeys: try preKeys.map { (id: $0.id, key: try data($0.publicKey)) }
        )
    }
}
