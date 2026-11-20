import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct OMEMOStoreTests {
    @Test func ownIdentityRoundTripsAndUpdates() throws {
        let f = try StoreFixture()
        var own = OMEMOAccountRecord(
            accountID: f.accountID, version: .v2, deviceID: 1234, identityPrivate: Data([1, 2, 3]),
            identityPublic: Data([4, 5, 6]), registrationID: nil, signedPreKeyID: 1,
            nextPreKeyID: 101)
        try f.db.saveOMEMOAccount(own)
        own.nextPreKeyID = 201
        try f.db.saveOMEMOAccount(own)
        #expect(try f.db.omemoAccount(accountID: f.accountID, version: .v2) == own)
        #expect(try f.db.omemoAccount(accountID: f.accountID, version: .v03) == nil)
    }

    @Test func devicesAndTrust() throws {
        let f = try StoreFixture()
        let phone = OMEMODeviceRecord(
            accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7, label: "Phone",
            active: true,
            lastSeen: nil, identityKey: Data([9, 9]), trust: .undecided)
        let laptop = OMEMODeviceRecord(
            accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 8, label: nil,
            active: true,
            lastSeen: nil, identityKey: nil, trust: .undecided)
        let legacy = OMEMODeviceRecord(
            accountID: f.accountID, jid: "bob@x", version: .v03, deviceID: 7, label: nil,
            active: true,
            lastSeen: nil, identityKey: nil, trust: .undecided)
        for device in [phone, laptop, legacy] { try f.db.saveOMEMODevice(device) }

        #expect(
            try f.db.omemoDevices(accountID: f.accountID, jid: "bob@x", version: .v2).map(
                \.deviceID) == [7, 8])
        #expect(
            try f.db.omemoDevices(accountID: f.accountID, jid: "bob@x", version: .v03).count == 1)
        try f.db.setOMEMOTrust(
            accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7, trust: .verified)
        #expect(
            try f.db.omemoDevice(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7)?
                .trust == .verified)
        #expect(
            try f.db.omemoDevice(accountID: f.accountID, jid: "bob@x", version: .v03, deviceID: 7)?
                .trust == .undecided)
        try f.db.deleteOMEMODevice(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 8)
        #expect(
            try f.db.omemoDevices(accountID: f.accountID, jid: "bob@x", version: .v2).map(
                \.deviceID) == [7])
    }

    @Test func sessionsAndPreKeys() throws {
        let f = try StoreFixture()
        let session = OMEMOSessionRecord(
            accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7, state: Data([1]))
        try f.db.saveOMEMOSession(session)
        var updated = session
        updated.state = Data([2, 2])
        try f.db.saveOMEMOSession(updated)
        #expect(
            try f.db.omemoSession(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7)
                == updated)
        #expect(
            try f.db.omemoSessions(accountID: f.accountID, jid: "bob@x", version: .v2) == [updated])
        try f.db.deleteOMEMOSession(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7)
        #expect(
            try f.db.omemoSession(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7)
                == nil)

        let preKeys = (1...3).map {
            OMEMOPreKeyRecord(
                accountID: f.accountID, version: .v2, keyID: $0, privateKey: Data([UInt8($0)]),
                publicKey: Data([UInt8($0 + 10)]))
        }
        try f.db.saveOMEMOPreKeys(preKeys)
        #expect(
            try f.db.omemoPreKeys(accountID: f.accountID, version: .v2).map(\.keyID) == [1, 2, 3])
        #expect(
            try f.db.omemoPreKey(accountID: f.accountID, version: .v2, keyID: 2)?.publicKey
                == Data([12]))
        #expect(try f.db.deleteOMEMOPreKey(accountID: f.accountID, version: .v2, keyID: 2))
        #expect(try f.db.deleteOMEMOPreKey(accountID: f.accountID, version: .v2, keyID: 2) == false)
        #expect(try f.db.omemoPreKeys(accountID: f.accountID, version: .v2).map(\.keyID) == [1, 3])

        let signed = OMEMOSignedPreKeyRecord(
            accountID: f.accountID, version: .v2, keyID: 1, privateKey: Data([1]),
            publicKey: Data([2]),
            signature: Data([3]), createdAt: StoreFixture.at(0))
        try f.db.saveOMEMOSignedPreKey(signed)
        #expect(
            try f.db.omemoSignedPreKey(accountID: f.accountID, version: .v2, keyID: 1) == signed)
        #expect(try f.db.omemoSignedPreKeys(accountID: f.accountID, version: .v2) == [signed])
        try f.db.deleteOMEMOSignedPreKey(accountID: f.accountID, version: .v2, keyID: 1)
        #expect(try f.db.omemoSignedPreKeys(accountID: f.accountID, version: .v2).isEmpty)
    }

    @Test func keysGoWithTheAccount() throws {
        let f = try StoreFixture()
        try f.db.saveOMEMOAccount(
            OMEMOAccountRecord(
                accountID: f.accountID, version: .v2, deviceID: 1, identityPrivate: Data([1]),
                identityPublic: Data([2]), registrationID: nil, signedPreKeyID: 1, nextPreKeyID: 1))
        try f.db.saveOMEMOPreKeys([
            OMEMOPreKeyRecord(
                accountID: f.accountID, version: .v2, keyID: 1, privateKey: Data([1]),
                publicKey: Data([2]))
        ])
        #expect(try f.db.removeAccount(id: f.accountID))
        #expect(try f.db.omemoAccount(accountID: f.accountID, version: .v2) == nil)
        #expect(try f.db.omemoPreKeys(accountID: f.accountID, version: .v2).isEmpty)
    }

    private func preKeys(_ f: StoreFixture, _ version: OMEMOVersion) -> [OMEMOPreKeyRecord] {
        (1...3).map {
            OMEMOPreKeyRecord(
                accountID: f.accountID, version: version, keyID: $0,
                privateKey: Data([UInt8($0)]), publicKey: Data([UInt8($0 + 10)]))
        }
    }

    @Test func sessionFromAKeyExchangeConsumesItsPreKey() throws {
        let f = try StoreFixture()
        try f.db.saveOMEMOPreKeys(preKeys(f, .v03) + preKeys(f, .v2))
        let session = OMEMOSessionRecord(
            accountID: f.accountID, jid: "bob@x", version: .v03, deviceID: 7, state: Data([1]))

        try f.db.saveOMEMOSession(session, consumingPreKey: 2)

        #expect(
            try f.db.omemoSession(accountID: f.accountID, jid: "bob@x", version: .v03, deviceID: 7)
                == session)
        #expect(
            try f.db.omemoPreKeys(accountID: f.accountID, version: .v03).map(\.keyID) == [1, 3])
        // The other version's key with the same id stays.
        #expect(
            try f.db.omemoPreKeys(accountID: f.accountID, version: .v2).map(\.keyID) == [1, 2, 3])

        // A key already gone: the session is still stored.
        var updated = session
        updated.state = Data([2, 2])
        try f.db.saveOMEMOSession(updated, consumingPreKey: 2)
        #expect(
            try f.db.omemoSession(accountID: f.accountID, jid: "bob@x", version: .v03, deviceID: 7)
                == updated)
        #expect(
            try f.db.omemoPreKeys(accountID: f.accountID, version: .v03).map(\.keyID) == [1, 3])
    }

    @Test func sessionThatCannotBeStoredKeepsThePreKey() throws {
        let f = try StoreFixture()
        try f.db.saveOMEMOPreKeys(preKeys(f, .v2))
        // Any write of a session fails from here on, after the pre key was deleted in the same
        // transaction.
        try f.db.writer.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER refuseSessions BEFORE INSERT ON omemoSession
                    BEGIN SELECT RAISE(ABORT, 'refused'); END
                    """)
        }
        let session = OMEMOSessionRecord(
            accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7, state: Data([1]))

        #expect(throws: (any Error).self) {
            try f.db.saveOMEMOSession(session, consumingPreKey: 2)
        }

        #expect(
            try f.db.omemoPreKeys(accountID: f.accountID, version: .v2).map(\.keyID) == [1, 2, 3])
        #expect(
            try f.db.omemoSession(accountID: f.accountID, jid: "bob@x", version: .v2, deviceID: 7)
                == nil)
    }

    /// Task 17c, m21: the oldest kept message the caller has not set aside, in one read.
    @Test func theNextKeptMessageSkipsTheOnesSetAside() throws {
        let f = try StoreFixture()
        let at = StoreFixture.at(0)
        for index in 1...3 {
            #expect(
                try f.db.keepOMEMOPending(
                    OMEMOPendingRecord(
                        accountID: f.accountID, stanza: "<message id='\(index)'/>",
                        carbon: nil, receivedAt: at)))
        }
        let ids = try f.db.omemoPending(accountID: f.accountID).compactMap(\.id)
        #expect(try f.db.nextOMEMOPending(accountID: f.accountID, excluding: [])?.id == ids[0])
        #expect(
            try f.db.nextOMEMOPending(accountID: f.accountID, excluding: [ids[0]])?.id == ids[1])
        #expect(
            try f.db.nextOMEMOPending(accountID: f.accountID, excluding: [ids[0], ids[2]])?.id
                == ids[1])
        #expect(try f.db.nextOMEMOPending(accountID: f.accountID, excluding: Set(ids)) == nil)
    }

    /// Messages that came while OMEMO waited for the store come back in the order they came,
    /// go with their account, and are bounded.
    @Test func keptMessagesComeBackInOrder() throws {
        let f = try StoreFixture()
        let at = StoreFixture.at(0)
        for index in 1...3 {
            #expect(
                try f.db.keepOMEMOPending(
                    OMEMOPendingRecord(
                        accountID: f.accountID, stanza: "<message id='\(index)'/>",
                        carbon: index == 2 ? "sent" : nil, receivedAt: at)))
        }
        let kept = try f.db.omemoPending(accountID: f.accountID)
        #expect(
            kept.map(\.stanza) == ["<message id='1'/>", "<message id='2'/>", "<message id='3'/>"])
        #expect(kept.map(\.carbon) == [nil, "sent", nil])
        let first = try #require(try f.db.nextOMEMOPending(accountID: f.accountID))
        #expect(first.stanza == "<message id='1'/>")
        try f.db.deleteOMEMOPending(id: try #require(first.id))
        #expect(try f.db.nextOMEMOPending(accountID: f.accountID)?.stanza == "<message id='2'/>")

        for index in 0..<(AppDatabase.maxOMEMOPending - 2) {
            try f.db.keepOMEMOPending(
                OMEMOPendingRecord(
                    accountID: f.accountID, stanza: "<message id='f\(index)'/>", carbon: nil,
                    receivedAt: at))
        }
        #expect(
            try !f.db.keepOMEMOPending(
                OMEMOPendingRecord(
                    accountID: f.accountID, stanza: "<message/>", carbon: nil, receivedAt: at)))

        // Removing the account removes what it kept.
        try f.db.writer.write {
            try $0.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [f.accountID])
        }
        #expect(try f.db.omemoPending(accountID: f.accountID).isEmpty)
    }

    /// R60: trust kept per version merges by identity key, contact by contact.
    @Test func deviceJIDsListEachContactOncePerVersion() throws {
        let f = try StoreFixture()
        for (jid, version, id) in [
            ("bob@x", OMEMOVersion.v2, 1), ("bob@x", .v2, 2), ("carol@x", .v03, 3),
            ("bob@x", .v03, 4),
        ] {
            try f.db.saveOMEMODevice(
                OMEMODeviceRecord(
                    accountID: f.accountID, jid: jid, version: version, deviceID: id, label: nil,
                    active: true, lastSeen: nil, identityKey: nil, trust: .trusted))
        }
        #expect(try f.db.omemoDeviceJIDs(accountID: f.accountID, version: .v2) == ["bob@x"])
        #expect(
            try f.db.omemoDeviceJIDs(accountID: f.accountID, version: .v03) == ["bob@x", "carol@x"])
    }

}
