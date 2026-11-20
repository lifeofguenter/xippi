import Foundation
import Testing

@testable import XippiStore

/// Ruling R65: the OMEMO messages kept to read later are capped per sender and in total, and a
/// full store makes room from the oldest messages of senders not known, never from a known
/// sender's.
@Suite struct OMEMOPendingCapsTests {
    static let share = AppDatabase.maxOMEMOPendingPerSender
    static let total = AppDatabase.maxOMEMOPending

    static func record(_ f: StoreFixture, from sender: String, known: Bool, id: String)
        -> OMEMOPendingRecord
    {
        OMEMOPendingRecord(
            accountID: f.accountID, stanza: "<message id='\(id)'/>", carbon: nil,
            receivedAt: StoreFixture.at(0), sender: sender, senderKnown: known)
    }

    /// Each of `senders` keeps its full share, in turn.
    static func fill(_ f: StoreFixture, _ senders: [String], known: Bool) throws {
        for sender in senders {
            for index in 0..<share {
                #expect(
                    try f.db.keepOMEMOPending(
                        record(f, from: sender, known: known, id: "\(sender)-\(index)")))
            }
        }
    }

    static func ids(_ f: StoreFixture) throws -> [String] {
        try f.db.omemoPending(accountID: f.accountID).map {
            String($0.stanza.dropFirst("<message id='".count).dropLast("'/>".count))
        }
    }

    @Test func aSenderKeepsAtMostItsShare() throws {
        let f = try StoreFixture()
        try Self.fill(f, ["mallory@evil"], known: false)
        #expect(
            try !f.db.keepOMEMOPending(
                Self.record(f, from: "mallory@evil", known: false, id: "one more")))
        #expect(try f.db.keepOMEMOPending(Self.record(f, from: "eve@evil", known: false, id: "e")))
        #expect(try f.db.omemoPending(accountID: f.accountID).count == Self.share + 1)
    }

    /// Strangers fill the store to the top, from many addresses: a contact's message is still
    /// kept, and one kept before stays.
    @Test func aStrangerFloodCannotPushOutAContactsMessage() throws {
        let f = try StoreFixture()
        #expect(try f.db.keepOMEMOPending(Self.record(f, from: "bob@x", known: true, id: "early")))
        let strangers = (0..<(Self.total / Self.share + 2)).map { "s\($0)@evil" }
        for stranger in strangers {
            for index in 0..<Self.share {
                try f.db.keepOMEMOPending(
                    Self.record(f, from: stranger, known: false, id: "\(stranger)-\(index)"))
            }
        }
        #expect(try f.db.keepOMEMOPending(Self.record(f, from: "bob@x", known: true, id: "late")))
        let kept = try Self.ids(f)
        #expect(kept.contains("early"))
        #expect(kept.contains("late"))
        #expect(kept.count == Self.total)
    }

    /// A full store makes room from strangers' messages, oldest first, whoever comes next; a
    /// store full of known senders' messages keeps nothing more.
    @Test func aFullStoreMakesRoomFromStrangersOldestFirst() throws {
        let f = try StoreFixture()
        let strangers = (0..<(Self.total / Self.share / 2)).map { "s\($0)@evil" }
        let contacts = (0..<(Self.total / Self.share / 2)).map { "c\($0)@x" }
        try Self.fill(f, strangers, known: false)
        try Self.fill(f, contacts, known: true)
        #expect(try f.db.omemoPending(accountID: f.accountID).count == Self.total)

        #expect(try f.db.keepOMEMOPending(Self.record(f, from: "bob@x", known: true, id: "bob")))
        #expect(
            try f.db.keepOMEMOPending(Self.record(f, from: "eve@evil", known: false, id: "eve")))
        let kept = try Self.ids(f)
        #expect(kept.count == Self.total)
        #expect(!kept.contains("s0@evil-0"))
        #expect(!kept.contains("s0@evil-1"))
        #expect(kept.contains("s0@evil-2"))
        #expect(kept.filter { $0.hasPrefix("c") }.count == contacts.count * Self.share)
        #expect(kept.suffix(2) == ["bob", "eve"])
    }

    @Test func aStoreFullOfKnownSendersKeepsNothingMore() throws {
        let f = try StoreFixture()
        try Self.fill(f, (0..<(Self.total / Self.share)).map { "c\($0)@x" }, known: true)
        #expect(try !f.db.keepOMEMOPending(Self.record(f, from: "bob@x", known: true, id: "b")))
        #expect(try !f.db.keepOMEMOPending(Self.record(f, from: "eve@evil", known: false, id: "e")))
        #expect(try f.db.omemoPending(accountID: f.accountID).count == Self.total)
    }
}
