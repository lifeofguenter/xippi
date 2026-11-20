import Foundation
import Testing
import XMPPCore

@testable import OMEMO

/// `omemo-stanzas.json`: what python-oldmemo and python-twomemo (python-omemo's backends) put
/// on the wire, serialized by their etree modules. See `scripts/omemo-vectors/generate.py`.
struct StanzaFixtures: Decodable {
    struct Form: Decodable {
        let ed25519: String
        let curve25519: String
    }

    struct KeyPair: Decodable {
        let privateKey: String
        let publicKey: String
    }

    struct SignedKey: Decodable {
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

    /// The python-omemo device that sends.
    struct Sender: Decodable {
        let jid: String
        let deviceID: UInt32
        /// As its bundle carries it (legacy with the 0x05 type byte).
        let identityKey: String
        let deviceList: String
        let deviceListIDs: [UInt32]
        let bundle: String
    }

    /// The device Xippi plays, with the private keys python-omemo made for it.
    struct Receiver: Decodable {
        let jid: String
        let deviceID: UInt32
        let identity: KeyPair
        let signedPreKey: SignedKey
        let preKeys: [PreKey]
        let bundle: String
    }

    struct Message: Decodable {
        let stanza: String
        /// Nil for an empty OMEMO message.
        let body: String?
    }

    struct Version: Decodable {
        let alice: Sender
        let bob: Receiver
        let messages: [Message]
    }

    let curve25519Forms: [Form]
    let v03: Version
    let v2: Version

    subscript(version: OMEMOVersion) -> Version {
        switch version {
        case .v03: v03
        case .v2: v2
        }
    }

    static func load() throws -> StanzaFixtures {
        guard let url = Bundle.module.url(forResource: "omemo-stanzas", withExtension: "json")
        else {
            throw TestInputError.missingResource("omemo-stanzas.json")
        }
        return try JSONDecoder().decode(StanzaFixtures.self, from: Data(contentsOf: url))
    }
}

@Suite struct RecordedStanzaTests {
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func decryptsRecordedMessagesFromOtherClients(version: OMEMOVersion) async throws {
        let fixture = try StanzaFixtures.load()[version]
        let pep = FakePEP()
        let clock = TestClock()
        let alice = try JID(fixture.alice.jid)
        let bob = try JID(fixture.bob.jid)

        // python-omemo's device list and bundles read as ours.
        let list = try element(fixture.alice.deviceList)
        #expect(DeviceList.deviceIDs(in: list, version: version) == fixture.alice.deviceListIDs)
        let aliceBundle = try element(fixture.alice.bundle)
        let parsedAlice = try #require(OMEMOBundle.parse(aliceBundle, version: version))
        #expect(parsedAlice.hasValidSignature(version: version))
        #expect(
            version.encodePublicKey(parsedAlice.identityKey)
                == (try data(fixture.alice.identityKey)))
        let bobBundle = try #require(
            OMEMOBundle.parse(try element(fixture.bob.bundle), version: version))
        #expect(bobBundle.hasValidSignature(version: version))
        #expect(bobBundle.identityKey == (try data(fixture.bob.identity.publicKey)))
        #expect(bobBundle.signedPreKeyID == fixture.bob.signedPreKey.id)
        #expect(bobBundle.signedPreKey == (try data(fixture.bob.signedPreKey.publicKey)))
        #expect(bobBundle.preKeys.map(\.id) == fixture.bob.preKeys.map(\.id))
        await pep.setList(list, of: alice, version: version)
        await pep.setBundle(
            aliceBundle, of: alice, deviceID: fixture.alice.deviceID, version: version)

        // Xippi plays Bob, with the keys python-omemo made for him.
        let store = MemoryStore()
        let identity = try IdentityKeyPair(
            privateKey: try data(fixture.bob.identity.privateKey), version: version)
        #expect(identity.publicKey == (try data(fixture.bob.identity.publicKey)))
        await store.saveOwnIdentity(
            OwnIdentity(
                deviceID: fixture.bob.deviceID, identityKeyPair: identity,
                registrationID: version == .v03 ? fixture.bob.deviceID : nil,
                signedPreKeyID: fixture.bob.signedPreKey.id,
                nextPreKeyID: (fixture.bob.preKeys.map(\.id).max() ?? 0) + 1),
            version: version)
        await store.saveSignedPreKey(
            SignedPreKey(
                id: fixture.bob.signedPreKey.id,
                keyPair: try X25519KeyPair(
                    privateKey: try data(fixture.bob.signedPreKey.privateKey)),
                signature: try data(fixture.bob.signedPreKey.signature), createdAt: clock.now),
            version: version)
        await store.savePreKeys(
            try fixture.bob.preKeys.map {
                OneTimePreKey(
                    id: $0.id, keyPair: try X25519KeyPair(privateKey: try data($0.privateKey)))
            }, version: version)
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: pep), accountJID: bob, now: { clock.now })

        // The bundle Xippi publishes for these keys says what python-omemo's says.
        let ours = try #require(
            OMEMOBundle.parse(try await engine.ownBundle(version: version), version: version))
        #expect(ours.identityKey == bobBundle.identityKey)
        #expect(ours.signedPreKey == bobBundle.signedPreKey)
        #expect(ours.signedPreKeySignature == bobBundle.signedPreKeySignature)
        #expect(ours.preKeys.map(\.key) == bobBundle.preKeys.map(\.key))

        // Every recorded message: the key exchange, its repeat, the empty message.
        let fingerprint = engine.fingerprint(
            of: try data(fixture.alice.identityKey), version: version)
        for message in fixture.messages {
            let stanza = try element(message.stanza)
            let encrypted = try #require(stanza.child("encrypted", namespace: version.rawValue))
            let result = try await engine.decrypt(
                encrypted, from: alice, version: version, recipient: .direct(bob))
            if let body = message.body {
                #expect(result.body == body)
            } else {
                #expect(result.content == .empty)
            }
            #expect(result.sender == DeviceAddress(jid: alice, deviceID: fixture.alice.deviceID))
            #expect(result.fingerprint == fingerprint)
            #expect(result.senderTrust == .trusted)
        }
        let preKeys = await store.preKeyIDs(version: version)
        #expect(!preKeys.contains(fixture.bob.preKeys[0].id))
        #expect(preKeys.count == OMEMOEngine.preKeyCount)

        // A session from python-omemo's bundle: a new device of another account writes to Alice.
        // Her second listed device has no bundle and is left out.
        let carol = OMEMOEngine(
            store: MemoryStore(), transport: PEPTransport(pep: pep),
            accountJID: try JID("carol@example.org"), now: { clock.now })
        _ = try await carol.ensureOwnDevice(version: version)
        let sent = try await carol.encrypt(
            MessageContent(body: "hi"), to: [alice], version: version)
        #expect(keyedDevices(sent, version: version) == [fixture.alice.deviceID])
        #expect(isKeyExchange(sent, for: fixture.alice.deviceID, version: version) == true)
    }

    /// XEP-0384 section 8: the fingerprint is the identity key in its Curve25519 form, so one
    /// identity shows one fingerprint in both versions. python-omemo keeps one identity for both.
    @Test func fingerprintsUseTheCurve25519Form() throws {
        let fixtures = try StanzaFixtures.load()
        let engine = OMEMOEngine(
            store: MemoryStore(), transport: PEPTransport(pep: FakePEP()),
            accountJID: try JID("alice@example.org"))
        func grouped(_ hex: String) -> String {
            stride(from: 0, to: hex.count, by: 8).map {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                return String(hex[start..<hex.index(start, offsetBy: 8)])
            }.joined(separator: " ")
        }
        #expect(fixtures.curve25519Forms.count == 4)
        for form in fixtures.curve25519Forms {
            let curve = try data(form.curve25519)
            #expect(
                engine.fingerprint(of: try data(form.ed25519), version: .v2)
                    == grouped(form.curve25519))
            #expect(engine.fingerprint(of: curve, version: .v03) == grouped(form.curve25519))
            #expect(
                engine.fingerprint(of: Data([0x05]) + curve, version: .v03)
                    == grouped(form.curve25519))
        }
        let legacy = engine.fingerprint(of: try data(fixtures.v03.alice.identityKey), version: .v03)
        #expect(legacy != nil)
        #expect(
            legacy == engine.fingerprint(of: try data(fixtures.v2.alice.identityKey), version: .v2))

        // Keys that are not identity keys have no fingerprint.
        #expect(engine.fingerprint(of: Data(count: 31), version: .v03) == nil)
        #expect(engine.fingerprint(of: Data(count: 32), version: .v2) == nil)
    }

    /// The OMEMO 2 fingerprint is the X25519 public key X3DH computes with.
    @Test func v2FingerprintIsTheKeyX3DHUses() async throws {
        let net = TestNetwork(version: .v2)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let result = try await net.deliver(
            try await net.send("hi", from: alice, to: [bob.jid]), from: alice, to: bob)
        let identity = try #require(await alice.store.ownIdentity(version: .v2)?.identityKeyPair)
        let agreement = try #require(
            Primitives.x25519PublicKey(privateKey: identity.agreementPrivateKey))
        let expected = stride(from: 0, to: 64, by: 8).map {
            let hex = agreement.hex
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[start..<hex.index(start, offsetBy: 8)])
        }.joined(separator: " ")
        #expect(result.fingerprint == expected)
        #expect(alice.engine.fingerprint(of: identity.publicKey, version: .v2) == expected)
    }
}
