import Foundation
import Testing
import XMPPCore

@testable import OMEMO

/// A `MemoryStore` whose session saves fail while `failingSaves` is above zero, and whose
/// session deletes fail while `failingDeletes` is.
actor FailingSaveStore: OMEMOStoreProtocol {
    let base = MemoryStore()
    private var failingSaves = 0
    private var failingDeletes = 0

    struct Failure: Error {}

    func failSessionSaves(_ count: Int) { failingSaves = count }

    func failSessionDeletes(_ count: Int) { failingDeletes = count }

    private func saveFails() -> Bool {
        guard failingSaves > 0 else { return false }
        failingSaves -= 1
        return true
    }

    func ownIdentity(version: OMEMOVersion) async -> OwnIdentity? {
        await base.ownIdentity(version: version)
    }
    func saveOwnIdentity(_ identity: OwnIdentity, version: OMEMOVersion) async {
        await base.saveOwnIdentity(identity, version: version)
    }
    func signedPreKeys(version: OMEMOVersion) async -> [SignedPreKey] {
        await base.signedPreKeys(version: version)
    }
    func saveSignedPreKey(_ key: SignedPreKey, version: OMEMOVersion) async {
        await base.saveSignedPreKey(key, version: version)
    }
    func deleteSignedPreKey(id: UInt32, version: OMEMOVersion) async {
        await base.deleteSignedPreKey(id: id, version: version)
    }
    func preKeys(version: OMEMOVersion) async -> [OneTimePreKey] {
        await base.preKeys(version: version)
    }
    func preKey(id: UInt32, version: OMEMOVersion) async -> OneTimePreKey? {
        await base.preKey(id: id, version: version)
    }
    func savePreKeys(_ keys: [OneTimePreKey], version: OMEMOVersion) async {
        await base.savePreKeys(keys, version: version)
    }
    func devices(of jid: JID, version: OMEMOVersion) async -> [OMEMODevice] {
        await base.devices(of: jid, version: version)
    }
    func saveDevice(_ device: OMEMODevice, version: OMEMOVersion) async {
        await base.saveDevice(device, version: version)
    }
    func deviceJIDs(version: OMEMOVersion) async -> [JID] {
        await base.deviceJIDs(version: version)
    }
    func session(with device: DeviceAddress, version: OMEMOVersion) async -> Data? {
        await base.session(with: device, version: version)
    }
    func saveSession(_ state: Data, with device: DeviceAddress, version: OMEMOVersion)
        async throws
    {
        if saveFails() { throw Failure() }
        await base.saveSession(state, with: device, version: version)
    }
    func saveSession(
        _ state: Data, with device: DeviceAddress, consumingPreKey preKeyID: UInt32,
        version: OMEMOVersion
    ) async throws {
        if saveFails() { throw Failure() }
        await base.saveSession(state, with: device, consumingPreKey: preKeyID, version: version)
    }
    func deleteSession(with device: DeviceAddress, version: OMEMOVersion) async throws {
        if failingDeletes > 0 {
            failingDeletes -= 1
            throw Failure()
        }
        await base.deleteSession(with: device, version: version)
    }
}

/// Task 17c, m20: a store failure after the new identity key is recorded.
@Suite(.timeLimit(.minutes(1))) struct EngineStoreFailureTests {
    typealias Net = EngineIdentityTrustTests.Net

    /// This Mac's device of `jid` on a store whose session saves can be made to fail.
    static func failingDevice(_ jid: String, version: OMEMOVersion, on net: Net) async throws
        -> (TestDevice, FailingSaveStore)
    {
        let jid = try JID(jid)
        let store = FailingSaveStore()
        let clock = net.clock
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: net.pep), accountJID: jid,
            now: { clock.now })
        let id = try await engine.ensureOwnDevice(version: version)
        await net.pep.setBundle(
            try await engine.ownBundle(version: version), of: jid, deviceID: id, version: version)
        await net.pep.setList(
            engine.deviceListElement(version: version, devices: [id]), of: jid, version: version)
        return (TestDevice(jid: jid, engine: engine, store: store.base, id: id), store)
    }

    /// What the session's manager does (m10): a try that throws is tried again.
    static func read(
        _ encrypted: Element, from sender: JID, by device: TestDevice,
        version: OMEMOVersion
    ) async throws -> DecryptedPayload {
        do {
            return try await device.engine.decrypt(encrypted, from: sender, version: version)
        } catch {
            return try await device.engine.decrypt(encrypted, from: sender, version: version)
        }
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aSessionSaveThatFailsAfterTheNewKeyIsRecordedKeepsTheFlag(version: OMEMOVersion)
        async throws
    {
        let net = Net()
        let (alice, store) = try await Self.failingDevice(
            "alice@example.org", version: version, on: net)
        let bob = try await net.device("bob@example.org", versions: [version])
        let hello = try await net.send("hello", from: bob, to: alice.jid, version: version)
        _ = try await alice.engine.decrypt(hello, from: bob.jid, version: version)
        try await withdrawUsedPreKey(of: bob, toward: alice, version: version, on: net.pep)

        // Bob's device is reset; its first key exchange under the new key comes while the
        // store cannot save the session.
        let reset = try await EngineIdentityTrustTests.reinstalled(bob, version: version, on: net)
        let after = try await net.send("after reset", from: reset, to: alice.jid, version: version)
        await store.failSessionSaves(1)
        let read = try await Self.read(after, from: bob.jid, by: alice, version: version)
        #expect(read.body == "after reset")
        #expect(read.identityChanged)
        let newKey = try #require(await reset.store.ownIdentity(version: version))
            .identityKeyPair.publicKey
        #expect(read.fingerprint == OMEMOEngine.fingerprint(of: newKey, version: version))
    }

    /// The session that could not be saved is not answered: the device repeats its key
    /// exchange, and the next one is read on a session that is saved.
    @Test(arguments: OMEMOVersion.allCases)
    func aSessionNotSavedIsNotAnsweredAndTheNextKeyExchangeIsRead(version: OMEMOVersion)
        async throws
    {
        let net = Net()
        let (alice, store) = try await Self.failingDevice(
            "alice@example.org", version: version, on: net)
        let bob = try await net.device("bob@example.org", versions: [version])
        await store.failSessionSaves(1)
        let first = try await net.send("first", from: bob, to: alice.jid, version: version)
        let read = try await Self.read(first, from: bob.jid, by: alice, version: version)
        #expect(read.body == "first")
        #expect(read.replies.isEmpty)
        #expect(await alice.store.session(with: bob.address, version: version) == nil)

        let second = try await net.send("second", from: bob, to: alice.jid, version: version)
        let again = try await alice.engine.decrypt(second, from: bob.jid, version: version)
        #expect(again.body == "second")
        #expect(!again.identityChanged)
        #expect(again.replies.map(\.reason) == [.sessionCompletion])
        #expect(await alice.store.session(with: bob.address, version: version) != nil)
    }

    // MARK: Fix round 1, N7: the old key's session never outlives its record

    /// Alice, on a failing store, read bob's first message; bob's device is then reset, and
    /// its first key exchange under the new key is returned with the new identity key.
    static func resetAfterASession(version: OMEMOVersion) async throws -> (
        net: Net, alice: TestDevice, store: FailingSaveStore, bob: TestDevice, reset: TestDevice,
        after: Element, oldKey: Data, newKey: Data
    ) {
        let net = Net()
        let (alice, store) = try await Self.failingDevice(
            "alice@example.org", version: version, on: net)
        let bob = try await net.device("bob@example.org", versions: [version])
        let hello = try await net.send("hello", from: bob, to: alice.jid, version: version)
        _ = try await alice.engine.decrypt(hello, from: bob.jid, version: version)
        try await withdrawUsedPreKey(of: bob, toward: alice, version: version, on: net.pep)
        let oldKey = try #require(await bob.store.ownIdentity(version: version))
            .identityKeyPair.publicKey
        let reset = try await EngineIdentityTrustTests.reinstalled(bob, version: version, on: net)
        let newKey = try #require(await reset.store.ownIdentity(version: version))
            .identityKeyPair.publicKey
        let after = try await net.send("after reset", from: reset, to: alice.jid, version: version)
        return (net, alice, store, bob, reset, after, oldKey, newKey)
    }

    @Test(arguments: OMEMOVersion.allCases)
    func aFailedDeleteOfTheOldSessionChangesNothing(version: OMEMOVersion) async throws {
        let setup = try await Self.resetAfterASession(version: version)
        let (alice, bob) = (setup.alice, setup.bob)
        let record = await alice.store.device(bob.address, version: version)
        let session = await alice.store.session(with: bob.address, version: version)
        #expect(record?.identityKey == setup.oldKey)
        #expect(session != nil)

        await setup.store.failSessionDeletes(1)
        await #expect(throws: FailingSaveStore.Failure.self) {
            try await alice.engine.decrypt(setup.after, from: bob.jid, version: version)
        }
        #expect(await alice.store.device(bob.address, version: version) == record)
        #expect(await alice.store.session(with: bob.address, version: version) == session)

        // The next try reads it, flagged.
        let read = try await alice.engine.decrypt(setup.after, from: bob.jid, version: version)
        #expect(read.body == "after reset")
        #expect(read.identityChanged)
    }

    /// The reviewer's case: the delete fails, then the session save. No session of the old
    /// key is left current, and the next message to bob starts one on the new key.
    @Test(arguments: OMEMOVersion.allCases)
    func aFailedDeleteAndAFailedSaveLeaveNoOldSession(version: OMEMOVersion) async throws {
        let setup = try await Self.resetAfterASession(version: version)
        let (net, alice, bob, reset) = (setup.net, setup.alice, setup.bob, setup.reset)
        await setup.store.failSessionDeletes(1)
        await setup.store.failSessionSaves(1)
        let read = try await Self.read(setup.after, from: bob.jid, by: alice, version: version)
        #expect(read.body == "after reset")
        #expect(read.identityChanged)
        if let state = await alice.store.session(with: bob.address, version: version) {
            #expect(try StoredSession(encoded: state).remoteIdentityKey != setup.oldKey)
        }

        let reply = try await net.send("reply", from: alice, to: bob.jid, version: version)
        #expect(isKeyExchange(reply, for: bob.id, version: version) == true)
        let opened = try await reset.engine.decrypt(reply, from: alice.jid, version: version)
        #expect(opened.body == "reply")
    }

    /// Whatever left it there: a session under another key than the device's record is never
    /// sealed to; the device gets a new session from its bundle.
    @Test(arguments: OMEMOVersion.allCases)
    func aSessionUnderAnotherKeyThanTheRecordIsNeverSealedTo(version: OMEMOVersion)
        async throws
    {
        let setup = try await Self.resetAfterASession(version: version)
        let (net, alice, bob, reset) = (setup.net, setup.alice, setup.bob, setup.reset)
        var record = try #require(await alice.store.device(bob.address, version: version))
        record.identityKey = setup.newKey
        await alice.store.saveDevice(record, version: version)

        let reply = try await net.send("reply", from: alice, to: bob.jid, version: version)
        #expect(isKeyExchange(reply, for: bob.id, version: version) == true)
        let opened = try await reset.engine.decrypt(reply, from: alice.jid, version: version)
        #expect(opened.body == "reply")
        let state = try #require(await alice.store.session(with: bob.address, version: version))
        #expect(try StoredSession(encoded: state).remoteIdentityKey == setup.newKey)
    }

    // MARK: Fix round 1, m24: the pre key of a session not saved

    /// The device does not repeat its key exchange, because this side starts a session first:
    /// the pre key that read it is deleted with that session.
    @Test(arguments: OMEMOVersion.allCases)
    func thePreKeyOfASessionNotSavedGoesWithTheNextSession(version: OMEMOVersion)
        async throws
    {
        let net = Net()
        let (alice, store) = try await Self.failingDevice(
            "alice@example.org", version: version, on: net)
        let bob = try await net.device("bob@example.org", versions: [version])
        await store.failSessionSaves(1)
        let first = try await net.send("first", from: bob, to: alice.jid, version: version)
        let state = try #require(await bob.store.session(with: alice.address, version: version))
        let used = try #require(try StoredSession(encoded: state).pendingKeyExchange?.preKeyID)
        let read = try await Self.read(first, from: bob.jid, by: alice, version: version)
        #expect(read.body == "first")
        #expect(await alice.store.preKey(id: used, version: version) != nil)

        let reply = try await net.send("reply", from: alice, to: bob.jid, version: version)
        #expect(
            try await bob.engine.decrypt(reply, from: alice.jid, version: version).body == "reply")
        #expect(await alice.store.preKey(id: used, version: version) == nil)
    }
}
