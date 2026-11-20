import Foundation
import Testing
import XMPPCore

@testable import OMEMO

@Suite struct EngineTests {
    // MARK: - Who gets keys

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func encryptForAllTrustedDevicesOnly(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice1 = try await net.device("alice@example.org")
        let alice2 = try await net.device("alice@example.org")
        let bob1 = try await net.device("bob@example.org")
        let bob2 = try await net.device("bob@example.org")
        let bob3 = try await net.device("bob@example.org")
        let bob4 = try await net.device("bob@example.org")
        try await net.syncLists([alice1, alice2, bob1, bob2, bob3, bob4])

        try await alice1.engine.setTrust(.undecided, for: bob2.address, version: version)
        try await alice1.engine.setTrust(.distrusted, for: bob3.address, version: version)
        await net.unlist(bob4)
        let update = try await net.notify(alice1, about: bob1.jid)
        #expect(update.deactivated == [bob4.id])

        let encrypted = try await net.send("hi", from: alice1, to: [bob1.jid])
        switch version {
        case .v03:
            #expect(keyedDevices(encrypted, version: version) == [bob1.id, alice2.id])
        case .v2:
            #expect(
                keyRecipients(encrypted, version: version) == [
                    "bob@example.org": [bob1.id], "alice@example.org": [alice2.id],
                ])
        }
        #expect(
            encrypted.child("header", namespace: version.rawValue)?[attribute: "sid"]
                == String(alice1.id))

        #expect(try await net.deliver(encrypted, from: alice1, to: bob1).body == "hi")
        let carbon = try await net.deliver(
            encrypted, from: alice1, to: alice2, recipient: .direct(bob1.jid))
        #expect(carbon.body == "hi")
        for excluded in [bob2, bob3, bob4] {
            let result = try await net.deliver(encrypted, from: alice1, to: excluded)
            #expect(result.content == .notForThisDevice)
        }
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func newDeviceOfVerifiedContactGetsNoKey(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob1 = try await net.device("bob@example.org")
        _ = try await net.deliver(
            try await net.send("first", from: alice, to: [bob1.jid]), from: alice, to: bob1)
        try await alice.engine.setTrust(.verified, for: bob1.address, version: version)

        let bob2 = try await net.device("bob@example.org")
        let update = try await net.notify(alice, about: bob1.jid)
        #expect(update.added.map(\.deviceID) == [bob2.id])
        #expect(update.added.map(\.trust) == [.undecided])

        let encrypted = try await net.send("second", from: alice, to: [bob1.jid])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id])
        #expect(try await net.deliver(encrypted, from: alice, to: bob1).body == "second")
        let result = try await net.deliver(encrypted, from: alice, to: bob2)
        #expect(result.content == .notForThisDevice)
        #expect(result.sender == alice.address)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func blindTrustUntilAContactIsVerified(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob1 = try await net.device("bob@example.org")
        let bob = bob1.jid

        var encrypted = try await net.send("one", from: alice, to: [bob])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id])
        #expect(
            try await alice.engine.devices(of: bob, version: version).map(\.trust) == [.trusted])

        // No device verified yet: a new device is trusted blindly.
        let bob2 = try await net.device("bob@example.org")
        #expect(try await net.notify(alice, about: bob).added.map(\.trust) == [.trusted])
        encrypted = try await net.send("two", from: alice, to: [bob])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id, bob2.id])

        // One device verified: the next new one waits for a decision; the others keep theirs.
        try await alice.engine.setTrust(.verified, for: bob1.address, version: version)
        let bob3 = try await net.device("bob@example.org")
        #expect(try await net.notify(alice, about: bob).added.map(\.trust) == [.undecided])
        encrypted = try await net.send("three", from: alice, to: [bob])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id, bob2.id])

        try await alice.engine.setTrust(.trusted, for: bob3.address, version: version)
        encrypted = try await net.send("four", from: alice, to: [bob])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id, bob2.id, bob3.id])

        try await alice.engine.setTrust(.distrusted, for: bob2.address, version: version)
        encrypted = try await net.send("five", from: alice, to: [bob])
        #expect(keyedDevices(encrypted, version: version) == [bob1.id, bob3.id])

        // A contact with devices but none trusted, and one without OMEMO.
        let carol = try await net.device("carol@example.org")
        _ = try await net.send("hello", from: alice, to: [carol.jid])
        try await alice.engine.setTrust(.undecided, for: carol.address, version: version)
        await #expect(throws: OMEMOError.noTrustedDevices(carol.jid)) {
            try await net.send("again", from: alice, to: [carol.jid])
        }
        let dave = try JID("dave@example.org")
        await #expect(throws: OMEMOError.noDevices(dave)) {
            try await net.send("hello", from: alice, to: [dave])
        }
        await #expect(throws: OMEMOError.unknownDevice(DeviceAddress(jid: dave, deviceID: 1))) {
            try await alice.engine.setTrust(
                .trusted, for: DeviceAddress(jid: dave, deviceID: 1), version: version)
        }
    }

    // MARK: - Sessions

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func decryptUpdatesSessionAndStores(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let preKeysBefore = Set(await bob.store.preKeyIDs(version: version))
        #expect(preKeysBefore.count == 100)

        let first = try await net.send("one", from: alice, to: [bob.jid])
        #expect(isKeyExchange(first, for: bob.id, version: version) == true)
        let result = try await net.deliver(first, from: alice, to: bob)
        #expect(result.body == "one")
        #expect(result.sender == alice.address)
        #expect(result.senderTrust == .trusted)
        #expect(result.identityChanged == false)
        let aliceIdentity = try #require(
            await alice.store.ownIdentity(version: version)?.identityKeyPair.publicKey)
        #expect(result.fingerprint == alice.engine.fingerprint(of: aliceIdentity, version: version))

        // The session is stored and the one-time pre key is gone, from the store and the bundle.
        #expect(try await bob.store.storedSession(with: alice.address, version: version) != nil)
        let preKeysAfter = Set(await bob.store.preKeyIDs(version: version))
        #expect(preKeysAfter.count == 99)
        #expect(preKeysAfter.isSubset(of: preKeysBefore))
        let bundle = try #require(result.bundleToPublish)
        #expect(Set(bundlePreKeyIDs(bundle, version: version)) == preKeysAfter)
        let record = try #require(await bob.store.device(alice.address, version: version))
        #expect(record.identityKey == aliceIdentity)
        #expect(record.lastSeen == net.clock.now)

        // Until Bob answers, Alice repeats the key exchange; the repeat uses the same session.
        let second = try await net.send("two", from: alice, to: [bob.jid])
        #expect(isKeyExchange(second, for: bob.id, version: version) == true)
        let secondResult = try await net.deliver(second, from: alice, to: bob)
        #expect(secondResult.body == "two")
        #expect(secondResult.replies.isEmpty)
        #expect(secondResult.bundleToPublish == nil)
        #expect(await bob.store.preKeyIDs(version: version).count == 99)

        // A message seen before is a duplicate, not an error.
        #expect(try await net.deliver(first, from: alice, to: bob).content == .duplicate)

        // Bob confirms the new session with an empty message; Alice stops the key exchange.
        #expect(result.replies.map(\.reason) == [.sessionCompletion])
        #expect(result.replies.map(\.device) == [alice.address])
        let reply = try #require(result.replies.first)
        #expect(reply.stanza.child("store", namespace: "urn:xmpp:hints") != nil)
        let confirmed = try await net.deliver(reply, from: bob, to: alice)
        #expect(confirmed.content == .empty)
        #expect(confirmed.replies.isEmpty)
        let third = try await net.send("three", from: alice, to: [bob.jid])
        #expect(isKeyExchange(third, for: bob.id, version: version) == false)
        #expect(try await net.deliver(third, from: alice, to: bob).body == "three")

        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(isKeyExchange(back, for: alice.id, version: version) == false)
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func heartbeatAfter53MessagesWithoutReply(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")

        for round in 0..<2 {
            // Counters 0 to 52 on one ratchet key: no heartbeat.
            for counter in 0..<53 {
                let result = try await net.deliver(
                    try await net.send("m\(counter)", from: alice, to: [bob.jid]), from: alice,
                    to: bob)
                #expect(result.body == "m\(counter)")
                let expected: [KeyTransportMessage.Reason] =
                    round == 0 && counter == 0 ? [.sessionCompletion] : []
                #expect(result.replies.map(\.reason) == expected)
            }
            // Counter 53 is the first that asks for one, once per ratchet key.
            let due = try await net.deliver(
                try await net.send("m53", from: alice, to: [bob.jid]), from: alice, to: bob)
            #expect(due.replies.map(\.reason) == [.heartbeat])
            let next = try await net.deliver(
                try await net.send("m54", from: alice, to: [bob.jid]), from: alice, to: bob)
            #expect(next.replies.isEmpty)

            // The heartbeat moves Alice to a new ratchet key, and the count starts again.
            let heartbeat = try #require(due.replies.first)
            #expect(heartbeat.device == alice.address)
            #expect(try await net.deliver(heartbeat, from: bob, to: alice).content == .empty)
        }
    }

    /// Legacy OMEMO repairs a broken session on its own, as Conversations does.
    @Test func legacyBrokenSessionIsRepairedOncePerHour() async throws {
        let version = OMEMOVersion.v03
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let opened = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(opened.replies.first), from: bob, to: alice)
        let snapshot = try #require(
            await bob.store.session(with: alice.address, version: version))

        // Bob loses the session: he cannot read Alice's message and starts a new session.
        await bob.store.deleteSession(with: alice.address, version: version)
        let lost = try await net.deliver(
            try await net.send("lost", from: alice, to: [bob.jid]), from: alice, to: bob)
        #expect(lost.content == .failed(.noSession))
        #expect(lost.replies.map(\.reason) == [.sessionRepair])
        let repair = try #require(lost.replies.first)
        let repairElement = try #require(
            repair.stanza.child("encrypted", namespace: version.rawValue))
        #expect(isKeyExchange(repairElement, for: alice.id, version: version) == true)
        #expect(repairElement.child("payload", namespace: version.rawValue) == nil)

        // Alice takes the new session and confirms it; messages flow both ways again.
        let accepted = try await net.deliver(repair, from: bob, to: alice)
        #expect(accepted.content == .empty)
        #expect(accepted.replies.map(\.reason) == [.sessionCompletion])
        #expect(
            try await net.deliver(try #require(accepted.replies.first), from: alice, to: bob)
                .content == .empty)
        let after = try await net.send("after", from: alice, to: [bob.jid])
        #expect(isKeyExchange(after, for: bob.id, version: version) == false)
        #expect(try await net.deliver(after, from: alice, to: bob).body == "after")
        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(isKeyExchange(back, for: alice.id, version: version) == false)
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")

        // Within the hour, another broken session (an old state) is not repaired again, not
        // even after the second failure in a row, which would otherwise count as broken.
        await bob.store.saveSession(snapshot, with: alice.address, version: version)
        for text in ["stale", "stale again"] {
            let stale = try await net.deliver(
                try await net.send(text, from: alice, to: [bob.jid]), from: alice, to: bob)
            #expect(stale.content == .failed(.authenticationFailed))
            #expect(stale.replies.isEmpty)
        }

        // An hour later it is.
        net.clock.advance(by: 3_601)
        let later = try await net.deliver(
            try await net.send("later", from: alice, to: [bob.jid]), from: alice, to: bob)
        #expect(later.content == .failed(.authenticationFailed))
        #expect(later.replies.map(\.reason) == [.sessionRepair])
    }

    /// XEP-0384: broken sessions are replaced on the user's request; OMEMO 2 never does it on
    /// its own after a decryption error.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func brokenSessionIsReplacedOnRequest(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let opened = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(opened.replies.first), from: bob, to: alice)

        await bob.store.deleteSession(with: alice.address, version: version)
        let lost = try await net.deliver(
            try await net.send("lost", from: alice, to: [bob.jid]), from: alice, to: bob)
        #expect(lost.content == .failed(.noSession))
        let automatic: [KeyTransportMessage.Reason] = version == .v03 ? [.sessionRepair] : []
        #expect(lost.replies.map(\.reason) == automatic)

        // The user asks for new sessions with Alice; that is not limited to once an hour.
        let replaced = try await bob.engine.replaceSessions(with: alice.jid, version: version)
        #expect(replaced.map(\.reason) == [.sessionRepair])
        #expect(replaced.map(\.device) == [alice.address])
        let replacement = try #require(replaced.first)
        let accepted = try await net.deliver(replacement, from: bob, to: alice)
        #expect(accepted.content == .empty)
        #expect(
            try await net.deliver(try #require(accepted.replies.first), from: alice, to: bob)
                .content == .empty)
        #expect(
            try await net.deliver(
                try await net.send("again", from: alice, to: [bob.jid]), from: alice, to: bob
            ).body == "again")
        #expect(
            try await net.deliver(
                try await net.send("back", from: bob, to: [alice.jid]), from: bob, to: alice
            ).body == "back")

        // Distrusted devices and unknown contacts get nothing.
        try await bob.engine.setTrust(.distrusted, for: alice.address, version: version)
        #expect(try await bob.engine.replaceSessions(with: alice.jid, version: version).isEmpty)
        #expect(
            try await bob.engine.replaceSessions(
                with: try JID("nobody@example.org"), version: version
            ).isEmpty)
    }

    /// A device that comes back with another identity key (a reinstall reusing its id) is
    /// judged again: after a verification it gets no keys until the user decides.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func changedIdentityOfVerifiedDeviceNeedsDecision(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let opened = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(opened.replies.first), from: bob, to: alice)
        try await alice.engine.setTrust(.verified, for: bob.address, version: version)
        let oldKey = try #require(
            await alice.store.device(bob.address, version: version)?.identityKey)

        // Bob reinstalls and comes back with the same device id and a new identity.
        let store = MemoryStore()
        await store.saveOwnIdentity(
            OwnIdentity(
                deviceID: bob.id, identityKeyPair: .generate(version: version),
                registrationID: version == .v03 ? bob.id : nil, signedPreKeyID: 0,
                nextPreKeyID: 1),
            version: version)
        let clock = net.clock
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: net.pep), accountJID: bob.jid,
            now: { clock.now })
        #expect(try await engine.ensureOwnDevice(version: version) == bob.id)
        let reinstalled = TestDevice(jid: bob.jid, engine: engine, store: store, id: bob.id)
        try await net.publishBundle(of: reinstalled)

        // Alice's message cannot be read there; the new session comes back to Alice.
        let lost = try await net.deliver(
            try await net.send("lost", from: alice, to: [bob.jid]), from: alice, to: reinstalled)
        #expect(lost.content == .failed(.noSession))
        let handover =
            version == .v03
            ? lost.replies : try await engine.replaceSessions(with: alice.jid, version: version)
        let kex = try #require(handover.first)
        let seen = try await net.deliver(kex, from: reinstalled, to: alice)
        #expect(seen.identityChanged)
        #expect(seen.senderTrust == .undecided)
        let record = try #require(await alice.store.device(bob.address, version: version))
        #expect(record.identityKey != oldKey)
        #expect(record.trust == .undecided)
        await #expect(throws: OMEMOError.noTrustedDevices(bob.jid)) {
            try await net.send("not yet", from: alice, to: [bob.jid])
        }

        try await alice.engine.setTrust(.verified, for: bob.address, version: version)
        #expect(
            try await net.deliver(
                try await net.send("verified", from: alice, to: [bob.jid]), from: alice,
                to: reinstalled
            ).body == "verified")
    }

    /// A bundle whose signature does not verify is not used, and does not touch what is known
    /// about the device.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func forgedBundleChangesNothing(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        _ = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        try await alice.engine.setTrust(.verified, for: bob.address, version: version)
        let known = try #require(await alice.store.device(bob.address, version: version))

        // The bundle now names another identity key, which did not sign the signed pre key.
        let ns = version.rawValue
        var bundle = try #require(
            await net.pep.bundle(of: bob.jid, deviceID: bob.id, version: version))
        let other = IdentityKeyPair.generate(version: version).publicKey
        bundle.children = bundle.children.map { node in
            guard case .element(var element) = node,
                element.name == (version == .v03 ? "identityKey" : "ik")
            else { return node }
            element.children = [.text(version.encodePublicKey(other).base64EncodedString())]
            return .element(element)
        }
        #expect(bundle.child(version == .v03 ? "identityKey" : "ik", namespace: ns) != nil)
        await net.pep.setBundle(bundle, of: bob.jid, deviceID: bob.id, version: version)
        await alice.store.deleteSession(with: bob.address, version: version)

        await #expect(throws: OMEMOError.sessionsUnavailable(bob.jid)) {
            try await net.send("again", from: alice, to: [bob.jid])
        }
        #expect(await alice.store.device(bob.address, version: version) == known)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func ownDeviceReadsSentCarbon(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice1 = try await net.device("alice@example.org")
        let alice2 = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.syncLists([alice1, alice2, bob])

        let encrypted = try await net.send("hi bob", from: alice1, to: [bob.jid])
        #expect(keyedDevices(encrypted, version: version) == [bob.id, alice2.id])

        // The sent carbon on Alice's other device: addressed to Bob, sent by Alice.
        let carbon = try await net.deliver(
            encrypted, from: alice1, to: alice2, recipient: .direct(bob.jid))
        #expect(carbon.body == "hi bob")
        #expect(carbon.sender == alice1.address)
        #expect(carbon.senderTrust == .trusted)

        // The sending device never has a key of its own: it already has the text.
        let own = try await net.deliver(encrypted, from: alice1, to: alice1)
        #expect(own.content == .sentByThisDevice)
        #expect(try await net.deliver(encrypted, from: alice1, to: bob).body == "hi bob")

        // Alice's second device replies, and Alice's first device reads that carbon too.
        let reply = try await net.send("from my laptop", from: alice2, to: [bob.jid])
        #expect(keyedDevices(reply, version: version) == [bob.id, alice1.id])
        let replyCarbon = try await net.deliver(
            reply, from: alice2, to: alice1, recipient: .direct(bob.jid))
        #expect(replyCarbon.body == "from my laptop")
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func messageWithoutKeyForThisDevice(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice1 = try await net.device("alice@example.org")
        let alice2 = try await net.device("alice@example.org")
        let bob1 = try await net.device("bob@example.org")
        try await net.syncLists([alice1, alice2, bob1])
        let first = try await net.deliver(
            try await net.send("one", from: alice1, to: [bob1.jid]), from: alice1, to: bob1)

        // Bob's new device is not in Alice's list yet: it has no key.
        let bob2 = try await net.device("bob@example.org")
        let encrypted = try await net.send("two", from: alice1, to: [bob1.jid])
        let result = try await net.deliver(encrypted, from: alice1, to: bob2)
        #expect(result.content == .notForThisDevice)
        #expect(result.sender == alice1.address)
        #expect(result.replies.isEmpty)

        // An empty message for another device of the account is nothing to show.
        let completion = try #require(first.replies.first)
        #expect(try await net.deliver(completion, from: bob1, to: alice2).content == .empty)
        #expect(try await net.deliver(completion, from: bob1, to: alice1).content == .empty)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func concurrentEncryptsKeepSessionsConsistent(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let messages = try await withThrowingTaskGroup(of: (Int, Element).self) { group in
            for index in 0..<20 {
                group.addTask {
                    (index, try await net.send("m\(index)", from: alice, to: [bob.jid]))
                }
            }
            var sent: [(Int, Element)] = []
            for try await message in group {
                sent.append(message)
            }
            return sent
        }
        #expect(await net.pep.bundleFetches == 1)
        var bodies: Set<String> = []
        for (_, encrypted) in messages {
            let result = try await net.deliver(encrypted, from: alice, to: bob)
            bodies.insert(try #require(result.body))
        }
        #expect(bodies == Set((0..<20).map { "m\($0)" }))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func malformedInputIsAFailureNotACrash(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let ns = version.rawValue

        func keyElement(_ text: String, kex: Bool) -> Element {
            var key = Element("key", namespace: ns, attributes: ["rid": String(bob.id)])
            if kex { key[attribute: version == .v03 ? "prekey" : "kex"] = "true" }
            key.append(text: text)
            return key
        }
        func encrypted(sid: String?, key: Element?) -> Element {
            var header = Element("header", namespace: ns)
            header[attribute: "sid"] = sid
            if let key {
                switch version {
                case .v03:
                    header.append(key)
                    header.append(
                        Element("iv", namespace: ns, children: [.text("AAAAAAAAAAAAAAAA")]))
                case .v2:
                    header.append(
                        Element(
                            "keys", namespace: ns, attributes: ["jid": "bob@example.org"],
                            children: [.element(key)]))
                }
            }
            return Element(
                "encrypted", namespace: ns,
                children: [
                    .element(header),
                    .element(Element("payload", namespace: ns, children: [.text("AAAA")])),
                ])
        }

        let garbage = Data(repeating: 0x42, count: 40).base64EncodedString()
        let cases: [Element] = [
            Element("encrypted", namespace: ns),
            encrypted(sid: nil, key: keyElement(garbage, kex: false)),
            encrypted(sid: "abc", key: keyElement(garbage, kex: false)),
            encrypted(sid: "0", key: keyElement(garbage, kex: false)),
            encrypted(sid: String(alice.id), key: keyElement("not base64!", kex: false)),
            encrypted(sid: String(alice.id), key: keyElement(garbage, kex: false)),
            encrypted(sid: String(alice.id), key: keyElement(garbage, kex: true)),
            encrypted(sid: String(alice.id), key: keyElement("", kex: true)),
            Element("encrypted", namespace: "urn:example:other"),
            Element("message"),
        ]
        for element in cases {
            let result = try await net.deliver(element, from: alice, to: bob)
            #expect(result.content == .failed(.malformed), "\(element.xml())")
            #expect(result.replies.isEmpty)
        }
        // Nothing was stored for the sender by any of them.
        #expect(try await bob.store.storedSession(with: alice.address, version: version) == nil)
        #expect(await bob.store.preKeyIDs(version: version).count == 100)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func nothingWorksBeforeTheOwnDeviceExists(version: OMEMOVersion) async throws {
        let engine = OMEMOEngine(
            store: MemoryStore(), transport: PEPTransport(pep: FakePEP()),
            accountJID: try JID("alice@example.org"))
        await #expect(throws: OMEMOError.noOwnDevice) {
            try await engine.ownBundle(version: version)
        }
        await #expect(throws: OMEMOError.noOwnDevice) {
            try await engine.encrypt(
                MessageContent(body: "hi"), to: [try JID("bob@example.org")], version: version)
        }
        await #expect(throws: OMEMOError.noOwnDevice) {
            try await engine.decrypt(
                Element("encrypted", namespace: version.rawValue),
                from: try JID("bob@example.org"), version: version)
        }
    }

    // MARK: - Payloads

    @Test func v2UsesSCEEnvelopeWithRpad() async throws {
        let alice = try JID("alice@example.org")
        let bob = try JID("bob@example.org")
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let link = Element(
            "x", namespace: "jabber:x:oob",
            children: [
                .element(
                    Element(
                        "url", namespace: "jabber:x:oob",
                        children: [.text("https://example.org/a.jpg")]))
            ])
        let hint = Element("store", namespace: "urn:xmpp:hints")
        let content = MessageContent(body: "hello", elements: [link, hint])

        var paddings: Set<String> = []
        for _ in 0..<20 {
            let envelope = OMEMOEngine.envelope(for: content, to: bob, from: alice, time: time)
            #expect(envelope.name == "envelope")
            #expect(envelope.namespace == "urn:xmpp:sce:1")
            let inner = try #require(envelope.child("content", namespace: "urn:xmpp:sce:1"))
            #expect(inner.child("body", namespace: "jabber:client")?.text == "hello")
            #expect(inner.elements.map(\.name) == ["body", "x"])
            #expect(inner.child("x", namespace: "jabber:x:oob") == link)
            let rpad = try #require(envelope.child("rpad", namespace: "urn:xmpp:sce:1")?.text)
            #expect(!rpad.isEmpty)
            paddings.insert(rpad)
            #expect(
                envelope.child("time", namespace: "urn:xmpp:sce:1")?[attribute: "stamp"]
                    .flatMap(XMPPDateTime.parse) == time)
            #expect(
                envelope.child("to", namespace: "urn:xmpp:sce:1")?[attribute: "jid"]
                    == "bob@example.org")
            #expect(
                envelope.child("from", namespace: "urn:xmpp:sce:1")?[attribute: "jid"]
                    == "alice@example.org")
        }
        #expect(paddings.count > 1)
        #expect(Set(paddings.map(\.count)).count > 1)

        // End to end: the envelope's content comes back, with the time it was sealed.
        let net = TestNetwork(version: .v2)
        let aliceDevice = try await net.device("alice@example.org")
        let bobDevice = try await net.device("bob@example.org")
        let encrypted = try await aliceDevice.engine.encrypt(
            content, to: [bob], version: .v2)
        #expect(
            encrypted.child("header", namespace: OMEMOVersion.v2.rawValue)?
                .child("iv", namespace: OMEMOVersion.v2.rawValue) == nil)
        let result = try await net.deliver(encrypted, from: aliceDevice, to: bobDevice)
        guard case .message(let message) = result.content else {
            Issue.record("not a message: \(result.content)")
            return
        }
        #expect(message.body == "hello")
        #expect(message.elements == [link])
        #expect(message.sentAt == net.clock.now)
    }

    @Test func legacyPayloadIsTheBodyOnly() async throws {
        let net = TestNetwork(version: .v03)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let ns = OMEMOVersion.v03.rawValue
        let encrypted = try await net.send("hello", from: alice, to: [bob.jid])
        let payload = try #require(
            encrypted.child("payload", namespace: ns).flatMap { Data(base64Encoded: $0.text) })
        #expect(payload.count == 5)
        let iv = try #require(
            encrypted.child("header", namespace: ns)?.child("iv", namespace: ns).flatMap {
                Data(base64Encoded: $0.text)
            })
        #expect(iv.count == 12)
        #expect(try await net.deliver(encrypted, from: alice, to: bob).body == "hello")

        await #expect(throws: OMEMOError.legacyEncryptsBodyOnly) {
            try await alice.engine.encrypt(
                MessageContent(body: "hi", elements: [Element("x", namespace: "jabber:x:oob")]),
                to: [bob.jid], version: .v03)
        }
        await #expect(throws: OMEMOError.nothingToEncrypt) {
            try await alice.engine.encrypt(
                MessageContent(body: nil), to: [bob.jid], version: .v03)
        }
    }

    @Test func envelopeAffixesChecked() async throws {
        let net = TestNetwork(version: .v2)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let room = try JID("room@muc.example.org")
        let body = "<content><body xmlns='jabber:client'>hi</body></content><rpad>xyz</rpad>"

        func envelope(_ affixes: String, content: String = body) -> Data {
            Data("<envelope xmlns='urn:xmpp:sce:1'>\(content)\(affixes)</envelope>".utf8)
        }
        func deliver(
            _ plaintext: Data, recipient: MessageRecipient? = nil
        ) async throws -> DecryptedPayload.Content {
            let encrypted = try await alice.engine.encryptPayload(
                plaintext, to: [bob.jid], version: .v2)
            return try await net.deliver(encrypted, from: alice, to: bob, recipient: recipient)
                .content
        }

        let good = "<to jid='bob@example.org'/><from jid='alice@example.org'/>"
        guard case .message(let message) = try await deliver(envelope(good)) else {
            Issue.record("a valid envelope was refused")
            return
        }
        #expect(message.body == "hi")
        #expect(message.sentAt == nil)
        // Affixes are optional in a direct message.
        guard case .message = try await deliver(envelope("")) else {
            Issue.record("an envelope without affixes was refused")
            return
        }

        let rejected: [(Data, MessageRecipient?)] = [
            // Addressed to someone else, or claiming another sender.
            (envelope("<to jid='carol@example.org'/><from jid='alice@example.org'/>"), nil),
            (envelope("<to jid='bob@example.org'/><from jid='mallory@example.org'/>"), nil),
            // A direct message turned into a room message, and a room message without <to/>.
            (envelope(good), .room(room)),
            (envelope("<from jid='alice@example.org'/>"), .room(room)),
            // A room message turned into a direct one.
            (envelope("<to jid='room@muc.example.org'/><from jid='alice@example.org'/>"), nil),
            // Not an envelope, no content, not XML.
            (Data("<body xmlns='jabber:client'>hi</body>".utf8), nil),
            (envelope(good, content: "<rpad>x</rpad>"), nil),
            (Data("<envelope xmlns='urn:xmpp:sce:1'><content>".utf8), nil),
            (Data("not xml".utf8), nil),
        ]
        for (plaintext, recipient) in rejected {
            let content = try await deliver(plaintext, recipient: recipient)
            #expect(
                content == .failed(.envelopeRejected),
                "\(String(decoding: plaintext, as: UTF8.self))")
        }

        // A room message to the right room passes.
        let inRoom = envelope("<to jid='room@muc.example.org'/><from jid='alice@example.org'/>")
        guard case .message = try await deliver(inRoom, recipient: .room(room)) else {
            Issue.record("a room envelope was refused")
            return
        }

        // Server-processed elements inside the content are dropped (XEP-0420).
        let smuggled = envelope(
            good,
            content: """
                <content><body xmlns='jabber:client'>hi</body>\
                <store xmlns='urn:xmpp:hints'/><origin-id xmlns='urn:xmpp:sid:0' id='x'/>\
                <encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:omemo:2'/>\
                <addresses xmlns='http://jabber.org/protocol/address'/>\
                <reply xmlns='urn:xmpp:reply:0' id='m1'/></content><rpad>a</rpad>
                """)
        guard case .message(let cleaned) = try await deliver(smuggled) else {
            Issue.record("the envelope was refused")
            return
        }
        #expect(cleaned.body == "hi")
        #expect(cleaned.elements.map(\.name) == ["reply"])
    }

    // MARK: - Own keys

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func bundleRotationKeeps100PreKeys(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let bob = try await net.device("bob@example.org")
        var consumed: Set<UInt32> = []
        for index in 0..<21 {
            let sender = try await net.device("user\(index)@example.org")
            let before = Set(await bob.store.preKeyIDs(version: version))
            let result = try await net.deliver(
                try await net.send("hi \(index)", from: sender, to: [bob.jid]), from: sender,
                to: bob)
            #expect(result.body == "hi \(index)")
            let after = Set(await bob.store.preKeyIDs(version: version))
            consumed.formUnion(before.subtracting(after))
            // Below 80 the bundle is filled up to 100 again.
            #expect(after.count == (index < 20 ? 99 - index : 100))
            let published = try #require(result.bundleToPublish)
            let publishedIDs = bundlePreKeyIDs(published, version: version)
            #expect(Set(publishedIDs) == after)
            #expect(publishedIDs.count == after.count)
            #expect(Set(publishedIDs).isDisjoint(with: consumed))
        }
        #expect(consumed.count == 21)
        _ = try await bob.engine.ensureOwnDevice(version: version)
        #expect(await bob.store.preKeyIDs(version: version).count == 100)
        #expect(
            bundlePreKeyIDs(try await bob.engine.ownBundle(version: version), version: version)
                .count == 100)
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func signedPreKeyRotatesWeeklyAndKeepsThePreviousFor30Days(version: OMEMOVersion)
        async throws
    {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let day: TimeInterval = 86_400
        let oldBundle = try #require(
            await net.pep.bundle(of: bob.jid, deviceID: bob.id, version: version))
        let first = try #require(await bob.store.ownIdentity(version: version)?.signedPreKeyID)

        net.clock.advance(by: 6 * day)
        #expect(try await bob.engine.ensureOwnDevice(version: version) == bob.id)
        #expect(await bob.store.signedPreKeyIDs(version: version) == [first])

        net.clock.advance(by: 2 * day)
        _ = try await bob.engine.ensureOwnDevice(version: version)
        let second = try #require(await bob.store.ownIdentity(version: version)?.signedPreKeyID)
        #expect(second != first)
        #expect(Set(await bob.store.signedPreKeyIDs(version: version)) == [first, second])
        let rotated = try await bob.engine.ownBundle(version: version)
        #expect(bundleSignedPreKeyID(rotated, version: version) == second)

        // A sender holding the bundle from before the rotation still gets through.
        #expect(
            try await net.deliver(
                try await net.send("late", from: alice, to: [bob.jid]), from: alice, to: bob
            ).body
                == "late")

        // 29 days after its retirement the first is kept; the second rotates on.
        net.clock.advance(by: 29 * day)
        _ = try await bob.engine.ensureOwnDevice(version: version)
        let third = try #require(await bob.store.ownIdentity(version: version)?.signedPreKeyID)
        #expect(Set(await bob.store.signedPreKeyIDs(version: version)) == [first, second, third])

        // 31 days after, it is gone, and a key exchange naming it fails.
        net.clock.advance(by: 2 * day)
        _ = try await bob.engine.ensureOwnDevice(version: version)
        #expect(Set(await bob.store.signedPreKeyIDs(version: version)) == [second, third])
        let carol = try await net.device("carol@example.org")
        await net.pep.setBundle(oldBundle, of: bob.jid, deviceID: bob.id, version: version)
        let tooLate = try await net.deliver(
            try await net.send("too late", from: carol, to: [bob.jid]), from: carol, to: bob)
        #expect(tooLate.content == .failed(.unknownSignedPreKey))
    }

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func ownDeviceIsStableAndReannounced(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice1 = try await net.device("alice@example.org")
        #expect((1...0x7FFF_FFFF).contains(alice1.id))
        #expect(try await alice1.engine.ensureOwnDevice(version: version) == alice1.id)

        // The second device saw the first one in the list and records it, never itself.
        let alice2 = try await net.device("alice@example.org")
        #expect(alice2.id != alice1.id)
        #expect(
            try await alice2.engine.devices(of: alice2.jid, version: version).map(\.deviceID)
                == [alice1.id])

        // A list without this device is published again with it.
        #expect(try await net.notify(alice1, about: alice1.jid).listToPublish == nil)
        await net.unlist(alice1)
        let update = try await net.notify(alice1, about: alice1.jid)
        let republished = try #require(update.listToPublish)
        #expect(
            DeviceList.deviceIDs(in: republished, version: version).map(Set.init)
                == Set([alice1.id, alice2.id]))
    }

    @Test func newDeviceIDAvoidsListedIDs() {
        var candidates = [UInt32(0), 7, 0x8000_0000, 42, 9].makeIterator()
        let id = OMEMOEngine.newDeviceID(avoiding: [7, 42]) { candidates.next() ?? 1 }
        #expect(id == 9)
        for _ in 0..<1_000 {
            let random = OMEMOEngine.newDeviceID(avoiding: []) {
                UInt32.random(in: .min ... .max)
            }
            #expect((1...0x7FFF_FFFF).contains(random))
        }
    }

    // MARK: - Rooms

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func roomMessagesGoToEveryMembersDevices(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let carol = try await net.device("carol@example.org")
        let roomJID = try JID("room@muc.example.org")
        let room = OMEMORoom(jid: roomJID, isNonAnonymous: true, isMembersOnly: true)

        let encrypted = try await net.send(
            "hello room", from: alice, to: [bob.jid, carol.jid], room: room)
        switch version {
        case .v03:
            #expect(keyedDevices(encrypted, version: version) == [bob.id, carol.id])
        case .v2:
            #expect(
                keyRecipients(encrypted, version: version) == [
                    "bob@example.org": [bob.id], "carol@example.org": [carol.id],
                ])
        }
        let forBob = try await net.deliver(
            encrypted, from: alice, to: bob, recipient: .room(roomJID))
        #expect(forBob.body == "hello room")

        // A room message must not pass as a direct one (OMEMO 2's <to/> affix).
        let forCarol = try await net.deliver(encrypted, from: alice, to: carol)
        switch version {
        case .v03: #expect(forCarol.body == "hello room")
        case .v2: #expect(forCarol.content == .failed(.envelopeRejected))
        }

        for unsuitable in [
            OMEMORoom(jid: roomJID, isNonAnonymous: false, isMembersOnly: true),
            OMEMORoom(jid: roomJID, isNonAnonymous: true, isMembersOnly: false),
        ] {
            await #expect(throws: OMEMOError.roomNotSuitable) {
                try await net.send("hi", from: alice, to: [bob.jid], room: unsuitable)
            }
        }
        await #expect(throws: OMEMOError.invalidRecipients) {
            try await net.send("hi", from: alice, to: [bob.jid, carol.jid])
        }
    }

    // MARK: - Fix round 1

    /// Spec 8.1: a corrupted message is rejected without changing any stored state, and the
    /// intact copy still decrypts.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func corruptedMessageLeavesStateUnchanged(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")

        // A key exchange whose payload was altered: no session, no pre key used, no reply.
        let first = try await net.send("one", from: alice, to: [bob.jid])
        var before = await bob.store.snapshot()
        let badKeyExchange = try await net.deliver(
            try flippingPayload(first, version: version), from: alice, to: bob)
        #expect(badKeyExchange.content == .failed(.invalidPayload))
        #expect(badKeyExchange.replies.isEmpty)
        #expect(badKeyExchange.bundleToPublish == nil)
        #expect(await bob.store.snapshot() == before)
        let opened = try await net.deliver(first, from: alice, to: bob)
        #expect(opened.body == "one")
        _ = try await net.deliver(try #require(opened.replies.first), from: bob, to: alice)

        // On a working session: an altered payload, and an altered key (its MAC).
        let second = try await net.send("two", from: alice, to: [bob.jid])
        before = await bob.store.snapshot()
        let badPayload = try await net.deliver(
            try flippingPayload(second, version: version), from: alice, to: bob)
        #expect(badPayload.content == .failed(.invalidPayload))
        #expect(await bob.store.snapshot() == before)
        let badMAC = try await net.deliver(
            try flippingKey(second, for: bob.id, version: version), from: alice, to: bob)
        #expect(badMAC.content == .failed(.authenticationFailed))
        #expect(badMAC.replies.isEmpty)
        #expect(await bob.store.snapshot() == before)
        #expect(try await net.deliver(second, from: alice, to: bob).body == "two")

        // OMEMO 2: an envelope addressed elsewhere (here: read as a room message).
        if version == .v2 {
            let third = try await net.send("three", from: alice, to: [bob.jid])
            before = await bob.store.snapshot()
            let misaddressed = try await net.deliver(
                third, from: alice, to: bob, recipient: .room(try JID("room@muc.example.org")))
            #expect(misaddressed.content == .failed(.envelopeRejected))
            #expect(await bob.store.snapshot() == before)
            #expect(try await net.deliver(third, from: alice, to: bob).body == "three")
        }
    }

    /// Two devices that start sessions with each other at the same time keep a working pair: the
    /// replaced sessions are kept and tried before a message counts as undecryptable.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func crossingKeyExchangesKeepWorking(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let fromAlice = try await net.send("hi bob", from: alice, to: [bob.jid])
        let fromBob = try await net.send("hi alice", from: bob, to: [alice.jid])
        #expect(isKeyExchange(fromAlice, for: bob.id, version: version) == true)
        #expect(isKeyExchange(fromBob, for: alice.id, version: version) == true)

        let atBob = try await net.deliver(fromAlice, from: alice, to: bob)
        let atAlice = try await net.deliver(fromBob, from: bob, to: alice)
        #expect(atBob.body == "hi bob")
        #expect(atAlice.body == "hi alice")
        for (reply, sender, receiver) in [
            (try #require(atBob.replies.first), bob, alice),
            (try #require(atAlice.replies.first), alice, bob),
        ] {
            #expect(try await net.deliver(reply, from: sender, to: receiver).content == .empty)
        }
        for round in 0..<3 {
            let toBob = try await net.deliver(
                try await net.send("a\(round)", from: alice, to: [bob.jid]), from: alice, to: bob)
            #expect(toBob.body == "a\(round)")
            let toAlice = try await net.deliver(
                try await net.send("b\(round)", from: bob, to: [alice.jid]), from: bob, to: alice)
            #expect(toAlice.body == "b\(round)")
        }
        // Settled: messages now decrypt on each side's current session, not on a replaced
        // one, because the replaced one that worked was made current.
        func previous(at device: TestDevice, of peer: TestDevice) async throws -> Data {
            let session = try #require(
                try await device.store.storedSession(with: peer.address, version: version))
            return try PropertyListEncoder().encode(session.previous)
        }
        let previousAtBob = try await previous(at: bob, of: alice)
        let previousAtAlice = try await previous(at: alice, of: bob)
        #expect(
            try await net.deliver(
                try await net.send("settled", from: alice, to: [bob.jid]), from: alice, to: bob
            ).body == "settled")
        #expect(
            try await net.deliver(
                try await net.send("settled too", from: bob, to: [alice.jid]), from: bob,
                to: alice
            ).body == "settled too")
        #expect(try await previous(at: bob, of: alice) == previousAtBob)
        #expect(try await previous(at: alice, of: bob) == previousAtAlice)

        // At most five replaced sessions are kept per device.
        let stored = try #require(
            try await alice.store.storedSession(with: bob.address, version: version))
        #expect(stored.previous.count <= StoredSession.maxPrevious)
        #expect(StoredSession.maxPrevious == 5)
    }

    /// A listed device without a bundle is asked for again only after a back-off of an hour,
    /// doubling to a day; listing it again retries at once.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func bundleLessDeviceIsFetchedOncePerBackoffWindow(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let ghost: UInt32 = 424_242
        await net.pep.setList(
            DeviceList.element(version: version, devices: [bob.id, ghost]), of: bob.jid,
            version: version)

        func send() async throws -> Element {
            try await net.send("hi", from: alice, to: [bob.jid])
        }
        #expect(keyedDevices(try await send(), version: version) == [bob.id])
        #expect(await net.pep.bundleFetches == 2)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 2)

        net.clock.advance(by: 59 * 60)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 2)
        net.clock.advance(by: 2 * 60)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 3)

        // Two failures: two hours.
        net.clock.advance(by: 3_600)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 3)
        net.clock.advance(by: 3_660)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 4)

        // Listed again after it was gone: asked at once.
        await net.unlist(TestDevice(jid: bob.jid, engine: bob.engine, store: bob.store, id: ghost))
        try await net.notify(alice, about: bob.jid)
        await net.pep.setList(
            DeviceList.element(version: version, devices: [bob.id, ghost]), of: bob.jid,
            version: version)
        try await net.notify(alice, about: bob.jid)
        _ = try await send()
        #expect(await net.pep.bundleFetches == 5)

        #expect(
            (1...7).map { OMEMOEngine.bundleRetryDelay(afterFailures: $0) } == [
                3_600, 7_200, 14_400, 28_800, 57_600, 86_400, 86_400,
            ])
    }

    /// A bundle fetch that never answers does not hold the account up: it is given up after the
    /// time-out, and the message goes to the other devices.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func hangingBundleFetchTimesOut(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let bob1 = try await net.device("bob@example.org")
        let bob2 = try await net.device("bob@example.org")
        let transport = SlowTransport(pep: net.pep, hanging: [bob2.id])
        let clock = net.clock
        let alice = OMEMOEngine(
            store: MemoryStore(), transport: transport, accountJID: try JID("alice@example.org"),
            now: { clock.now }, bundleFetchTimeout: .milliseconds(200))
        _ = try await alice.ensureOwnDevice(version: version)
        let started = ContinuousClock.now
        let sent = try await alice.encrypt(
            MessageContent(body: "hi"), to: [bob1.jid], version: version)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(keyedDevices(sent, version: version) == [bob1.id])
    }

    /// The bundles one message needs are fetched side by side, at most eight at a time.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func bundleFetchesRunConcurrentlyUpToEight(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        var devices: [TestDevice] = []
        for _ in 0..<12 {
            devices.append(try await net.device("bob@example.org"))
        }
        let transport = SlowTransport(pep: net.pep, delay: .milliseconds(50))
        let clock = net.clock
        let alice = OMEMOEngine(
            store: MemoryStore(), transport: transport, accountJID: try JID("alice@example.org"),
            now: { clock.now })
        _ = try await alice.ensureOwnDevice(version: version)
        let sent = try await alice.encrypt(
            MessageContent(body: "hi"), to: [devices[0].jid], version: version)
        #expect(keyedDevices(sent, version: version) == Set(devices.map(\.id)))
        let mostAtOnce = await transport.mostAtOnce
        #expect(mostAtOnce > 1)
        #expect(mostAtOnce <= 8)
    }

    /// A device that has not been heard from for 90 days, or after 500 messages sent to it
    /// without an answer, is stale: it gets no keys while the contact has a device that is not.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func staleDevicesGetNoKeys(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob1 = try await net.device("bob@example.org")
        let bob2 = try await net.device("bob@example.org")
        try await net.syncLists([alice, bob1, bob2])
        func hear(from device: TestDevice) async throws {
            let result = try await net.deliver(
                try await net.send("ping", from: device, to: [alice.jid]), from: device,
                to: alice)
            #expect(result.body == "ping")
        }
        func stale() async throws -> [UInt32] {
            try await alice.engine.deviceStatuses(of: bob1.jid, version: version)
                .filter(\.isStale).map(\.device.deviceID)
        }

        // 500 messages without an answer from bob2, while bob1 answers.
        for index in 0..<OMEMOEngine.staleAfterMessages {
            let sent = try await net.send("m\(index)", from: alice, to: [bob1.jid])
            #expect(keyedDevices(sent, version: version) == [bob1.id, bob2.id])
            if index % 100 == 0 { try await hear(from: bob1) }
        }
        #expect(try await stale() == [bob2.id])
        let statuses = try await alice.engine.deviceStatuses(of: bob1.jid, version: version)
        #expect(statuses.first { $0.device.deviceID == bob2.id }?.messagesSinceLastReceived == 500)
        #expect(
            keyedDevices(try await net.send("next", from: alice, to: [bob1.jid]), version: version)
                == [bob1.id])

        // A message from bob2 makes it current again.
        try await hear(from: bob2)
        #expect(try await stale() == [])
        #expect(
            keyedDevices(try await net.send("back", from: alice, to: [bob1.jid]), version: version)
                == [bob1.id, bob2.id])

        // 90 days of silence from bob2 while bob1 talks.
        net.clock.advance(by: 91 * 86_400)
        try await hear(from: bob1)
        #expect(try await stale() == [bob2.id])
        #expect(
            keyedDevices(try await net.send("later", from: alice, to: [bob1.jid]), version: version)
                == [bob1.id])

        // When every device of a contact is stale, the message still goes to all of them.
        net.clock.advance(by: 91 * 86_400)
        #expect(Set(try await stale()) == [bob1.id, bob2.id])
        #expect(
            keyedDevices(
                try await net.send("anyone?", from: alice, to: [bob1.jid]), version: version)
                == [bob1.id, bob2.id])
    }

    /// A message refused for one recipient stores nothing for the others (review M2): no
    /// session moves on, and no new session is kept.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func refusedMessageChangesNoSession(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let erin = try await net.device("erin@example.org")
        _ = try await net.deliver(
            try await net.send("hi", from: alice, to: [bob.jid]), from: alice, to: bob)
        let carol = try JID("carol@example.org")
        await net.pep.setList(
            DeviceList.element(version: version, devices: [77]), of: carol, version: version)
        let room = OMEMORoom(
            jid: try JID("room@muc.example.org"), isNonAnonymous: true, isMembersOnly: true)

        let before = await alice.store.snapshot()
        await #expect(throws: OMEMOError.sessionsUnavailable(carol)) {
            try await net.send("hello", from: alice, to: [bob.jid, erin.jid, carol], room: room)
        }
        let after = await alice.store.snapshot()
        let sessions = { (snapshot: String) in
            snapshot.split(separator: "\n").filter { $0.hasPrefix("session ") }
        }
        #expect(sessions(after) == sessions(before))
        #expect(try await alice.store.storedSession(with: erin.address, version: version) == nil)
    }

    /// Transport errors: a recipient whose list cannot be fetched cannot be written to; a
    /// device whose bundle cannot be fetched is left out; the account's own list failing is not
    /// an error.
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func transportErrorsAreContained(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let bob1 = try await net.device("bob@example.org")
        let bob2 = try await net.device("bob@example.org")
        let carol = try await net.device("carol@example.org")
        let transport = FailingTransport(pep: net.pep)
        let clock = net.clock
        let alice = try JID("alice@example.org")
        let engine = OMEMOEngine(
            store: MemoryStore(), transport: transport, accountJID: alice, now: { clock.now })
        _ = try await engine.ensureOwnDevice(version: version)
        await transport.fail(listOf: alice)
        await transport.fail(listOf: carol.jid)
        await transport.fail(bundleOf: bob2.id)

        let sent = try await engine.encrypt(
            MessageContent(body: "hi"), to: [bob1.jid], version: version)
        #expect(keyedDevices(sent, version: version) == [bob1.id])
        await #expect(throws: FailingTransport.Failure.self) {
            try await engine.encrypt(MessageContent(body: "hi"), to: [carol.jid], version: version)
        }
    }

    /// Staleness is decided among the devices a message can reach: a listed device without a
    /// session or bundle never pushes out a stale device that works (re-review N1).
    @Test(arguments: [OMEMOVersion.v03, .v2])
    func staleWorkingDeviceIsNotDroppedForUnreachableOnes(version: OMEMOVersion) async throws {
        let ghost: UInt32 = 424_242
        func network() async throws -> (TestNetwork, TestDevice, TestDevice) {
            let net = TestNetwork(version: version)
            let alice = try await net.device("alice@example.org")
            let bob = try await net.device("bob@example.org")
            await net.pep.setList(
                DeviceList.element(version: version, devices: [bob.id, ghost]), of: bob.jid,
                version: version)
            #expect(
                keyedDevices(try await net.send("hi", from: alice, to: [bob.jid]), version: version)
                    == [bob.id])
            return (net, alice, bob)
        }

        // Silent for 91 days: bob1 is stale, the device without a bundle cannot be reached.
        var (net, alice, bob) = try await network()
        net.clock.advance(by: 91 * 86_400)
        #expect(
            keyedDevices(
                try await net.send("still there?", from: alice, to: [bob.jid]), version: version)
                == [bob.id])
        let statuses = try await alice.engine.deviceStatuses(of: bob.jid, version: version)
        let working = try #require(statuses.first { $0.device.deviceID == bob.id })
        let unreachable = try #require(statuses.first { $0.device.deviceID == ghost })
        #expect(working.isStale && working.hasSession && !working.isBundleUnavailable)
        #expect(!unreachable.isStale && !unreachable.hasSession && unreachable.isBundleUnavailable)

        // 500 messages without an answer: the same.
        (net, alice, bob) = try await network()
        for index in 1..<OMEMOEngine.staleAfterMessages {
            _ = try await net.send("m\(index)", from: alice, to: [bob.jid])
        }
        #expect(
            try await alice.engine.deviceStatuses(of: bob.jid, version: version)
                .first { $0.device.deviceID == bob.id }?.isStale == true)
        #expect(
            keyedDevices(
                try await net.send("anyone?", from: alice, to: [bob.jid]), version: version)
                == [bob.id])

        // A new device that can be reached replaces the stale one.
        (net, alice, bob) = try await network()
        net.clock.advance(by: 91 * 86_400)
        let bob3 = try await net.device("bob@example.org")
        try await net.notify(alice, about: bob.jid)
        #expect(
            keyedDevices(
                try await net.send("new phone?", from: alice, to: [bob.jid]), version: version)
                == [bob3.id])
    }

    /// A new identity key never raises a device's trust (review M1).
    @Test func identityChangeNeverRaisesTrust() throws {
        let jid = try JID("contact@example.org")
        func device(_ id: UInt32, _ trust: DeviceTrust) -> OMEMODevice {
            OMEMODevice(jid: jid, deviceID: id, active: true, trust: trust)
        }
        for previous in DeviceTrust.allCases {
            for siblings in [[], [device(2, .trusted)], [device(2, .verified)]] {
                let expected: DeviceTrust =
                    previous == .trusted && !siblings.contains { $0.trust == .verified }
                    ? .trusted : .undecided
                #expect(
                    TrustPolicy.trustAfterIdentityChange(previous: previous, among: siblings)
                        == expected, "\(previous) \(siblings.map(\.trust))")
            }
        }
    }

    // MARK: - Published elements

    @Test(arguments: [OMEMOVersion.v03, .v2])
    func publishedElementsHaveTheVersionShape(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let ns = version.rawValue
        let list = alice.engine.deviceListElement(version: version, devices: [alice.id, 42])
        let bundle = try await alice.engine.ownBundle(version: version)
        let identity = try #require(await alice.store.ownIdentity(version: version))
        switch version {
        case .v03:
            #expect(list.name == "list")
            #expect(
                DeviceList.node(version: version) == "eu.siacs.conversations.axolotl.devicelist")
            #expect(
                OMEMOBundle.node(version: version, deviceID: alice.id)
                    == "eu.siacs.conversations.axolotl.bundles:\(alice.id)")
            #expect(OMEMOBundle.itemID(version: version, deviceID: alice.id) == "current")
            #expect(
                bundle.elements.map(\.name) == [
                    "signedPreKeyPublic", "signedPreKeySignature", "identityKey", "prekeys",
                ])
            let identityKey = bundle.child("identityKey", namespace: ns).flatMap {
                Data(base64Encoded: $0.text)
            }
            #expect(identityKey == Data([0x05]) + identity.identityKeyPair.publicKey)
        case .v2:
            #expect(list.name == "devices")
            #expect(DeviceList.node(version: version) == "urn:xmpp:omemo:2:devices")
            #expect(
                OMEMOBundle.node(version: version, deviceID: alice.id) == "urn:xmpp:omemo:2:bundles"
            )
            #expect(OMEMOBundle.itemID(version: version, deviceID: alice.id) == String(alice.id))
            #expect(bundle.elements.map(\.name) == ["spk", "spks", "ik", "prekeys"])
            let identityKey = bundle.child("ik", namespace: ns).flatMap {
                Data(base64Encoded: $0.text)
            }
            #expect(identityKey == identity.identityKeyPair.publicKey)
        }
        #expect(list.namespace == ns)
        #expect(list.elements.map { $0[attribute: "id"] } == [String(alice.id), "42"])
        #expect(DeviceList.itemID == "current")
        #expect(bundle.name == "bundle")
        #expect(bundle.namespace == ns)
        #expect(bundlePreKeyIDs(bundle, version: version).count == 100)
        let parsed = try #require(OMEMOBundle.parse(bundle, version: version))
        #expect(parsed.identityKey == identity.identityKeyPair.publicKey)
        #expect(parsed.hasValidSignature(version: version))
        #expect(parsed.preKeys.count == 100)
        #expect(DeviceList.deviceIDs(in: list, version: version) == [alice.id, 42])
        #expect(DeviceList.deviceIDs(in: bundle, version: version) == nil)

        let options = OMEMOBundle.publishOptions(version: version).map { "\($0.key)=\($0.value)" }
        #expect(options.contains("pubsub#access_model=[\"open\"]"))
        #expect(options.contains("pubsub#max_items=[\"max\"]") == (version == .v2))
        #expect(DeviceList.publishOptions.map(\.key) == ["pubsub#access_model"])
    }

    @Test func fingerprintsAreGroupsOfEightHexDigits() throws {
        let engine = OMEMOEngine(
            store: MemoryStore(), transport: PEPTransport(pep: FakePEP()),
            accountJID: try JID("alice@example.org"))
        let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 7 + 0xA0) })
        let fingerprint = try #require(engine.fingerprint(of: key, version: .v03))
        let groups = fingerprint.split(separator: " ")
        #expect(groups.count == 8)
        #expect(groups.allSatisfy { $0.count == 8 })
        #expect(fingerprint.allSatisfy { $0 == " " || $0.isHexDigit && !$0.isUppercase })
        #expect(groups.joined() == key.hex)
        // Legacy keys as bundles carry them: the type byte is not part of the fingerprint.
        #expect(engine.fingerprint(of: Data([0x05]) + key, version: .v03) == fingerprint)
    }
}

// MARK: - Reading bundles independently of the engine

func bundlePreKeyIDs(_ bundle: Element, version: OMEMOVersion) -> [UInt32] {
    let ns = version.rawValue
    let name = version == .v03 ? "preKeyPublic" : "pk"
    let attribute = version == .v03 ? "preKeyId" : "id"
    return (bundle.child("prekeys", namespace: ns)?.children(name, namespace: ns) ?? [])
        .compactMap { $0[attribute: attribute].flatMap { UInt32($0) } }
}

func bundleSignedPreKeyID(_ bundle: Element, version: OMEMOVersion) -> UInt32? {
    let ns = version.rawValue
    switch version {
    case .v03:
        return bundle.child("signedPreKeyPublic", namespace: ns)?[attribute: "signedPreKeyId"]
            .flatMap { UInt32($0) }
    case .v2:
        return bundle.child("spk", namespace: ns)?[attribute: "id"].flatMap { UInt32($0) }
    }
}
