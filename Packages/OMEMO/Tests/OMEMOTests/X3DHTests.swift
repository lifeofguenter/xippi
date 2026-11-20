import CryptoKit
import Foundation
import Testing

@testable import OMEMO

@Suite struct X3DHTests {
    /// python-x3dh as python-oldmemo and python-twomemo configure it: same shared secret and
    /// associated data on both sides, from the same keys.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func matchesPythonVectors(version: OMEMOVersion) throws {
        let vectors = try OMEMOVectors.load().vectors(for: version)
        #expect(!vectors.x3dh.isEmpty)
        for (index, vector) in vectors.x3dh.enumerated() {
            let alice = try vector.aliceIdentity.identity(version: version)
            let bob = try vector.bobIdentity.identity(version: version)
            let bundle = PreKeyBundle(
                identityKey: bob.publicKey,
                signedPreKeyID: vector.signedPreKey.id,
                signedPreKey: try data(vector.signedPreKey.publicKey),
                signedPreKeySignature: try data(vector.signedPreKey.signature),
                preKeys: try vector.preKeys.map { (id: $0.id, key: try data($0.publicKey)) }
            )
            #expect(bundle.hasValidSignature(version: version), "vector \(index)")

            let initiated = try X3DH.initiate(
                own: alice, bundle: bundle, preKeyID: vector.usedPreKeyID, version: version,
                ephemeralPrivateKey: try data(vector.ephemeral.privateKey))
            #expect(initiated.sharedSecret.hex == vector.sharedSecret, "vector \(index)")
            #expect(initiated.associatedData.hex == vector.associatedData, "vector \(index)")
            #expect(initiated.ephemeral.hex == vector.ephemeral.publicKey, "vector \(index)")

            let preKey = try require(
                vector.preKeys.first { $0.id == vector.usedPreKeyID }, "pre key")
            let responded = try X3DH.respond(
                own: bob,
                signedPreKey: try X25519KeyPair(
                    privateKey: try data(vector.signedPreKey.privateKey)),
                preKey: try preKey.keyPair(),
                remoteIdentityKey: alice.publicKey,
                remoteEphemeral: try data(vector.ephemeral.publicKey),
                version: version
            )
            #expect(responded.sharedSecret.hex == vector.sharedSecret, "vector \(index)")
            #expect(responded.associatedData.hex == vector.associatedData, "vector \(index)")
        }
    }

    /// Legacy associated data is both identity keys with the 0x05 type byte; OMEMO 2's is both
    /// Ed25519 keys as they are.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func associatedDataLayout(version: OMEMOVersion) throws {
        let alice = IdentityKeyPair.generate(version: version)
        let (bundle, bob, signedPreKey, preKey) = try makeBundle(version: version)
        let initiated = try X3DH.initiate(own: alice, bundle: bundle, preKeyID: 5, version: version)
        let expected =
            version == .v03
            ? Data([0x05]) + alice.publicKey + Data([0x05]) + bob.publicKey
            : alice.publicKey + bob.publicKey
        #expect(initiated.associatedData == expected)

        let responded = try X3DH.respond(
            own: bob, signedPreKey: signedPreKey, preKey: preKey,
            remoteIdentityKey: alice.publicKey, remoteEphemeral: initiated.ephemeral,
            version: version)
        #expect(responded.sharedSecret == initiated.sharedSecret)
        #expect(responded.associatedData == initiated.associatedData)
        #expect(initiated.sharedSecret.count == 32)
    }

    /// Legacy bundles carry the Edwards sign bit in the signature's top bit; libsignal's own test
    /// vector is exactly an identity key signing a serialized key.
    @Test func libsignalBundleSignatureVerifies() throws {
        let identityKey = try data(
            "05ab7e717d4a163b7d9a1d8071dfe9dcf8cdcd1cea3339b6356be84d887e322c64")
        let signedPreKey = try data(
            "05edce9d9c415ca78cb7252e72c2c4a554d3eb29485a0e1d503118d1a82d99fb4a")
        let signature = try data(
            """
            5de88ca9a89b4a115da79109c67c9c7464a3e4180274f1cb8c63c2984e286dfb
            ede82deb9dcd9fae0bfbb821569b3d9001bd8130cd11d486cef047bd60b86e88
            """)
        var bundle = PreKeyBundle(
            identityKey: try OMEMOVersion.v03.decodePublicKey(identityKey),
            signedPreKeyID: 1,
            signedPreKey: try OMEMOVersion.v03.decodePublicKey(signedPreKey),
            signedPreKeySignature: signature,
            preKeys: []
        )
        #expect(bundle.hasValidSignature(version: .v03))
        bundle.signedPreKeySignature[63] &= 0x7F
        #expect(!bundle.hasValidSignature(version: .v03))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func ownSignaturesVerify(version: OMEMOVersion) throws {
        for _ in 0..<8 {
            let (bundle, _, _, _) = try makeBundle(version: version)
            #expect(bundle.hasValidSignature(version: version))
        }
    }

    /// OMEMO 2 publishes plain Ed25519 signatures over the raw key.
    @Test func v2SignatureIsEd25519() throws {
        let identity = IdentityKeyPair.generate(version: .v2)
        let key = X25519KeyPair.generate().publicKey
        let signature = try identity.signPreKey(key)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.publicKey)
        #expect(publicKey.isValidSignature(signature, for: key))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func badSignatureRejected(version: OMEMOVersion) throws {
        let alice = IdentityKeyPair.generate(version: version)
        let (bundle, _, _, _) = try makeBundle(version: version)
        for bit in [0, 100, 255, 256, 400, 511] {
            var forged = bundle
            forged.signedPreKeySignature = flipping(bit: bit, of: bundle.signedPreKeySignature)
            #expect(!forged.hasValidSignature(version: version), "bit \(bit)")
            #expect(throws: X3DHError.invalidSignature) {
                try X3DH.initiate(own: alice, bundle: forged, preKeyID: 5, version: version)
            }
        }
        var otherKey = bundle
        otherKey.signedPreKey = X25519KeyPair.generate().publicKey
        #expect(throws: X3DHError.invalidSignature) {
            try X3DH.initiate(own: alice, bundle: otherKey, preKeyID: 5, version: version)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func unknownPreKeyRejected(version: OMEMOVersion) throws {
        let alice = IdentityKeyPair.generate(version: version)
        let (bundle, _, _, _) = try makeBundle(version: version)
        #expect(throws: X3DHError.unknownPreKey) {
            try X3DH.initiate(own: alice, bundle: bundle, preKeyID: 6, version: version)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func invalidKeysRejected(version: OMEMOVersion) throws {
        let alice = IdentityKeyPair.generate(version: version)
        let (bundle, bob, signedPreKey, preKey) = try makeBundle(version: version)

        var short = bundle
        short.identityKey = Data(bundle.identityKey.dropLast())
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.initiate(own: alice, bundle: short, preKeyID: 5, version: version)
        }
        var shortPreKey = bundle
        shortPreKey.preKeys = [(id: 5, key: Data(count: 31))]
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.initiate(own: alice, bundle: shortPreKey, preKeyID: 5, version: version)
        }
        // A pre key of small order gives an all-zero Diffie-Hellman output.
        var smallOrder = bundle
        smallOrder.preKeys = [(id: 5, key: Data(count: 32))]
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.initiate(own: alice, bundle: smallOrder, preKeyID: 5, version: version)
        }
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.respond(
                own: bob, signedPreKey: signedPreKey, preKey: preKey,
                remoteIdentityKey: alice.publicKey, remoteEphemeral: Data(count: 32),
                version: version)
        }
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.respond(
                own: bob, signedPreKey: signedPreKey, preKey: preKey,
                remoteIdentityKey: Data(alice.publicKey.dropFirst()),
                remoteEphemeral: X25519KeyPair.generate().publicKey, version: version)
        }
        #expect(throws: X3DHError.invalidKey) {
            try X25519KeyPair(privateKey: Data(count: 33))
        }
        #expect(throws: X3DHError.invalidKey) {
            try IdentityKeyPair(privateKey: Data(count: 16), version: version)
        }
    }

    /// An Ed25519 identity key that is not a point of prime order cannot be converted for X3DH.
    /// A bundle with one fails its signature check first; a key exchange with one fails the
    /// conversion.
    @Test func v2IdentityKeyOfSmallOrderRejected() throws {
        let alice = IdentityKeyPair.generate(version: .v2)
        let (bundle, bob, signedPreKey, preKey) = try makeBundle(version: .v2)
        var identity = Data(count: 32)
        identity[0] = 1  // the identity point, y = 1
        var forged = bundle
        forged.identityKey = identity
        #expect(throws: X3DHError.invalidSignature) {
            try X3DH.initiate(own: alice, bundle: forged, preKeyID: 5, version: .v2)
        }
        #expect(throws: X3DHError.invalidKey) {
            try X3DH.respond(
                own: bob, signedPreKey: signedPreKey, preKey: preKey, remoteIdentityKey: identity,
                remoteEphemeral: X25519KeyPair.generate().publicKey, version: .v2)
        }
    }

    @Test func versionMismatchRejected() throws {
        let alice = IdentityKeyPair.generate(version: .v03)
        let (bundle, _, _, _) = try makeBundle(version: .v2)
        #expect(throws: X3DHError.versionMismatch) {
            try X3DH.initiate(own: alice, bundle: bundle, preKeyID: 5, version: .v2)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func identityKeyPairCodableAndDescription(version: OMEMOVersion) throws {
        let identity = IdentityKeyPair.generate(version: version)
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(IdentityKeyPair.self, from: encoded)
        #expect(decoded.privateKey == identity.privateKey)
        #expect(decoded.publicKey == identity.publicKey)
        #expect(decoded.version == version)

        let secrets = [identity.privateKey.hex, identity.privateKey.base64EncodedString()]
        var dumped = ""
        dump(identity, to: &dumped)
        for text in [String(describing: identity), String(reflecting: identity), dumped] {
            for secret in secrets {
                #expect(!text.contains(secret))
            }
        }

        // A stored public key that does not belong to the private key is corrupt.
        let other = IdentityKeyPair.generate(version: version)
        let mismatched = """
            {"privateKey":"\(identity.privateKey.base64EncodedString())",\
            "publicKey":"\(other.publicKey.base64EncodedString())",\
            "version":"\(version.rawValue)"}
            """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IdentityKeyPair.self, from: Data(mismatched.utf8))
        }
    }

    @Test func keyPairDescriptionHidesPrivateKey() throws {
        let pair = X25519KeyPair.generate()
        var dumped = ""
        dump(pair, to: &dumped)
        for text in [String(describing: pair), String(reflecting: pair), dumped] {
            #expect(!text.contains(pair.privateKey.hex))
            #expect(!text.contains(pair.privateKey.base64EncodedString()))
        }
        let decoded = try JSONDecoder().decode(
            X25519KeyPair.self, from: try JSONEncoder().encode(pair))
        #expect(decoded.publicKey == pair.publicKey)
    }

    @Test func publicKeyWireEncoding() throws {
        let key = X25519KeyPair.generate().publicKey
        #expect(OMEMOVersion.v03.encodePublicKey(key) == Data([0x05]) + key)
        #expect(OMEMOVersion.v2.encodePublicKey(key) == key)
        #expect(try OMEMOVersion.v03.decodePublicKey(Data([0x05]) + key) == key)
        #expect(try OMEMOVersion.v2.decodePublicKey(key) == key)
        #expect(throws: MessageFormatError.invalidKey) {
            try OMEMOVersion.v03.decodePublicKey(key)
        }
        #expect(throws: MessageFormatError.invalidKey) {
            try OMEMOVersion.v03.decodePublicKey(Data([0x06]) + key)
        }
        #expect(throws: MessageFormatError.invalidKey) {
            try OMEMOVersion.v2.decodePublicKey(Data([0x05]) + key)
        }
    }

    /// Bob's bundle with pre keys 5 and 8, and the keys behind it.
    private func makeBundle(
        version: OMEMOVersion
    ) throws -> (PreKeyBundle, IdentityKeyPair, X25519KeyPair, X25519KeyPair) {
        let bob = IdentityKeyPair.generate(version: version)
        let signedPreKey = X25519KeyPair.generate()
        let preKey = X25519KeyPair.generate()
        let bundle = PreKeyBundle(
            identityKey: bob.publicKey,
            signedPreKeyID: 1,
            signedPreKey: signedPreKey.publicKey,
            signedPreKeySignature: try bob.signPreKey(signedPreKey.publicKey),
            preKeys: [
                (id: 5, key: preKey.publicKey), (id: 8, key: X25519KeyPair.generate().publicKey),
            ]
        )
        return (bundle, bob, signedPreKey, preKey)
    }
}
