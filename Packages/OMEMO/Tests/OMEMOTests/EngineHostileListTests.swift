import Foundation
import Testing
import XMPPCore

@testable import OMEMO

/// Final review I-3: one contact's device list, however long, never holds up the account.
/// Bundles are read outside the engine's queue, a message starts a bounded number of new
/// sessions per recipient, and recording keys costs one key conversion per key, not one per
/// key already known.
@Suite struct EngineHostileListTests {
    static let hostileCount = 1_000

    /// `jid` lists `ids` in `version`, each with the bundle of `template` (when given).
    static func list(
        _ ids: [UInt32], of jid: JID, bundleOf template: TestDevice? = nil, on net: TestNetwork
    ) async throws {
        await net.pep.setList(
            DeviceList.element(version: net.version, devices: ids), of: jid, version: net.version)
        guard let template else { return }
        let bundle = try await template.engine.ownBundle(version: net.version)
        for id in ids {
            await net.pep.setBundle(bundle, of: jid, deviceID: id, version: net.version)
        }
    }

    /// A contact with 1,000 devices whose bundles never come: while a message to them waits
    /// for those bundles, another contact's message is read.
    @Test(.timeLimit(.minutes(1)), arguments: OMEMOVersion.allCases)
    func aHugeDeviceListDoesNotHoldUpAnotherContactsMessage(version: OMEMOVersion)
        async throws
    {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        // Nothing but the test's gate ends a bundle fetch.
        let (bob, transport) = try await EngineFixRoundTests.countedDevice(
            "bob@example.org", on: net, bundleFetchTimeout: .seconds(3_600))
        let mallory = try JID("mallory@example.org")
        let ids = (1...UInt32(Self.hostileCount)).map { $0 + 10_000 }
        try await Self.list(ids, of: mallory, on: net)
        try await net.notify(bob, about: mallory)
        for id in ids { await transport.hang(bundleOf: id) }
        // Bob can read alice's messages already.
        try await net.syncLists([alice, bob])
        let first = try await net.send("first", from: alice, to: [bob.jid])
        #expect(try await net.deliver(first, from: alice, to: bob).body == "first")

        let sending = Task { try await net.send("hello", from: bob, to: [mallory]) }
        for _ in 0..<1_000 where await transport.held == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.held > 0)

        // Alice's next message is read while mallory's bundles are still on their way. An
        // engine that held its queue over the fetches could not read it before the gate opens;
        // the bound only says how long such a failing run waits.
        let next = try await net.send("next", from: alice, to: [bob.jid])
        let read = Flag()
        let reading = Task {
            let result = try await net.deliver(next, from: alice, to: bob)
            await read.set()
            return result
        }
        for _ in 0..<500 where await !read.value {
            try await Task.sleep(for: .milliseconds(10))
        }
        let readWhileHeld = await read.value
        await transport.release()
        #expect(readWhileHeld)
        #expect(try await reading.value.body == "next")
        // Mallory's bundles are all missing: nothing could be sealed for them.
        await #expect(throws: OMEMOError.self) { try await sending.value }
    }

    /// A message starts at most `newDevicesPerMessage` sessions with one recipient; the rest
    /// follow with later messages, and devices already reached keep getting keys.
    @Test(arguments: OMEMOVersion.allCases)
    func newSessionsPerRecipientAreBoundedPerMessage(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let (bob, transport) = try await EngineFixRoundTests.countedDevice(
            "bob@example.org", on: net)
        let template = try await net.device("mallory@example.org")
        let mallory = template.jid
        let cap = OMEMOEngine.newDevicesPerMessage
        let ids = (1...UInt32(cap * 2 + 10)).map { $0 + 10_000 }
        try await Self.list(ids, of: mallory, bundleOf: template, on: net)
        try await net.notify(bob, about: mallory)
        try await net.notify(bob, about: bob.jid)

        var reached: Set<UInt32> = []
        for round in 1...3 {
            let before = await transport.bundleFetches
            let sent = try await net.send("round \(round)", from: bob, to: [mallory])
            let fetched = await transport.bundleFetches - before
            #expect(fetched <= cap)
            let keyed = keyedDevices(sent, version: version)
            #expect(keyed.isSuperset(of: reached))
            #expect(keyed.count == min(reached.count + cap, ids.count))
            reached = keyed
        }
        #expect(reached == Set(ids))
    }

    /// Recording a key compares it with the contact's other keys through their canonical
    /// form (R60), which costs two point conversions: each key is converted once, not once
    /// per key recorded after it.
    @Test func recordingKeysConvertsEachKeyOnce() async throws {
        let store = MemoryStore()
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: FakePEP()),
            accountJID: try JID("bob@example.org"))
        let mallory = try JID("mallory@example.org")
        let count = 200
        for index in 0..<count {
            for version in OMEMOVersion.allCases {
                let device = OMEMODevice(
                    jid: mallory, deviceID: UInt32(index + 1), active: true, trust: .trusted)
                await store.saveDevice(device, version: version)
            }
        }
        for index in 0..<count {
            for version in OMEMOVersion.allCases {
                let key = IdentityKeyPair.generate(version: version).publicKey
                let device = try #require(
                    await store.device(
                        DeviceAddress(jid: mallory, deviceID: UInt32(index + 1)), version: version))
                _ = try await engine.recordIdentity(key, of: device, version: version)
            }
        }
        // One conversion per key recorded (and per key found), never a scan's worth each time.
        #expect(await engine.canonicalConversions <= 2 * count * 2)
    }

    /// A list's new devices take their trust from what was known before the list (BTBV):
    /// a verified device before it makes every new one wait for the user.
    @Test func aLongListTakesBlindTrustOnce() async throws {
        let net = TestNetwork(version: .v2)
        let bob = try await net.device("bob@example.org")
        let mallory = try JID("mallory@example.org")
        let ids = (1...UInt32(Self.hostileCount)).map { $0 + 10_000 }
        try await Self.list(ids, of: mallory, on: net)
        let update = try await net.notify(bob, about: mallory)
        #expect(update.added.count == Self.hostileCount)
        #expect(update.added.allSatisfy { $0.trust == .trusted })
    }

}

/// Final review I-2: a device the user distrusted that goes on writing is told apart from one
/// that wrote before the user's decision. Distrusting forgets when the device was last heard
/// from, so a time there afterwards is a message that came from it while distrusted.
@Suite struct EngineDistrustedSenderTests {
    @Test(arguments: OMEMOVersion.allCases)
    func aDistrustedDeviceThatWritesIsHeardFromAgain(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        try await net.syncLists([alice, bob])
        let before = try await net.send("before", from: alice, to: [bob.jid])
        #expect(try await net.deliver(before, from: alice, to: bob).senderTrust == .trusted)
        #expect(await bob.store.device(alice.address, version: version)?.lastSeen != nil)

        try await bob.engine.setTrust(.distrusted, for: alice.address, version: version)
        #expect(await bob.store.device(alice.address, version: version)?.lastSeen == nil)

        net.clock.advance(by: 60)
        let after = try await net.send("after", from: alice, to: [bob.jid])
        let read = try await net.deliver(after, from: alice, to: bob)
        #expect(read.body == "after")
        #expect(read.senderTrust == .distrusted)
        // Nothing answers a distrusted device.
        #expect(read.replies.isEmpty)
        #expect(await bob.store.device(alice.address, version: version)?.lastSeen == net.clock.now)

        // By identity, the same.
        try await bob.engine.setTrust(.trusted, for: alice.address, version: version)
        let identity = try #require(try await bob.engine.identities(of: alice.jid).first)
        try await bob.engine.setTrust(
            .distrusted, forIdentity: try #require(identity.identityKey), of: alice.jid)
        #expect(await bob.store.device(alice.address, version: version)?.lastSeen == nil)
    }
}
