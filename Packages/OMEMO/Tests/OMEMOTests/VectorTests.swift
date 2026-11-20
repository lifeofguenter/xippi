import CurveMath
import Foundation
import Testing

@testable import OMEMO

/// Replays a session python-oldmemo or python-twomemo ran (scripts/omemo-vectors). Each party
/// takes its ratchet keys from the transcript, so its state matches python's at every step.
struct SessionReplay {
    let version: OMEMOVersion
    let vector: OMEMOVectors.Session
    private var sessions: [String: RatchetSession] = [:]
    private var ratchetKeys: [String: [X25519KeyPair]] = [:]
    private var keyExchangeEphemeral: Data?
    private let identities: [String: IdentityKeyPair]

    init(_ vector: OMEMOVectors.Session, version: OMEMOVersion) throws {
        self.version = version
        self.vector = vector
        identities = [
            "alice": try vector.alice.identity.identity(version: version),
            "bob": try vector.bob.identity.identity(version: version),
        ]
        for (party, keys) in vector.ratchetKeys {
            ratchetKeys[party] = try keys.map { try X25519KeyPair(privateKey: try data($0)) }
        }
    }

    /// Every ratchet key python generated was used, in the same order.
    var usedEveryRatchetKey: Bool { ratchetKeys.values.allSatisfy(\.isEmpty) }

    private mutating func nextRatchetKey(_ party: String) -> X25519KeyPair {
        guard var keys = ratchetKeys[party], !keys.isEmpty else { return X25519KeyPair.generate() }
        let key = keys.removeFirst()
        ratchetKeys[party] = keys
        return key
    }

    /// Encrypts message `index` as its sender and returns the key element python sent. With
    /// `onlyStartSession`, only the initiator's first message does anything: it starts the session
    /// the initiator later decrypts with.
    mutating func encrypt(_ index: Int, onlyStartSession: Bool = false) throws -> Data? {
        let message = vector.messages[index]
        let sender = message.sender
        let expected = try data(message.key)
        var keyExchange: KeyExchangeMessage?
        if message.keyExchange {
            keyExchange = try KeyExchangeMessage(serialized: expected, version: version)
        }
        if sessions[sender] == nil {
            let bundle = try vector.bob.bundle()
            let preKeyID = try require(keyExchange, "key exchange").preKeyID
            let agreement = try X3DH.initiate(
                own: try require(identities[sender], sender),
                bundle: bundle,
                preKeyID: preKeyID,
                version: version,
                ephemeralPrivateKey: try data(vector.aliceEphemeralKey)
            )
            sessions[sender] = try RatchetSession.initiator(
                sharedSecret: agreement.sharedSecret,
                remoteRatchetKey: bundle.signedPreKey,
                ad: agreement.associatedData,
                version: version,
                ratchetKeyPair: nextRatchetKey(sender)
            )
            keyExchangeEphemeral = agreement.ephemeral
        }
        if onlyStartSession { return nil }
        var session = try require(sessions[sender], sender)
        let ratchetMessage = try session.encrypt(try data(message.keyMaterial))
        sessions[sender] = session
        guard let keyExchange else { return ratchetMessage.serialized }
        return KeyExchangeMessage(
            preKeyID: keyExchange.preKeyID,
            signedPreKeyID: keyExchange.signedPreKeyID,
            identityKey: try require(identities[sender], sender).publicKey,
            ephemeralKey: try require(keyExchangeEphemeral, "ephemeral key"),
            message: ratchetMessage
        ).serialized
    }

    /// Decrypts python's message `index` as its recipient and returns the key material.
    mutating func decrypt(_ index: Int) throws -> Data {
        let message = vector.messages[index]
        let receiver = message.sender == "alice" ? "bob" : "alice"
        let serialized = try data(message.key)
        let ratchetMessage: RatchetMessage
        if message.keyExchange {
            let keyExchange = try KeyExchangeMessage(serialized: serialized, version: version)
            ratchetMessage = keyExchange.message
            if sessions[receiver] == nil || keyExchangeEphemeral != keyExchange.ephemeralKey {
                let party = vector.bob
                let signedPreKey = try party.signedPreKey.keyPair()
                #expect(keyExchange.signedPreKeyID == party.signedPreKey.id)
                let preKey = try require(
                    party.preKeys.first { $0.id == keyExchange.preKeyID }, "pre key"
                ).keyPair()
                let response = try X3DH.respond(
                    own: try require(identities[receiver], receiver),
                    signedPreKey: signedPreKey,
                    preKey: preKey,
                    remoteIdentityKey: keyExchange.identityKey,
                    remoteEphemeral: keyExchange.ephemeralKey,
                    version: version
                )
                sessions[receiver] = try RatchetSession.responder(
                    sharedSecret: response.sharedSecret,
                    ownRatchetKeyPair: signedPreKey,
                    ad: response.associatedData,
                    version: version
                )
                keyExchangeEphemeral = keyExchange.ephemeralKey
            }
        } else {
            ratchetMessage = try RatchetMessage(serialized: serialized, version: version)
        }
        var session = try require(sessions[receiver], receiver)
        var keys = ratchetKeys[receiver] ?? []
        let keyMaterial = try session.decrypt(ratchetMessage) {
            keys.isEmpty ? X25519KeyPair.generate() : keys.removeFirst()
        }
        ratchetKeys[receiver] = keys
        sessions[receiver] = session
        return keyMaterial
    }
}

@Suite struct VectorTests {
    /// Every message of every python session, both versions, decrypts here, and its payload too.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func vectorsDecrypt(version: OMEMOVersion) throws {
        let vectors = try OMEMOVectors.load().vectors(for: version)
        #expect(vectors.sessions.count == 3)
        for session in vectors.sessions {
            var replay = try SessionReplay(session, version: version)
            var decrypted = 0
            for event in session.events {
                if let index = event.encrypt {
                    _ = try replay.encrypt(index, onlyStartSession: true)
                }
                guard let index = event.decrypt else { continue }
                let message = session.messages[index]
                let keyMaterial = try replay.decrypt(index)
                #expect(keyMaterial.hex == message.keyMaterial, "\(session.name) \(index)")
                if let payload = message.payload {
                    let plaintext = try PayloadCipher.decrypt(
                        try data(payload),
                        iv: try optionalData(message.iv),
                        keyMaterial: keyMaterial,
                        version: version
                    )
                    #expect(plaintext.hex == message.plaintext, "\(session.name) \(index)")
                } else if version == .v2 {
                    #expect(keyMaterial == Data(count: 32), "\(session.name) \(index)")
                }
                decrypted += 1
            }
            #expect(decrypted == session.messages.count, "\(session.name)")
            #expect(replay.usedEveryRatchetKey, "\(session.name)")
        }
    }

    /// With python's ratchet and ephemeral keys, our sessions send the bytes python sent.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func vectorsEncryptByteForByte(version: OMEMOVersion) throws {
        let vectors = try OMEMOVectors.load().vectors(for: version)
        for session in vectors.sessions {
            var replay = try SessionReplay(session, version: version)
            for event in session.events {
                if let index = event.encrypt {
                    let sent = try replay.encrypt(index)
                    #expect(sent?.hex == session.messages[index].key, "\(session.name) \(index)")
                }
                if let index = event.decrypt {
                    _ = try replay.decrypt(index)
                }
            }
            #expect(replay.usedEveryRatchetKey, "\(session.name)")
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func kdfMatchesPython(version: OMEMOVersion) throws {
        let vectors = try OMEMOVectors.load().vectors(for: version)
        #expect(!vectors.kdf.isEmpty)
        for vector in vectors.kdf {
            let root = KDF.rootStep(
                rootKey: try data(vector.rootKey), dhOutput: try data(vector.dhOutput),
                version: version)
            #expect(root.rootKey.hex == vector.nextRootKey)
            #expect(root.chainKey.hex == vector.newChainKey)

            let chain = KDF.chainStep(try data(vector.chainKey))
            #expect(chain.chainKey.hex == vector.nextChainKey)
            #expect(chain.messageKey.hex == vector.chainMessageKey)

            let keys = KDF.messageKeys(try data(vector.messageKey), version: version)
            #expect(keys.encryptionKey.hex == vector.encryptionKey)
            #expect(keys.authenticationKey.hex == vector.authenticationKey)
            #expect(keys.iv.hex == vector.iv)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func payloadMatchesPython(version: OMEMOVersion) throws {
        let vectors = try OMEMOVectors.load().vectors(for: version)
        #expect(!vectors.payload.isEmpty)
        for vector in vectors.payload {
            let iv = try optionalData(vector.iv)
            #expect((iv != nil) == (version == .v03))
            let plaintext = try PayloadCipher.decrypt(
                try data(vector.ciphertext), iv: iv,
                keyMaterial: try data(vector.keyMaterial), version: version)
            #expect(plaintext.hex == vector.plaintext)

            let encrypted = try PayloadCipher.encrypt(
                try data(vector.plaintext), version: version, key: try data(vector.key), iv: iv)
            #expect(encrypted.ciphertext.hex == vector.ciphertext)
            #expect(encrypted.keyMaterial.hex == vector.keyMaterial)
            #expect(encrypted.iv == iv)
        }
    }

    /// Older Conversations releases put the GCM tag after the ciphertext, sent only the 16-byte
    /// key, and used 16-byte IVs; python cryptography (OpenSSL) made these.
    @Test func legacyPayloadLayoutMatchesPython() throws {
        let vectors = try require(OMEMOVectors.load().v03.legacyPayload, "legacyPayload")
        #expect(Set(vectors.compactMap { $0.iv?.count }) == [24, 32])
        for vector in vectors {
            let keyMaterial = try data(vector.keyMaterial)
            #expect(keyMaterial.count == 16)
            let plaintext = try PayloadCipher.decrypt(
                try data(vector.ciphertext), iv: try optionalData(vector.iv),
                keyMaterial: keyMaterial, version: .v03)
            #expect(plaintext.hex == vector.plaintext)
        }
    }

    /// libsignal-protocol-c's own XEdDSA test vector (test_curve25519_signature, the same bytes as
    /// libsignal-protocol-java's Curve25519Test): an identity key signing a serialized key, with
    /// bit 511 of the signature carrying the Edwards sign bit, as legacy OMEMO bundles do.
    @Test func libsignalXEdDSAVectorVerifies() throws {
        let identityKey = try data(
            "05ab7e717d4a163b7d9a1d8071dfe9dcf8cdcd1cea3339b6356be84d887e322c64")
        let message = try data(
            "05edce9d9c415ca78cb7252e72c2c4a554d3eb29485a0e1d503118d1a82d99fb4a")
        let signature = try data(
            """
            5de88ca9a89b4a115da79109c67c9c7464a3e4180274f1cb8c63c2984e286dfb
            ede82deb9dcd9fae0bfbb821569b3d9001bd8130cd11d486cef047bd60b86e88
            """)
        #expect(signature[63] & 0x80 != 0)
        let publicKey = Data(identityKey.dropFirst())
        #expect(
            XEdDSA.verify(signature: signature, message: message, montgomeryPublicKey: publicKey))

        var cleared = signature
        cleared[63] &= 0x7F
        #expect(
            !XEdDSA.verify(signature: cleared, message: message, montgomeryPublicKey: publicKey))
    }
}
