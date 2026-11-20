import Foundation
import OMEMO
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A joined room whose occupants' real JIDs and affiliations come from presence.
actor AffiliatedRooms: RoomLifecycle {
    let own: RoomOccupant?
    let realJIDs: [JID: JID]
    let affiliations: [JID: MUCPresence.Affiliation]

    init(own: RoomOccupant?, realJIDs: [JID: JID], affiliations: [JID: MUCPresence.Affiliation]) {
        self.own = own
        self.realJIDs = realJIDs
        self.affiliations = affiliations
    }

    func ownOccupant(in chatID: Int64) async -> RoomOccupant? { own }
    func realJID(of occupant: JID) async -> JID? { realJIDs[occupant] }
    func affiliation(of occupant: JID) async -> MUCPresence.Affiliation? { affiliations[occupant] }
    func sessionStarted(ownJID: JID) async {}
    func sessionResumed() async {}
    func sessionEnded(resumable: Bool) async {}
    func handle(presence: Element) async -> Bool { false }
    func handle(message: Element) async -> Bool { false }
    func join(chatID: Int64) async {}
    func leave(chatID: Int64) async {}
    func changeNick(chatID: Int64, to nick: String) async {}
    func realJID(ofOccupantID occupantID: String, in room: JID) async -> JID? { nil }
    func reloadWanted() async {}
    func rosterItemRemoved(_ jid: JID) async {}
    func state(of chatID: Int64) async -> RoomState { .joined }
}

/// The account's store, failing one read of its pre keys (m17), or of a session (m22), when
/// armed.
final class FailingOnceStore: OMEMOStoreProtocol, Sendable {
    let base: OMEMOStoreAdapter
    let armed = Locked(false)
    let sessionReadArmed = Locked(false)

    init(base: OMEMOStoreAdapter) { self.base = base }

    struct Failure: Error {}

    func ownIdentity(version: OMEMO.OMEMOVersion) async throws -> OwnIdentity? {
        try await base.ownIdentity(version: version)
    }
    func saveOwnIdentity(_ identity: OwnIdentity, version: OMEMO.OMEMOVersion) async throws {
        try await base.saveOwnIdentity(identity, version: version)
    }
    func signedPreKeys(version: OMEMO.OMEMOVersion) async throws -> [SignedPreKey] {
        try await base.signedPreKeys(version: version)
    }
    func saveSignedPreKey(_ key: SignedPreKey, version: OMEMO.OMEMOVersion) async throws {
        try await base.saveSignedPreKey(key, version: version)
    }
    func deleteSignedPreKey(id: UInt32, version: OMEMO.OMEMOVersion) async throws {
        try await base.deleteSignedPreKey(id: id, version: version)
    }
    func preKeys(version: OMEMO.OMEMOVersion) async throws -> [OneTimePreKey] {
        if armed.value {
            armed.set(false)
            throw Failure()
        }
        return try await base.preKeys(version: version)
    }
    func preKey(id: UInt32, version: OMEMO.OMEMOVersion) async throws -> OneTimePreKey? {
        try await base.preKey(id: id, version: version)
    }
    func savePreKeys(_ keys: [OneTimePreKey], version: OMEMO.OMEMOVersion) async throws {
        try await base.savePreKeys(keys, version: version)
    }
    func devices(of jid: JID, version: OMEMO.OMEMOVersion) async throws -> [OMEMODevice] {
        try await base.devices(of: jid, version: version)
    }
    func saveDevice(_ device: OMEMODevice, version: OMEMO.OMEMOVersion) async throws {
        try await base.saveDevice(device, version: version)
    }
    func deviceJIDs(version: OMEMO.OMEMOVersion) async throws -> [JID] {
        try await base.deviceJIDs(version: version)
    }
    func session(with device: DeviceAddress, version: OMEMO.OMEMOVersion) async throws -> Data? {
        let fails = sessionReadArmed.withLock { armed in
            defer { armed = false }
            return armed
        }
        if fails { throw Failure() }
        return try await base.session(with: device, version: version)
    }
    func saveSession(_ state: Data, with device: DeviceAddress, version: OMEMO.OMEMOVersion)
        async throws
    {
        try await base.saveSession(state, with: device, version: version)
    }
    func saveSession(
        _ state: Data, with device: DeviceAddress, consumingPreKey preKeyID: UInt32,
        version: OMEMO.OMEMOVersion
    ) async throws {
        try await base.saveSession(
            state, with: device, consumingPreKey: preKeyID, version: version)
    }
    func deleteSession(with device: DeviceAddress, version: OMEMO.OMEMOVersion) async throws {
        try await base.deleteSession(with: device, version: version)
    }
}

/// Fix round 5 of Task 17b.
@Suite(.timeLimit(.minutes(1))) struct OMEMOFixRound5Tests {
    static let alice = SessionServer.account
    static let me = SessionServer.fullJID
    static let bob = "bob@example.test"
    static let carol = "carol@example.test"
    static let room = OMEMOPipelineTests.room

    static func deliver(_ stanza: Element, from: String, to harness: SessionHarness) throws {
        try harness.deliver(OMEMOPipelineTests.delivered(stanza, from: from))
    }

    // MARK: N6, R69 (a): a member is known in a fresh session, without a send

    /// A fresh session in a joined room; carol, a member and no contact, writes from a device
    /// the account has not read. Returns the OMEMO requests to carol before and after.
    static func memberWritesFromANewDevice(
        trust: RoomTrust, affiliation: MUCPresence.Affiliation?, joined: Bool
    ) async throws -> (Int, Int) {
        let pep = FakePEP()
        let carol = try OMEMOParty(Self.carol, pep: pep)
        await carol.start()
        let room = try JID(Self.room)
        pep.setMembers([try JID(Self.alice), carol.jid], affiliation: .member, of: room)
        let harness = try await SessionHarness { database, accountID in
            var chat = try database.ensureChat(accountID: accountID, jid: Self.room, kind: .room)
            chat.nick = "alice"
            chat.encryption = .omemo
            try database.updateChat(chat)
        }
        let occupant = try room.withResource("carol")
        await harness.session.setRoomLifecycle(
            AffiliatedRooms(
                own: RoomOccupant(jid: try room.withResource("alice")),
                realJIDs: [occupant: carol.jid],
                affiliations: affiliation.map { [occupant: $0] } ?? [:]))
        await harness.session.setRoomTrust(trust, for: room)
        let harnessReady = try await OMEMOPipelineTests.online(pep: pep, harness: harness)
        let chatID = try OMEMOPipelineTests.chatID(harnessReady, Self.room)
        if joined {
            // What the room lifecycle tells the session once the room is joined.
            await harnessReady.session.roomJoined(chatID: chatID, room: room)
            await harnessReady.session.omemo.settled()
        }

        let tablet = try OMEMOParty(Self.carol, pep: pep)
        await tablet.start()
        let before = OMEMOFixRoundTests.iqs(to: Self.carol, harnessReady)
        let omemoRoom = OMEMORoom(jid: room, isNonAnonymous: true, isMembersOnly: true)
        let message = try await tablet.send(
            "from my tablet", to: .room(omemoRoom, chatID: 1), id: "t1")
        try Self.deliver(message, from: "\(Self.room)/carol", to: harnessReady)
        try await waitUntil("stored") { try harnessReady.message(originID: "t1") != nil }
        await harnessReady.session.omemo.settled()
        try await harnessReady.barrier()
        let after = OMEMOFixRoundTests.iqs(to: Self.carol, harnessReady)
        await harnessReady.stop()
        return (before, after)
    }

    static let omemoRoomTrust = RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: true)

    @Test func aMemberByPresenceIsKnownWithoutASend() async throws {
        let (before, after) = try await Self.memberWritesFromANewDevice(
            trust: Self.omemoRoomTrust, affiliation: .member, joined: false)
        #expect(after > before)
    }

    @Test func aMemberByTheListReadOnJoinIsKnownWithoutASend() async throws {
        let (before, after) = try await Self.memberWritesFromANewDevice(
            trust: Self.omemoRoomTrust, affiliation: nil, joined: true)
        #expect(after > before)
    }

    @Test func noMemberIsKnownWhereOMEMOIsNotAllowed() async throws {
        let open = RoomTrust(stanzaIDs: true, nonAnonymous: true, membersOnly: false)
        let (before, after) = try await Self.memberWritesFromANewDevice(
            trust: open, affiliation: .member, joined: true)
        #expect(after == before)
    }

    // MARK: m16: a kept row that cannot be deleted holds nothing up

    @Test func aKeptRowThatCannotBeDeletedHoldsNoLiveMessage() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        let harness = try await OMEMOFixRound3Tests.online(
            pep: pep, seed: OMEMOFixRound3Tests.omemoChat(Self.bob))
        let account = try JID(Self.alice)
        let kept = try await bob.send("kept", to: .direct(account), id: "k1")
        let element = try #require(
            SessionServer.elements(OMEMOPipelineTests.delivered(kept, from: "\(Self.bob)/phone"))
                .first)
        #expect(
            try harness.database.keepOMEMOPending(
                OMEMOPendingRecord(
                    accountID: harness.accountID, stanza: element.xml(), carbon: nil,
                    receivedAt: Date(), sender: Self.bob, senderKnown: true)))
        // The store refuses every delete for now.
        await harness.session.setKeptDeleteFailures(Int.max)
        await harness.session.drainPendingOMEMO()
        #expect(try harness.message(originID: "k1")?.body == "kept")

        // A live message is read at once, not kept behind the row.
        let live = try await bob.send("live", to: .direct(account), id: "l1")
        try Self.deliver(live, from: "\(Self.bob)/phone", to: harness)
        try await waitUntil("live read") { try harness.message(originID: "l1")?.body == "live" }

        // Once the store takes deletes again, a later drain removes the row.
        await harness.session.setKeptDeleteFailures(0)
        await harness.session.drainPendingOMEMO()
        #expect(try harness.database.omemoPending(accountID: harness.accountID).isEmpty)
        #expect(try harness.messages().filter { $0.originID == "k1" }.count == 1)
        await harness.stop()
    }

    // MARK: m17: a retry after the session was saved

    @Test func aRetryAfterTheSessionWasSavedIsNotLost() async throws {
        let pep = FakePEP()
        let bob = try OMEMOParty(Self.bob, pep: pep)
        await bob.start()
        // Alice's manager on a store that fails once when armed.
        let alice = try OMEMOParty(Self.alice, pep: pep)
        let store = FailingOnceStore(
            base: OMEMOStoreAdapter(database: alice.database, accountID: alice.accountID))
        let manager = OMEMOManager(
            account: alice.jid, store: store, sender: alice.sender, now: { Date() })
        await manager.sessionStarted(accountFeatures: OMEMOParty.features)
        await manager.settled()

        let message = try await bob.send("hello", to: .direct(alice.jid))
        let encrypted = try #require(ChatMessage(element: message)?.encrypted)
        // The session is saved, then reading the pre keys to refill them fails.
        store.armed.set(true)
        let result = try #require(
            await manager.decrypt(encrypted, from: bob.jid, recipient: nil, known: true))
        // The refill is logged, not thrown (Task 17c, m20): the message is read.
        #expect(result.body == "hello")
    }
}
