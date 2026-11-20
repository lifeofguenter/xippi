import Foundation
import Testing

@testable import XippiStore

/// Following one contact's roster row, for the call buttons of the open chat.
@Suite(.timeLimit(.minutes(1))) struct RosterObservationTests {
    private func item(_ jid: String, subscription: String) -> RosterItemRecord {
        RosterItemRecord(
            accountID: 0, jid: jid, name: nil, subscription: subscription, ask: nil,
            approved: false, groups: [])
    }

    @Test func rosterItemUpdatesFollowsOneContact() async throws {
        let f = try StoreFixture()
        var updates = f.db.rosterItemUpdates(accountID: f.accountID, jid: StoreFixture.bobJID)
            .makeAsyncIterator()
        // Not in the roster yet.
        let initial = try #require(await updates.next())
        #expect(initial == nil)

        try f.db.applyRosterPush(
            accountID: f.accountID, jid: StoreFixture.bobJID,
            item: item(StoreFixture.bobJID, subscription: "to"), version: nil)
        let added = try #require(await updates.next())
        #expect(added?.subscription == "to")

        try f.db.applyRosterPush(
            accountID: f.accountID, jid: StoreFixture.bobJID, item: nil, version: nil)
        let removed = try #require(await updates.next())
        #expect(removed == nil)
    }

    @Test func otherContactsAndAccountsDoNotCount() async throws {
        let f = try StoreFixture()
        var updates = f.db.rosterItemUpdates(accountID: f.accountID, jid: StoreFixture.bobJID)
            .makeAsyncIterator()
        _ = try #require(await updates.next())
        try f.db.applyRosterPush(
            accountID: f.otherAccountID, jid: StoreFixture.bobJID,
            item: item(StoreFixture.bobJID, subscription: "both"), version: nil)
        try f.db.applyRosterPush(
            accountID: f.accountID, jid: "carol@example.com",
            item: item("carol@example.com", subscription: "both"), version: nil)
        try f.db.applyRosterPush(
            accountID: f.accountID, jid: StoreFixture.bobJID,
            item: item(StoreFixture.bobJID, subscription: "from"), version: nil)
        // Rows of others may or may not wake the stream; the first row that arrives is bob's.
        var row: RosterItemRecord?
        while row == nil {
            guard let next = await updates.next() else { break }
            row = next
        }
        #expect(row?.subscription == "from")
        #expect(row?.accountID == f.accountID)
    }
}
