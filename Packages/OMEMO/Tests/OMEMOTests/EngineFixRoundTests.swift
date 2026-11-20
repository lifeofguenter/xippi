import Foundation
import Testing
import XMPPCore

@testable import OMEMO

/// A transport on a `FakePEP` that counts its calls; bundle fetches for `hanging` devices
/// are held at a gate until the test opens it with `release()`.
actor CountingTransport: OMEMOTransport {
    let pep: FakePEP
    var hanging: Set<UInt32> = []
    private var gate: [CheckedContinuation<Void, Never>] = []
    private(set) var listFetches = 0
    private(set) var bundleFetches = 0

    init(pep: FakePEP) {
        self.pep = pep
    }

    func hang(bundleOf deviceID: UInt32) { hanging.insert(deviceID) }

    /// Fetches held at the gate now.
    var held: Int { gate.count }

    /// Opens the gate: held fetches answer, and later ones are not held.
    func release() {
        hanging = []
        for fetch in gate { fetch.resume() }
        gate = []
    }

    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element? {
        listFetches += 1
        return await pep.list(of: jid, version: version)
    }

    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
    {
        bundleFetches += 1
        if hanging.contains(deviceID) { await withCheckedContinuation { gate.append($0) } }
        return await pep.bundle(of: jid, deviceID: deviceID, version: version)
    }
}

/// Set once, read by the test.
actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// Fix round 2 of Task 17b: decryption never waits on the network, a repair fetches outside
/// the engine's queue, an archived key exchange never displaces the current session, and a
/// device has one id in both versions.
@Suite struct EngineFixRoundTests {
    /// A device for `jid` on `net`'s PEP whose transport counts its calls.
    static func countedDevice(
        _ jid: String, on net: TestNetwork, bundleFetchTimeout: Duration = .seconds(2)
    ) async throws -> (TestDevice, CountingTransport) {
        let jid = try JID(jid)
        let store = MemoryStore()
        let transport = CountingTransport(pep: net.pep)
        let clock = net.clock
        let engine = OMEMOEngine(
            store: store, transport: transport, accountJID: jid, now: { clock.now },
            bundleFetchTimeout: bundleFetchTimeout)
        let id = try await engine.ensureOwnDevice(version: net.version)
        let device = TestDevice(jid: jid, engine: engine, store: store, id: id)
        try await net.publishBundle(of: device)
        await net.pep.setList(
            engine.deviceListElement(
                version: net.version, devices: await net.listedIDs(of: jid) + [id]),
            of: jid, version: net.version)
        return (device, transport)
    }

    @Test func decryptAsksForARepairInsteadOfFetching() async throws {
        let net = TestNetwork(version: .v03)
        let alice = try await net.device("alice@example.org")
        let (bob, transport) = try await Self.countedDevice("bob@example.org", on: net)
        let opened = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(opened.replies.first), from: bob, to: alice)
        await bob.store.deleteSession(with: alice.address, version: .v03)
        let lists = await transport.listFetches
        let bundles = await transport.bundleFetches

        let lost = try await bob.engine.decrypt(
            try await net.send("lost", from: alice, to: [bob.jid]), from: alice.jid,
            version: .v03)
        #expect(lost.content == .failed(.noSession))
        #expect(lost.repairWanted)
        #expect(lost.replies.isEmpty)
        #expect(await transport.listFetches == lists)
        #expect(await transport.bundleFetches == bundles)

        // The repair, run on its own, fetches the bundle and hands a new session over.
        let repair = try #require(
            try await bob.engine.repairSession(with: alice.address, version: .v03))
        #expect(repair.reason == .sessionRepair)
        #expect(await transport.bundleFetches == bundles + 1)
        #expect(try await net.deliver(repair, from: bob, to: alice).content == .empty)
        // Not twice within the hour.
        #expect(try await bob.engine.repairSession(with: alice.address, version: .v03) == nil)
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aMessageFromAnUnknownDeviceIsReadWithoutFetching(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let (bob, transport) = try await Self.countedDevice("bob@example.org", on: net)
        let alice = try await net.device("alice@example.org")
        let lists = await transport.listFetches

        let result = try await bob.engine.decrypt(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice.jid,
            version: version)
        #expect(result.body == "hello")
        #expect(result.senderUnknown)
        #expect(await transport.listFetches == lists)

        // Bob can still answer: encrypting reads the list it does not have.
        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")
    }

    @Test(.timeLimit(.minutes(1))) func aRepairFetchesOutsideTheEngineQueue() async throws {
        let net = TestNetwork(version: .v03)
        let alice = try await net.device("alice@example.org")
        // Nothing but the test's gate ends the bundle fetch: the engine does not give up on it.
        let (bob, transport) = try await Self.countedDevice(
            "bob@example.org", on: net, bundleFetchTimeout: .seconds(3_600))
        await transport.hang(bundleOf: alice.id)
        let repairing = Task {
            try await bob.engine.repairSession(with: alice.address, version: .v03)
        }
        for _ in 0..<1_000 where await transport.held == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.held == 1)

        // The engine takes other work while the repair's fetch is held. An engine that held
        // its queue over the fetch could not answer before the gate opens; the bound only says
        // how long such a failing run waits before the gate is opened anyway.
        let answered = Flag()
        let other = Task {
            _ = try await bob.engine.ownBundle(version: .v03)
            await answered.set()
        }
        for _ in 0..<3_000 where await !answered.value {
            try await Task.sleep(for: .milliseconds(10))
        }
        let answeredWhileHeld = await answered.value
        await transport.release()
        try await other.value
        #expect(answeredWhileHeld)
        // With the bundle, the repair hands a new session over.
        #expect(try await repairing.value != nil)
    }

    @Test(arguments: OMEMOVersion.allCases)
    func anArchivedKeyExchangeKeepsTheCurrentSession(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")

        // K1 reaches only the archive; alice loses her session and starts K2, which bob reads.
        let k1 = try await net.send("from K1", from: alice, to: [bob.jid])
        try await withdrawUsedPreKey(of: alice, toward: bob, version: version, on: net.pep)
        await alice.store.deleteSession(with: bob.address, version: version)
        let k2 = try await net.deliver(
            try await net.send("from K2", from: alice, to: [bob.jid]), from: alice, to: bob)
        #expect(k2.body == "from K2")
        _ = try await net.deliver(try #require(k2.replies.first), from: bob, to: alice)

        let archived = try await bob.engine.decrypt(
            k1, from: alice.jid, version: version, answering: false)
        #expect(archived.body == "from K1")
        #expect(archived.replies.isEmpty)

        // Bob still writes on K2's session, which alice has.
        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")
        let more = try await net.send("more", from: alice, to: [bob.jid])
        #expect(try await net.deliver(more, from: alice, to: bob).body == "more")
    }

    @Test func aDeviceHasOneIDInBothVersions() async throws {
        let net = TestNetwork(version: .v03)
        let alice = try await net.device("alice@example.org")
        #expect(try await alice.engine.ensureOwnDevice(version: .v2) == alice.id)

        // An id another device of the account lists in that version is not taken.
        let store = MemoryStore()
        let clock = net.clock
        let other = OMEMOEngine(
            store: store, transport: PEPTransport(pep: net.pep), accountJID: alice.jid,
            now: { clock.now })
        // OMEMO 2 comes first (R66: the legacy device takes its key); the account already
        // lists that id for another device in legacy.
        let modernID = try await other.ensureOwnDevice(version: .v2)
        await net.pep.setList(
            DeviceList.element(version: .v03, devices: [modernID]), of: alice.jid, version: .v03)
        #expect(try await other.ensureOwnDevice(version: .v03) != modernID)
    }

    // MARK: Round 3: identity changes and old key exchanges

    /// Bob's device id with a new identity key, as after a reinstall, or as anyone who
    /// knows the id and the public bundles can make it.
    static func impostor(of device: TestDevice, on net: TestNetwork) async throws -> TestDevice {
        let version = net.version
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
        return TestDevice(jid: device.jid, engine: engine, store: store, id: device.id)
    }

    /// Alice with a working session with bob, bob's device verified or blindly trusted.
    static func established(_ net: TestNetwork) async throws -> (TestDevice, TestDevice) {
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let hello = try await net.deliver(
            try await net.send("hello", from: bob, to: [alice.jid]), from: bob, to: alice)
        #expect(hello.body == "hello")
        _ = try await net.deliver(try #require(hello.replies.first), from: alice, to: bob)
        return (alice, bob)
    }

    @Test(arguments: OMEMOVersion.allCases)
    func anArchivedKeyExchangeUnderANewIdentityIsNotRead(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let (alice, bob) = try await Self.established(net)
        try await alice.engine.setTrust(.verified, for: bob.address, version: version)
        let session = await alice.store.session(with: bob.address, version: version)
        let preKeys = await alice.store.preKeyIDs(version: version)
        let known = await alice.store.device(bob.address, version: version)

        let forged = try await net.send(
            "forged", from: try await Self.impostor(of: bob, on: net), to: [alice.jid])
        let result = try await alice.engine.decrypt(
            forged, from: bob.jid, version: version, answering: false)

        #expect(result.content == .failed(.identityChanged))
        #expect(result.fingerprint == nil)
        #expect(await alice.store.session(with: bob.address, version: version) == session)
        #expect(await alice.store.preKeyIDs(version: version) == preKeys)
        #expect(await alice.store.device(bob.address, version: version) == known)
        // Bob's real device still reads alice and is read.
        let back = try await net.send("back", from: alice, to: [bob.jid])
        #expect(try await net.deliver(back, from: alice, to: bob).body == "back")
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aLiveKeyExchangeUnderANewIdentityIsTheNewIdentitys(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let (alice, bob) = try await Self.established(net)
        let oldKey = try #require(
            await alice.store.device(bob.address, version: version)?.identityKey)
        let impostor = try await Self.impostor(of: bob, on: net)
        let newKey = try #require(await impostor.store.ownIdentity(version: version))
            .identityKeyPair.publicKey

        let result = try await net.deliver(
            try await net.send("new key", from: impostor, to: [alice.jid]), from: impostor,
            to: alice)

        #expect(result.body == "new key")
        #expect(result.identityChanged)
        #expect(result.fingerprint == OMEMOEngine.fingerprint(of: newKey, version: version))
        #expect(result.fingerprint != OMEMOEngine.fingerprint(of: oldKey, version: version))
    }

    /// A sender repeats its key exchange until it hears back: two archived messages of the old
    /// one must leave the session that read newer messages current.
    @Test(arguments: OMEMOVersion.allCases)
    func twoArchivedCopiesOfAnOldKeyExchangeLeaveTheCurrentSession(version: OMEMOVersion)
        async throws
    {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")

        // K1 reaches only the archive, twice; alice loses her session and starts K2.
        let first = try await net.send("K1 one", from: alice, to: [bob.jid])
        let second = try await net.send("K1 two", from: alice, to: [bob.jid])
        try await withdrawUsedPreKey(of: alice, toward: bob, version: version, on: net.pep)
        await alice.store.deleteSession(with: bob.address, version: version)
        let k2 = try await net.deliver(
            try await net.send("from K2", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(k2.replies.first), from: bob, to: alice)

        for (copy, text) in [(first, "K1 one"), (second, "K1 two")] {
            let archived = try await bob.engine.decrypt(
                copy, from: alice.jid, version: version, answering: false)
            #expect(archived.body == text)
            #expect(archived.replies.isEmpty)
        }

        // Bob still writes on K2's session, which alice has.
        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")
    }

    /// A message on a session that was replaced since, read from the archive, leaves the
    /// newer session current.
    @Test(arguments: OMEMOVersion.allCases)
    func anArchivedMessageOnAReplacedSessionLeavesTheCurrentOne(version: OMEMOVersion)
        async throws
    {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        // K1, answered: alice's next message on it is a plain ratchet message.
        let k1 = try await net.deliver(
            try await net.send("hello", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(k1.replies.first), from: bob, to: alice)
        let onK1 = try await net.send("on K1", from: alice, to: [bob.jid])

        // That one reaches only the archive; alice loses her session and starts K2.
        await alice.store.deleteSession(with: bob.address, version: version)
        let k2 = try await net.deliver(
            try await net.send("from K2", from: alice, to: [bob.jid]), from: alice, to: bob)
        _ = try await net.deliver(try #require(k2.replies.first), from: bob, to: alice)

        let archived = try await bob.engine.decrypt(
            onK1, from: alice.jid, version: version, answering: false)
        #expect(archived.body == "on K1")

        let back = try await net.send("back", from: bob, to: [alice.jid])
        #expect(try await net.deliver(back, from: bob, to: alice).body == "back")
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceDistrustedDuringTheBundleFetchGetsNoRepair() async throws {
        let net = TestNetwork(version: .v03)
        let alice = try await net.device("alice@example.org")
        let (bob, transport) = try await Self.countedDevice(
            "bob@example.org", on: net, bundleFetchTimeout: .seconds(3_600))
        try await net.syncLists([alice, bob])
        await transport.hang(bundleOf: alice.id)
        let repairing = Task {
            try await bob.engine.repairSession(with: alice.address, version: .v03)
        }
        for _ in 0..<1_000 where await transport.held == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The user refuses alice's device while the fetch is held. An engine that held its
        // queue over the fetch could not take that before the gate opens; the bound only says
        // how long such a failing run waits.
        let refused = Flag()
        let refusing = Task {
            try await bob.engine.setTrust(.distrusted, for: alice.address, version: .v03)
            await refused.set()
        }
        for _ in 0..<3_000 where await !refused.value {
            try await Task.sleep(for: .milliseconds(10))
        }
        let refusedWhileHeld = await refused.value
        await transport.release()
        try await refusing.value
        #expect(refusedWhileHeld)
        #expect(try await repairing.value == nil)
        #expect(await bob.store.session(with: alice.address, version: .v03) == nil)
    }

    // MARK: Round 3, R57: a heartbeat is recorded only once it went out

    /// Alice sends `count` messages on one ratchet key to bob; the results of the last.
    static func flood(
        _ count: Int, from alice: TestDevice, to bob: TestDevice, on net: TestNetwork,
        from start: Int = 0
    ) async throws -> [DecryptedPayload] {
        var results: [DecryptedPayload] = []
        for counter in start..<(start + count) {
            results.append(
                try await net.deliver(
                    try await net.send("m\(counter)", from: alice, to: [bob.jid]), from: alice,
                    to: bob))
        }
        return results
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aHeartbeatNoAnswerCarriedIsNotRecorded(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        _ = try await Self.flood(1, from: alice, to: bob, on: net)
        // Bob refuses alice's device: no empty message goes to it, so no heartbeat either.
        try await bob.engine.setTrust(.distrusted, for: alice.address, version: version)
        let refused = try await Self.flood(53, from: alice, to: bob, on: net, from: 1)
        #expect(refused.allSatisfy { $0.replies.isEmpty })
        // Trusted again, the next message on the key still asks for the heartbeat.
        try await bob.engine.setTrust(.trusted, for: alice.address, version: version)
        let next = try await Self.flood(1, from: alice, to: bob, on: net, from: 54)
        #expect(next.first?.replies.map(\.reason) == [.heartbeat])
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aHeartbeatThatWasNotSentIsAskedForAgain(version: OMEMOVersion) async throws {
        let net = TestNetwork(version: version)
        let alice = try await net.device("alice@example.org")
        let bob = try await net.device("bob@example.org")
        let results = try await Self.flood(54, from: alice, to: bob, on: net)
        #expect(results.last?.replies.map(\.reason) == [.heartbeat])
        // It never went out (the stream was gone).
        try await bob.engine.heartbeatNotSent(to: alice.address, version: version)
        let next = try await Self.flood(1, from: alice, to: bob, on: net, from: 54)
        #expect(next.first?.replies.map(\.reason) == [.heartbeat])
    }

}
