import Foundation
import OMEMO
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// `OMEMOManager` between parties on a shared fake PEP service: publishing, device lists,
/// version choice, sending (rooms included) and the store adapter.
@Suite(.timeLimit(.minutes(1))) struct OMEMOManagerTests {
    static let room = "room@conference.example.test"

    static func parties(_ jids: String..., pep: FakePEP) async throws -> [OMEMOParty] {
        var parties: [OMEMOParty] = []
        for jid in jids {
            let party = try OMEMOParty(jid, pep: pep)
            await party.start()
            parties.append(party)
        }
        return parties
    }

    static func namespace(of stanza: Element) -> String? {
        ChatMessage(element: stanza)?.encrypted?.namespace
    }

    // MARK: Publishing

    @Test func ownDeviceIsPublishedWithOpenAccess() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        // Another device of the account is listed already (legacy only).
        pep.put(
            DeviceList.element(version: .v03, devices: [77]), id: "current",
            node: DeviceList.node(version: .v03), of: alice.jid)

        await alice.start()

        for version in OMEMO.OMEMOVersion.allCases {
            let id = try await alice.deviceID(version)
            #expect(
                pep.deviceIDs(of: alice.jid, version: version)
                    == (version == .v03 ? [77, id] : [id]))
            let lists = pep.published.filter { $0.node == DeviceList.node(version: version) }
            #expect(lists.count == 1)
            #expect(lists.first?.itemID == DeviceList.itemID)
            #expect(lists.first?.options["pubsub#access_model"] == "open")

            let node = OMEMOBundle.node(version: version, deviceID: id)
            let bundles = pep.published.filter { $0.node == node }
            #expect(bundles.count == 1)
            #expect(bundles.first?.itemID == OMEMOBundle.itemID(version: version, deviceID: id))
            #expect(bundles.first?.options["pubsub#access_model"] == "open")
            #expect(bundles.first?.options["pubsub#max_items"] == (version == .v2 ? "max" : nil))
            let stored = pep.items(node, of: alice.jid).last?.payload
            #expect(stored == (try await alice.manager.engine.ownBundle(version: version)))
        }
        #expect(pep.configured.isEmpty)

        // The next session finds this device listed: only the bundles go out again.
        await alice.start()
        for version in OMEMO.OMEMOVersion.allCases {
            let id = try await alice.deviceID(version)
            #expect(
                pep.published.filter { $0.node == DeviceList.node(version: version) }.count == 1)
            #expect(
                pep.published.filter {
                    $0.node == OMEMOBundle.node(version: version, deviceID: id)
                }.count == 2)
        }
    }

    @Test func serverWithoutPublishOptionsGetsTheNodeConfiguredAfter() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)

        await alice.start(features: [])

        #expect(pep.published.count == 4)
        #expect(pep.published.allSatisfy { $0.options.isEmpty })
        for version in OMEMO.OMEMOVersion.allCases {
            let id = try await alice.deviceID(version)
            for node in [
                DeviceList.node(version: version),
                OMEMOBundle.node(version: version, deviceID: id),
            ] {
                let configured = try #require(pep.configured.first { $0.node == node })
                #expect(configured.options["pubsub#access_model"] == "open")
            }
            #expect(pep.deviceIDs(of: alice.jid, version: version) == [id])
        }
    }

    @Test func nodeWithOtherSettingsIsConfiguredThenPublished() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        pep.refusePublishOnce(node: DeviceList.node(version: .v2))

        await alice.start()

        let id = try await alice.deviceID(.v2)
        #expect(pep.configured.map(\.node) == [DeviceList.node(version: .v2)])
        #expect(pep.configured.first?.options["pubsub#access_model"] == "open")
        #expect(pep.deviceIDs(of: alice.jid, version: .v2) == [id])
    }

    @Test func requestsEndWithinTheFetchTimeout() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        await alice.start()
        let bob = try OMEMOParty("bob@example.test", pep: pep)
        await bob.start()
        _ = try await alice.send("hi", to: .direct(bob.jid))

        #expect(alice.sender.timeouts.count >= 8)
        #expect(alice.sender.timeouts.allSatisfy { $0 <= .seconds(10) })
    }

    @Test func signedPreKeyRotatesOnALongSession() async throws {
        let pep = FakePEP()
        let date = ManualDate()
        let parties = try [
            OMEMOParty("alice@example.test", pep: pep, now: { date.now }),
            OMEMOParty("bob@example.test", pep: pep),
        ]
        let (alice, bob) = (parties[0], parties[1])
        for party in parties { await party.start() }
        let before = try await alice.manager.engine.ownBundle(version: .v2)
        let published = pep.published.count

        // Less than a day on, a message changes nothing.
        date.advance(by: 86_000)
        _ = try await alice.send("1", to: .direct(bob.jid))
        await alice.manager.settled()
        #expect(pep.published.count == published)

        // A day on, nothing is due yet: the keys are looked at, nothing is published.
        date.advance(by: 400)
        _ = try await alice.send("2", to: .direct(bob.jid))
        await alice.manager.settled()
        #expect(pep.published.count == published)

        // Eight days on, the signed pre keys rotate and both bundles go out again.
        date.advance(by: 7 * 86_400)
        let stanza = try await bob.send("3", to: .direct(alice.jid))
        _ = try await alice.open(stanza, from: bob.jid)
        await alice.manager.settled()
        let after = try await alice.manager.engine.ownBundle(version: .v2)
        #expect(after != before)
        for version in OMEMO.OMEMOVersion.allCases {
            let id = try await alice.deviceID(version)
            let node = OMEMOBundle.node(version: version, deviceID: id)
            // OMEMO 2 also went out for the pre key bob's message used.
            let count = pep.published.filter { $0.node == node }.count
            #expect(version == .v03 ? count == 2 : count >= 2)
            #expect(
                pep.items(node, of: alice.jid).last?.payload
                    == (try await alice.manager.engine.ownBundle(version: version)))
        }
    }

    @Test func stopWaitsUntilNothingWorksOnTheStore() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        alice.sender.hold(true)
        await alice.manager.sessionStarted(accountFeatures: OMEMOParty.features)
        let stopped = Locked(false)
        let stopping = Task {
            await alice.manager.stop()
            stopped.set(true)
        }

        // The own devices are still being made: a new session's engine must not start yet.
        // A stop that does not wait returns within this time, even on a busy machine.
        for _ in 0..<200 where !stopped.value {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!stopped.value)
        alice.sender.hold(false)
        await stopping.value
        #expect(stopped.value)
        // What was asked for before the stop ended with it: nothing is published after.
        #expect(pep.published.isEmpty)
    }

    // MARK: Device lists

    @Test func ownDeviceListComesOnlyFromTheAccountsBareJID() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        await alice.start()
        let id = try await alice.deviceID(.v2)
        let node = DeviceList.node(version: .v2)
        func event(from: JID?, _ devices: [UInt32]) -> PubSubEvent {
            PubSubEvent(
                from: from, node: node,
                items: [
                    PubSubItem(
                        id: DeviceList.itemID,
                        payload: DeviceList.element(version: .v2, devices: devices))
                ])
        }
        func ownDevices() async throws -> [UInt32] {
            try await alice.manager.engine.devices(of: alice.jid, version: .v2).map(\.deviceID)
        }

        // From a resource of the account, or without a sender: dropped, though handled.
        #expect(
            await alice.manager.deviceListEvent(event(from: try alice.jid.withResource("x"), [5])))
        #expect(await alice.manager.deviceListEvent(event(from: nil, [6])))
        #expect(try await ownDevices().isEmpty)

        // Another account's list is that account's.
        let bob = try JID("bob@example.test")
        #expect(await alice.manager.deviceListEvent(event(from: bob, [8])))
        #expect(
            try await alice.manager.engine.devices(of: bob, version: .v2).map(\.deviceID) == [8])
        #expect(try await ownDevices().isEmpty)

        // The account's own, without this device: taken, and published again with it.
        #expect(await alice.manager.deviceListEvent(event(from: alice.jid, [9])))
        #expect(try await ownDevices() == [9])
        #expect(pep.deviceIDs(of: alice.jid, version: .v2) == [9, id])

        // Not a device list: not OMEMO's.
        #expect(
            !(await alice.manager.deviceListEvent(
                PubSubEvent(from: alice.jid, node: "urn:xmpp:bookmarks:1"))))
    }

    // MARK: Version

    @Test func ownDeviceUsesOneIDInBothVersions() async throws {
        let pep = FakePEP()
        let alice = try OMEMOParty("alice@example.test", pep: pep)
        await alice.start()
        #expect(try await alice.deviceID(.v03) == (try await alice.deviceID(.v2)))
    }

    /// OMEMO 2 only when every active device of the recipient, and of the account, has it: a
    /// device is the same device in both lists only under the same id.
    @Test func omemo2OnlyWhenEveryDeviceSupportsIt() async throws {
        let pep = FakePEP()
        let parties = try await Self.parties("alice@example.test", "bob@example.test", pep: pep)
        let (alice, bob) = (parties[0], parties[1])
        let bobID = try await bob.deviceID(.v2)
        func lists(_ jid: JID, legacy: [UInt32], modern: [UInt32]) async {
            for (version, ids) in [(OMEMO.OMEMOVersion.v03, legacy), (.v2, modern)] {
                _ = await alice.manager.deviceListEvent(
                    PubSubEvent(
                        from: jid, node: DeviceList.node(version: version),
                        items: [
                            PubSubItem(
                                id: DeviceList.itemID,
                                payload: DeviceList.element(version: version, devices: ids))
                        ]))
            }
        }
        func version(to jid: JID) async throws -> String? {
            Self.namespace(of: try await alice.send("hi", to: .direct(jid)))
        }

        // Two Xippi clients: one id in both lists.
        #expect(try await version(to: bob.jid) == OMEMO.OMEMOVersion.v2.rawValue)

        // Bob adds a phone with legacy OMEMO only and a tablet with OMEMO 2 only.
        await lists(bob.jid, legacy: [bobID, 4242], modern: [bobID, 5353])
        #expect(try await version(to: bob.jid) == OMEMO.OMEMOVersion.v03.rawValue)

        // The phone gets OMEMO 2 under its id.
        await lists(bob.jid, legacy: [bobID, 4242], modern: [bobID, 4242, 5353])
        #expect(try await version(to: bob.jid) == OMEMO.OMEMOVersion.v2.rawValue)

        // A client that keeps an id per version: its legacy device cannot be matched.
        let carol = try OMEMOParty("carol@example.test", pep: pep)
        await carol.start()
        let carolID = try await carol.deviceID(.v2)
        await lists(carol.jid, legacy: [carolID, 7], modern: [carolID, 9])
        #expect(try await version(to: carol.jid) == OMEMO.OMEMOVersion.v03.rawValue)

        // The account's own other device has legacy OMEMO only.
        await lists(bob.jid, legacy: [bobID], modern: [bobID])
        #expect(try await version(to: bob.jid) == OMEMO.OMEMOVersion.v2.rawValue)
        await lists(alice.jid, legacy: [31], modern: [])
        #expect(try await version(to: bob.jid) == OMEMO.OMEMOVersion.v03.rawValue)
    }

    // MARK: Messages

    @Test(arguments: OMEMO.OMEMOVersion.allCases)
    func messagesBothWaysAndTheAccountsOtherDeviceReadsItsCopy(
        version: OMEMO.OMEMOVersion
    ) async throws {
        let pep = FakePEP()
        // The second device of alice and bob first, so the first device finds both listed.
        let parties = try await Self.parties(
            "alice@example.test", "bob@example.test", "alice@example.test", pep: pep)
        let (alice2, bob, alice1) = (parties[0], parties[1], parties[2])
        for party in parties { await party.manager.setForcedVersion(version) }

        let toBob = try await alice1.send("hello bob", to: .direct(bob.jid))
        #expect(Self.namespace(of: toBob) == version.rawValue)
        #expect(!toBob.xml().contains("hello bob"))
        #expect(toBob.child("body")?.text == OMEMOManager.fallbackBody)
        #expect(toBob.child("store", namespace: ChatMessage.hintsNamespace) != nil)
        #expect(
            toBob.child("encryption", namespace: OMEMOManager.emeNamespace)?[
                attribute: "namespace"] == version.rawValue)
        #expect(try await bob.open(toBob, from: alice1.jid).body == "hello bob")
        // The sent carbon on alice's other device.
        let copy = try await alice2.open(toBob, from: alice1.jid, recipient: .direct(bob.jid))
        #expect(copy.body == "hello bob")
        // The sending device's own copy (an archive copy, a reflection).
        #expect(try await alice1.open(toBob, from: alice1.jid).content == .sentByThisDevice)
        // Each bundle without the pre keys just used is out before the next sender reads it:
        // a sender that picks a used one makes a key exchange nobody can read.
        for party in parties { await party.manager.settled() }

        let toAlice = try await bob.send("hello alice", to: .direct(alice1.jid))
        #expect(Self.namespace(of: toAlice) == version.rawValue)
        #expect(try await alice1.open(toAlice, from: bob.jid).body == "hello alice")
        #expect(try await alice2.open(toAlice, from: bob.jid).body == "hello alice")
        for party in parties { await party.manager.settled() }
        let reply = try await alice2.send("from my other Mac", to: .direct(bob.jid))
        #expect(try await bob.open(reply, from: alice2.jid).body == "from my other Mac")
    }

    @Test func keyExchangeIsAnsweredAndTheBundlePublishedAgain() async throws {
        let pep = FakePEP()
        let parties = try await Self.parties("alice@example.test", "bob@example.test", pep: pep)
        let (alice, bob) = (parties[0], parties[1])
        let bobID = try await bob.deviceID(.v2)
        let bundleNode = OMEMOBundle.node(version: .v2, deviceID: bobID)
        let published = pep.published.filter { $0.node == bundleNode }.count

        let stanza = try await alice.send("hi", to: .direct(bob.jid))
        let sentBefore = bob.sender.messages.count
        #expect(try await bob.open(stanza, from: alice.jid).body == "hi")

        // The empty message that completes the session goes back to alice.
        let answers = bob.sender.messages.dropFirst(sentBefore)
        let completion = try #require(answers.first)
        #expect(completion.to == alice.jid)
        let encrypted = try #require(ChatMessage(element: completion)?.encrypted)
        #expect(encrypted.child("payload", namespace: encrypted.namespace) == nil)
        #expect(try await alice.open(completion, from: bob.jid).content == .empty)
        // The used pre key leaves the published bundle.
        await bob.manager.settled()
        #expect(pep.published.filter { $0.node == bundleNode }.count == published + 1)
        #expect(
            pep.items(bundleNode, of: bob.jid).last?.payload
                == (try await bob.manager.engine.ownBundle(version: .v2)))
    }

    @Test func aResendIsEncryptedAgain() async throws {
        let pep = FakePEP()
        let parties = try await Self.parties("alice@example.test", "bob@example.test", pep: pep)
        let (alice, bob) = (parties[0], parties[1])

        let first = try await alice.send("once", to: .direct(bob.jid), id: "m1")
        let again = try await alice.send("once", to: .direct(bob.jid), id: "m1")
        #expect(again != first)
        #expect(try await bob.open(first, from: alice.jid).body == "once")
        #expect(try await bob.open(again, from: alice.jid).body == "once")
    }

    @Test func messagesThatCannotBeEncryptedAreNotSent() async throws {
        let pep = FakePEP()
        let parties = try await Self.parties("alice@example.test", "bob@example.test", pep: pep)
        let (alice, bob) = (parties[0], parties[1])
        let nobody = try JID("nobody@example.test")
        let plain = ChatMessage.text("secret", to: nobody)

        await #expect(throws: EncryptionError.noDevices(nobody)) {
            try await alice.manager.send(plain, to: .direct(nobody))
        }
        // Every device of bob refused.
        _ = try await alice.send("hi", to: .direct(bob.jid))
        for version in OMEMO.OMEMOVersion.allCases {
            try await alice.manager.engine.setTrust(
                .distrusted,
                for: DeviceAddress(jid: bob.jid, deviceID: try await bob.deviceID(version)),
                version: version)
        }
        await #expect(throws: EncryptionError.noTrustedDevices(bob.jid)) {
            try await alice.manager.send(
                ChatMessage.text("secret", to: bob.jid), to: .direct(bob.jid))
        }
        // A device without keys yet.
        let fresh = try OMEMOParty("carol@example.test", pep: pep)
        await #expect(throws: EncryptionError.notReady) {
            try await fresh.manager.send(
                ChatMessage.text("secret", to: bob.jid), to: .direct(bob.jid))
        }
        for party in parties + [fresh] {
            #expect(!party.sender.messages.contains { $0.xml().contains("secret") })
        }
    }

    // MARK: Rooms

    @Test func roomMessagesGoToEveryMemberAndOccupant() async throws {
        let pep = FakePEP()
        let parties = try await Self.parties(
            "alice@example.test", "bob@example.test", "carol@example.test", "dave@example.test",
            pep: pep)
        let (alice, bob, carol, dave) = (parties[0], parties[1], parties[2], parties[3])
        let room = try JID(Self.room)
        pep.setMembers([carol.jid], affiliation: .owner, of: room)
        pep.setMembers([alice.jid, bob.jid], affiliation: .member, of: room)
        let suitable = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)

        // Dave is in the room, not on its member lists (the room's own word).
        let stanza = try await alice.send(
            "to the room", to: .room(suitable, chatID: 1), occupants: { [dave.jid] })
        #expect(Self.namespace(of: stanza) != nil)
        #expect(stanza.type == "groupchat")
        for member in [bob, carol, dave] {
            let opened = try await member.open(stanza, from: alice.jid, recipient: .room(room))
            #expect(opened.body == "to the room")
        }

        for unsuitable in [
            OMEMORoom(jid: room, isNonAnonymous: false, isMembersOnly: true),
            OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: false),
        ] {
            await #expect(throws: EncryptionError.roomNotSuitable) {
                try await alice.manager.send(
                    ChatMessage.text("secret", to: room, type: .groupchat),
                    to: .room(unsuitable, chatID: 1))
            }
        }
        let empty = OMEMORoom(
            jid: try JID("empty@conference.example.test"), isNonAnonymous: true,
            isMembersOnly: true)
        await #expect(throws: EncryptionError.noRecipients) {
            try await alice.manager.send(
                ChatMessage.text("secret", to: empty.jid, type: .groupchat),
                to: .room(empty, chatID: 2))
        }
        #expect(!alice.sender.messages.contains { $0.xml().contains("secret") })
    }

    // MARK: Store adapter

    @Test func storeAdapterKeepsEverythingAsTheEngineGaveIt() async throws {
        let party = try OMEMOParty("alice@example.test", pep: FakePEP())
        let store = OMEMOStoreAdapter(database: party.database, accountID: party.accountID)
        let bob = try JID("bob@example.test")
        for version in OMEMO.OMEMOVersion.allCases {
            let pair = IdentityKeyPair.generate(version: version)
            let identity = OwnIdentity(
                deviceID: 0x7FFF_FFFF, identityKeyPair: pair,
                registrationID: version == .v03 ? 0x7FFF_FFFF : nil, signedPreKeyID: 3,
                nextPreKeyID: 0xFF_FFFE)
            try await store.saveOwnIdentity(identity, version: version)
            let read = try #require(try await store.ownIdentity(version: version))
            #expect(read.deviceID == identity.deviceID)
            #expect(read.identityKeyPair.privateKey == pair.privateKey)
            #expect(read.identityKeyPair.publicKey == pair.publicKey)
            #expect(read.registrationID == identity.registrationID)
            #expect(read.signedPreKeyID == 3 && read.nextPreKeyID == 0xFF_FFFE)

            let signed = SignedPreKey(
                id: 3, keyPair: .generate(), signature: Data([1, 2]),
                createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            try await store.saveSignedPreKey(signed, version: version)
            let readSigned = try await store.signedPreKeys(version: version)
            #expect(readSigned.map(\.id) == [3])
            #expect(readSigned.first?.keyPair.privateKey == signed.keyPair.privateKey)
            #expect(readSigned.first?.createdAt == signed.createdAt)

            let preKeys = (1...3).map { OneTimePreKey(id: UInt32($0), keyPair: .generate()) }
            try await store.savePreKeys(preKeys, version: version)
            #expect(
                try await store.preKey(id: 2, version: version)?.keyPair.publicKey
                    == preKeys[1].keyPair.publicKey)

            let device = OMEMODevice(
                jid: bob, deviceID: 9, label: "Phone", active: true,
                lastSeen: Date(timeIntervalSince1970: 1_800_000_100), identityKey: Data([7]),
                trust: .verified)
            try await store.saveDevice(device, version: version)
            #expect(try await store.devices(of: bob, version: version) == [device])

            let address = DeviceAddress(jid: bob, deviceID: 9)
            try await store.saveSession(
                Data([4]), with: address, consumingPreKey: 2, version: version)
            #expect(try await store.session(with: address, version: version) == Data([4]))
            #expect(try await store.preKeys(version: version).map(\.id) == [1, 3])
            try await store.deleteSession(with: address, version: version)
            #expect(try await store.session(with: address, version: version) == nil)
        }
        // The versions do not mix.
        #expect(
            try party.database.omemoAccount(accountID: party.accountID, version: .v2)?
                .identityPublic
                != party.database.omemoAccount(accountID: party.accountID, version: .v03)?
                .identityPublic)

        // A stored private key that does not give the stored public key is refused.
        var record = try #require(
            try party.database.omemoAccount(accountID: party.accountID, version: .v2))
        record.identityPublic = Data(repeating: 1, count: 32)
        try party.database.saveOMEMOAccount(record)
        await #expect(throws: OMEMOStoreAdapter.Corrupted.self) {
            _ = try await store.ownIdentity(version: .v2)
        }
    }
}
