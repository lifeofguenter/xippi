import CurveMath
import Foundation
import Testing
import XMPPCore

@testable import OMEMO

/// Ruling R60: trust belongs to the identity key, not to a device in one OMEMO version.
@Suite(.timeLimit(.minutes(1))) struct EngineIdentityTrustTests {
    /// Devices of both versions on one fake PEP.
    struct Net {
        let pep = FakePEP()
        let clock = TestClock()

        /// A device of `jid` in `versions`, with id `id` (random when nil). With both versions
        /// and `sameIdentity`, the legacy identity is the X25519 form of the OMEMO 2 one, as a
        /// client that keeps one identity for both publishes it. With `madeByEngine`, the
        /// engine makes its own keys, as for this Mac's device.
        func device(
            _ jid: String, id: UInt32? = nil, versions: [OMEMOVersion] = OMEMOVersion.allCases,
            sameIdentity: Bool = true, madeByEngine: Bool = false
        ) async throws -> TestDevice {
            let jid = try JID(jid)
            let store = MemoryStore()
            let modern = IdentityKeyPair.generate(version: .v2)
            let id = id ?? UInt32.random(in: 1...0x7FFF_FFFF)
            for version in versions where !madeByEngine {
                let pair =
                    version == .v2 || !sameIdentity
                    ? (version == .v2 ? modern : IdentityKeyPair.generate(version: .v03))
                    : try IdentityKeyPair(
                        privateKey: KeyConversion.montgomeryPrivate(
                            fromEd25519Seed: modern.privateKey),
                        version: .v03)
                await store.saveOwnIdentity(
                    OwnIdentity(
                        deviceID: id, identityKeyPair: pair,
                        registrationID: version == .v03 ? id : nil, signedPreKeyID: 0,
                        nextPreKeyID: 1),
                    version: version)
            }
            let clock = self.clock
            let engine = OMEMOEngine(
                store: store, transport: PEPTransport(pep: pep), accountJID: jid,
                now: { clock.now })
            var made: UInt32?
            for version in versions {
                let own = try await engine.ensureOwnDevice(version: version)
                #expect(madeByEngine ? made.map { $0 == own } ?? true : own == id)
                made = own
                await pep.setBundle(
                    try await engine.ownBundle(version: version), of: jid, deviceID: own,
                    version: version)
                let listed = await listed(jid, version: version)
                await pep.setList(
                    engine.deviceListElement(version: version, devices: listed + [own]), of: jid,
                    version: version)
            }
            return TestDevice(jid: jid, engine: engine, store: store, id: made ?? id)
        }

        func listed(_ jid: JID, version: OMEMOVersion) async -> [UInt32] {
            guard let list = await pep.list(of: jid, version: version) else { return [] }
            return list.elements.compactMap { $0[attribute: "id"].flatMap { UInt32($0) } }
        }

        /// `observer` reads `jid`'s current lists in both versions.
        func notify(_ observer: TestDevice, about jid: JID) async throws {
            for version in OMEMOVersion.allCases {
                guard let list = await pep.list(of: jid, version: version) else { continue }
                _ = try await observer.engine.processDeviceList(list, from: jid, version: version)
            }
        }

        func send(_ body: String, from sender: TestDevice, to jid: JID, version: OMEMOVersion)
            async throws -> Element
        {
            try await sender.engine.encrypt(MessageContent(body: body), to: [jid], version: version)
        }
    }

    static func keyed(_ encrypted: Element, version: OMEMOVersion) -> Set<UInt32> {
        Set(keyRecipients(encrypted, version: version).values.flatMap { $0 })
    }

    @Test func aVerifiedContactsNewLegacyOnlyIdentityGetsNoKeysAndIsFlagged() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        _ = try await net.send("hello", from: alice, to: bob.jid, version: .v2)
        try await alice.engine.setTrust(.verified, for: bob.address, version: .v2)

        // A device bob's account never had appears in his legacy list only, with a key of its
        // own (someone with his password, or his server).
        let other = try await net.device("bob@example.org", versions: [.v03])
        try await net.notify(alice, about: bob.jid)

        let legacy = try await net.send("which", from: alice, to: bob.jid, version: .v03)
        let keyed = Self.keyed(legacy, version: .v03)
        #expect(keyed.contains(bob.id))
        #expect(!keyed.contains(other.id))
        #expect(await alice.store.device(other.address, version: .v03)?.trust == .undecided)

        let identities = try await alice.engine.identities(of: bob.jid)
        let flagged = try #require(identities.first { $0.deviceIDs[.v03] == [other.id] })
        #expect(flagged.needsDecision)
        #expect(flagged.trust == .undecided)
        let verified = try #require(identities.first { $0.deviceIDs[.v2] == [bob.id] })
        #expect(verified.trust == .verified)
        #expect(verified.deviceIDs[.v03] == [bob.id])
        #expect(!verified.needsDecision)
    }

    @Test func verifyingInOneVersionVerifiesTheIdentityInBoth() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        _ = try await net.send("v2", from: alice, to: bob.jid, version: .v2)
        try await alice.engine.setTrust(.verified, for: bob.address, version: .v2)

        // The legacy twin, seen after the verification, is the same key: verified too.
        _ = try await net.send("legacy", from: alice, to: bob.jid, version: .v03)
        #expect(await alice.store.device(bob.address, version: .v03)?.trust == .verified)

        // And verified there, both are, whichever came first.
        let carol = try await net.device("carol@example.org")
        try await net.notify(alice, about: carol.jid)
        for version in OMEMOVersion.allCases {
            _ = try await net.send("hi", from: alice, to: carol.jid, version: version)
        }
        try await alice.engine.setTrust(.verified, for: carol.address, version: .v03)
        #expect(await alice.store.device(carol.address, version: .v2)?.trust == .verified)
    }

    @Test func aTwinSeenAfterTheVerificationGetsItsKeys() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        // Alice knows only bob's OMEMO 2 list, and verifies his device there.
        let modern = try #require(await net.pep.list(of: bob.jid, version: .v2))
        _ = try await alice.engine.processDeviceList(modern, from: bob.jid, version: .v2)
        _ = try await net.send("v2", from: alice, to: bob.jid, version: .v2)
        try await alice.engine.setTrust(.verified, for: bob.address, version: .v2)

        // His legacy list comes later: a new device there waits for a decision, until its
        // bundle shows the key alice verified.
        try await net.notify(alice, about: bob.jid)
        let legacy = try await net.send("legacy", from: alice, to: bob.jid, version: .v03)
        #expect(Self.keyed(legacy, version: .v03).contains(bob.id))
        #expect(await alice.store.device(bob.address, version: .v03)?.trust == .verified)
    }

    @Test func distrustInOneVersionDistrustsInBoth() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        for version in OMEMOVersion.allCases {
            _ = try await net.send("hi", from: alice, to: bob.jid, version: version)
        }
        try await alice.engine.setTrust(.distrusted, for: bob.address, version: .v03)
        #expect(await alice.store.device(bob.address, version: .v2)?.trust == .distrusted)
        await #expect(throws: OMEMOError.noTrustedDevices(bob.jid)) {
            try await net.send("no", from: alice, to: bob.jid, version: .v2)
        }
        // By identity, the same.
        let identity = try #require(try await alice.engine.identities(of: bob.jid).first)
        try await alice.engine.setTrust(
            .trusted, forIdentity: try #require(identity.identityKey), of: bob.jid)
        for version in OMEMOVersion.allCases {
            #expect(await alice.store.device(bob.address, version: version)?.trust == .trusted)
        }
    }

    @Test func storedTrustOfOneIdentityMergesToTheStrictest() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try JID("bob@example.org")
        /// One identity in both versions: OMEMO 2's Ed25519 key and its X25519 form, the
        /// latter with the top bit set as libsignal may write it.
        func identity() throws -> (modern: Data, legacy: Data) {
            let modern = IdentityKeyPair.generate(version: .v2).publicKey
            var legacy = try KeyConversion.montgomeryPublic(fromEdwards: modern)
            legacy[31] |= 0x80
            return (modern, legacy)
        }
        let cases: [(DeviceTrust, DeviceTrust, DeviceTrust)] = [
            (.verified, .trusted, .verified),
            (.distrusted, .verified, .distrusted),
            (.trusted, .undecided, .undecided),
            (.verified, .undecided, .verified),
        ]
        for (index, (modern, legacy, _)) in cases.enumerated() {
            let keys = try identity()
            #expect(
                OMEMOEngine.canonicalIdentity(of: keys.modern, version: .v2)
                    == OMEMOEngine.canonicalIdentity(of: keys.legacy, version: .v03))
            let id = UInt32(100 + index)
            await alice.store.saveDevice(
                OMEMODevice(
                    jid: bob, deviceID: id, active: true, identityKey: keys.modern, trust: modern),
                version: .v2)
            await alice.store.saveDevice(
                OMEMODevice(
                    jid: bob, deviceID: id + 50, active: true, identityKey: keys.legacy,
                    trust: legacy),
                version: .v03)
        }
        try await alice.engine.reconcileTrust()
        for (index, (_, _, merged)) in cases.enumerated() {
            let id = UInt32(100 + index)
            let modern = await alice.store.device(
                DeviceAddress(jid: bob, deviceID: id), version: .v2)
            let legacy = await alice.store.device(
                DeviceAddress(jid: bob, deviceID: id + 50), version: .v03)
            #expect(modern?.trust == merged, "case \(index)")
            #expect(legacy?.trust == merged, "case \(index)")
        }
    }

    // MARK: R66: one identity key for both versions

    /// The identity key a bundle of `device` carries, in canonical form.
    static func bundleIdentity(_ device: TestDevice, version: OMEMOVersion) async throws -> Data? {
        let element = try await device.engine.ownBundle(version: version)
        let bundle = try #require(OMEMOBundle.parse(element, version: version))
        #expect(bundle.hasValidSignature(version: version))
        return OMEMOEngine.canonicalIdentity(of: bundle.identityKey, version: version)
    }

    @Test(arguments: [[OMEMOVersion.v03, .v2], [.v2, .v03]])
    func ourBundlesCarryOneIdentityInBothVersions(order: [OMEMOVersion]) async throws {
        let net = Net()
        let us = try await net.device("alice@example.org", versions: order, madeByEngine: true)
        let legacy = try #require(try await Self.bundleIdentity(us, version: .v03))
        #expect(legacy == (try await Self.bundleIdentity(us, version: .v2)))
        var fingerprints: [String?] = []
        for version in OMEMOVersion.allCases {
            let identity = try #require(await us.store.ownIdentity(version: version))
            fingerprints.append(
                us.engine.fingerprint(of: identity.identityKeyPair.publicKey, version: version))
        }
        #expect(fingerprints[0] != nil && fingerprints[0] == fingerprints[1])
    }

    @Test func aPeerThatVerifiesUsInOneVersionSeesUsVerifiedInTheOther() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let us = try await net.device("bob@example.org", madeByEngine: true)
        try await net.notify(alice, about: us.jid)
        _ = try await net.send("v2", from: alice, to: us.jid, version: .v2)
        try await alice.engine.setTrust(.verified, for: us.address, version: .v2)
        let legacy = try await net.send("legacy", from: alice, to: us.jid, version: .v03)
        #expect(await alice.store.device(us.address, version: .v03)?.trust == .verified)
        #expect(Self.keyed(legacy, version: .v03).contains(us.id))
        // And we read it.
        let read = try await us.engine.decrypt(legacy, from: alice.jid, version: .v03)
        #expect(read.body == "legacy")
    }

    /// Task 24: a listed device whose key no bundle has shown gets it from a refresh, so a
    /// verified contact's other device can be decided on.
    @Test func aRefreshLearnsTheKeysOfListedDevices() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        for version in OMEMOVersion.allCases {
            #expect(await alice.store.device(bob.address, version: version)?.identityKey == nil)
        }
        var learnt = 0
        for version in OMEMOVersion.allCases {
            learnt += try await alice.engine.refreshIdentities(of: bob.jid, version: version)
        }
        #expect(learnt == 2)
        let identities = try await alice.engine.identities(of: bob.jid)
        #expect(identities.count == 1)
        #expect(identities.first?.identityKey != nil)
        #expect(identities.first?.deviceIDs == [.v2: [bob.id], .v03: [bob.id]])
        // Known now: nothing more to fetch.
        #expect(try await alice.engine.refreshIdentities(of: bob.jid, version: .v2) == 0)
    }

    // MARK: Round 4

    /// N5: a refusal given before the key was known holds once the key turns up, and spreads
    /// to the key's other devices (the strictest wins).
    @Test func aDistrustBeforeTheKeyHoldsWhenTheKeyArrives() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        _ = try await net.send("v2", from: alice, to: bob.jid, version: .v2)
        // The legacy twin is listed, its key unknown; the user refuses it.
        #expect(await alice.store.device(bob.address, version: .v03)?.identityKey == nil)
        try await alice.engine.setTrust(.distrusted, for: bob.address, version: .v03)

        // A legacy key exchange from it shows the key, which the OMEMO 2 device shows too.
        let legacy = try await net.send("legacy", from: bob, to: alice.jid, version: .v03)
        _ = try await alice.engine.decrypt(legacy, from: bob.jid, version: .v03)
        for version in OMEMOVersion.allCases {
            #expect(await alice.store.device(bob.address, version: version)?.trust == .distrusted)
        }
        await #expect(throws: OMEMOError.noTrustedDevices(bob.jid)) {
            try await net.send("no", from: alice, to: bob.jid, version: .v03)
        }
    }

    /// N5: the same when the refusal comes while a refresh is fetching the bundle.
    @Test func aDistrustDuringARefreshHoldsWhenTheKeyArrives() async throws {
        let net = Net()
        let transport = CountingTransport(pep: net.pep)
        let store = MemoryStore()
        let clock = net.clock
        let aliceJID = try JID("alice@example.org")
        let engine = OMEMOEngine(
            store: store, transport: transport, accountJID: aliceJID, now: { clock.now },
            bundleFetchTimeout: .seconds(3_600))
        for version in OMEMOVersion.allCases {
            _ = try await engine.ensureOwnDevice(version: version)
        }
        let alice = TestDevice(jid: aliceJID, engine: engine, store: store, id: 0)
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        _ = try await net.send("v2", from: alice, to: bob.jid, version: .v2)

        await transport.hang(bundleOf: bob.id)
        let refreshing = Task { try await engine.refreshIdentities(of: bob.jid, version: .v03) }
        for _ in 0..<1_000 where await transport.held == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await engine.setTrust(.distrusted, for: bob.address, version: .v03)
        await transport.release()
        _ = try await refreshing.value
        #expect(await store.device(bob.address, version: .v03)?.identityKey != nil)
        #expect(await store.device(bob.address, version: .v03)?.trust == .distrusted)
    }

    /// m11: a message kept while OMEMO could not read it is read later as a live one, answered,
    /// but never makes an older session current again (N2's rule).
    @Test(arguments: OMEMOVersion.allCases)
    func aKeptMessageReadLateLeavesTheCurrentSession(version: OMEMOVersion) async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org", versions: [version])
        let bob = try await net.device("bob@example.org", versions: [version])
        let first = try await net.send("K1 one", from: alice, to: bob.jid, version: version)
        let second = try await net.send("K1 two", from: alice, to: bob.jid, version: version)
        try await withdrawUsedPreKey(of: alice, toward: bob, version: version, on: net.pep)
        await alice.store.deleteSession(with: bob.address, version: version)
        let k2 = try await net.send("from K2", from: alice, to: bob.jid, version: version)
        let read = try await bob.engine.decrypt(k2, from: alice.jid, version: version)
        let reply = try #require(read.replies.first)
        let encrypted = try #require(reply.stanza.child("encrypted", namespace: version.rawValue))
        _ = try await alice.engine.decrypt(encrypted, from: bob.jid, version: version)

        for (copy, text) in [(first, "K1 one"), (second, "K1 two")] {
            let late = try await bob.engine.decrypt(
                copy, from: alice.jid, version: version, answering: true, promoting: false)
            #expect(late.body == text)
        }
        let back = try await net.send("back", from: bob, to: alice.jid, version: version)
        #expect(
            try await alice.engine.decrypt(back, from: bob.jid, version: version).body == "back")
    }

    // MARK: Round 5

    /// m15: a twin BTBV left undecided (listed after a verification) takes its key's trust
    /// when the key is a blindly trusted one; it does not lower that key.
    @Test func aTwinListedUndecidedTakesItsTrustedKeysTrust() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let verified = try await net.device("bob@example.org", versions: [.v2])
        // Alice knows bob's OMEMO 2 devices: one blindly trusted, one verified.
        let modern = try #require(await net.pep.list(of: bob.jid, version: .v2))
        _ = try await alice.engine.processDeviceList(modern, from: bob.jid, version: .v2)
        _ = try await net.send("v2", from: alice, to: bob.jid, version: .v2)
        try await alice.engine.setTrust(.verified, for: verified.address, version: .v2)
        #expect(await alice.store.device(bob.address, version: .v2)?.trust == .trusted)

        // The legacy twin of the trusted one is listed now: undecided by BTBV, until its key.
        try await net.notify(alice, about: bob.jid)
        #expect(await alice.store.device(bob.address, version: .v03)?.trust == .undecided)
        let legacy = try await net.send("legacy", from: alice, to: bob.jid, version: .v03)
        #expect(Self.keyed(legacy, version: .v03).contains(bob.id))
        for version in OMEMOVersion.allCases {
            #expect(await alice.store.device(bob.address, version: version)?.trust == .trusted)
        }
    }

    /// m15: a device whose key is not known cannot be trusted or verified: nobody compared it.
    @Test func aDeviceWithoutAKeyIsNeitherTrustedNorVerified() async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        for trust in [DeviceTrust.trusted, .verified] {
            await #expect(throws: OMEMOError.unknownIdentity(bob.jid)) {
                try await alice.engine.setTrust(trust, for: bob.address, version: .v2)
            }
        }
        // A refusal needs no key.
        try await alice.engine.setTrust(.distrusted, for: bob.address, version: .v2)
        #expect(await alice.store.device(bob.address, version: .v2)?.trust == .distrusted)
    }

    /// m18: a late key exchange under a new key, from a device reset while OMEMO could not
    /// read, replaces the session, flagged as an identity change under the new key.
    @Test(arguments: OMEMOVersion.allCases)
    func aLateKeyExchangeFromAResetDeviceIsTheNewKeys(version: OMEMOVersion) async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org", versions: [version])
        let bob = try await net.device("bob@example.org", versions: [version])
        let hello = try await net.send("hello", from: bob, to: alice.jid, version: version)
        _ = try await alice.engine.decrypt(hello, from: bob.jid, version: version)
        try await withdrawUsedPreKey(of: bob, toward: alice, version: version, on: net.pep)
        try await alice.engine.setTrust(.verified, for: bob.address, version: version)
        let arrived = net.clock.now.addingTimeInterval(60)
        net.clock.advance(by: 120)
        let reset = try await Self.reinstalled(bob, version: version, on: net)
        let late = try await net.send("after reset", from: reset, to: alice.jid, version: version)
        let read = try await alice.engine.decrypt(
            late, from: bob.jid, version: version, answering: true, promoting: false,
            arrivedAt: arrived)
        #expect(read.body == "after reset")
        #expect(read.identityChanged)
        let newKey = try #require(await reset.store.ownIdentity(version: version))
            .identityKeyPair.publicKey
        #expect(read.fingerprint == OMEMOEngine.fingerprint(of: newKey, version: version))
        // Under N1 and BTBV: not the verified key any more; it waits for the user.
        #expect(read.senderTrust == .undecided)
        #expect(await alice.store.device(bob.address, version: version)?.trust == .undecided)
    }

    /// m18: a kept message of the device's old key, read after newer messages under its new
    /// key, is refused as an identity change: the session stays on the new key.
    @Test(arguments: OMEMOVersion.allCases)
    func aLateKeyExchangeUnderAnOlderKeyIsRefused(version: OMEMOVersion) async throws {
        let net = Net()
        let alice = try await net.device("alice@example.org", versions: [version])
        let bob = try await net.device("bob@example.org", versions: [version])
        // Kept while OMEMO could not read: bob's first key exchange, under his old key.
        let old = try await net.send("old key", from: bob, to: alice.jid, version: version)
        try await withdrawUsedPreKey(of: bob, toward: alice, version: version, on: net.pep)
        let arrived = net.clock.now
        net.clock.advance(by: 60)
        // Then bob's device is reset, and its new key is read live.
        let reset = try await Self.reinstalled(bob, version: version, on: net)
        let fresh = try await net.send("new key", from: reset, to: alice.jid, version: version)
        _ = try await alice.engine.decrypt(fresh, from: bob.jid, version: version)

        let late = try await alice.engine.decrypt(
            old, from: bob.jid, version: version, answering: true, promoting: false,
            arrivedAt: arrived)
        #expect(late.content == .failed(.identityChanged))
        let back = try await net.send("back", from: alice, to: bob.jid, version: version)
        #expect(
            try await reset.engine.decrypt(back, from: alice.jid, version: version).body == "back")
    }

    /// `device`'s JID and id with a new identity key, its bundle and list published.
    static func reinstalled(_ device: TestDevice, version: OMEMOVersion, on net: Net)
        async throws -> TestDevice
    {
        let store = MemoryStore()
        await store.saveOwnIdentity(
            OwnIdentity(
                deviceID: device.id, identityKeyPair: .generate(version: version),
                registrationID: version == .v03 ? device.id : nil, signedPreKeyID: 0,
                nextPreKeyID: 1),
            version: version)
        let clock = net.clock
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: net.pep), accountJID: device.jid,
            now: { clock.now })
        #expect(try await engine.ensureOwnDevice(version: version) == device.id)
        await net.pep.setBundle(
            try await engine.ownBundle(version: version), of: device.jid, deviceID: device.id,
            version: version)
        return TestDevice(jid: device.jid, engine: engine, store: store, id: device.id)
    }

}
