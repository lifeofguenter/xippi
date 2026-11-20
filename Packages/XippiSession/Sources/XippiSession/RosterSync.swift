import Foundation
import Synchronization
import XMPPCore
import XippiStore

/// The account's roster (RFC 6121 section 2), kept in the database and in memory.
///
/// On a fresh session the roster is fetched with the stored version when the server versions
/// rosters (section 2.6): an empty answer keeps the stored roster, a full one replaces it.
/// Pushes change one item each and carry the next version. Only the account itself may push
/// (`Roster.push` checks the sender); anything else is answered with an error and not applied.
struct RosterSync {
    let database: AppDatabase
    let accountID: Int64
    /// The same items, for readers outside the session's actor.
    let snapshot: RosterSnapshot
    /// By bare JID.
    private(set) var items: [JID: RosterItem] = [:] {
        didSet { snapshot.set(items) }
    }

    init(database: AppDatabase, accountID: Int64, snapshot: RosterSnapshot) {
        self.database = database
        self.accountID = accountID
        self.snapshot = snapshot
    }

    /// Reads the stored roster into memory.
    mutating func load() throws {
        items = Dictionary(
            try database.rosterItems(accountID: accountID).compactMap(RosterItem.init(record:))
                .map { ($0.jid.bare, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The version to send with the roster get: the stored one, `""` to start versioning, or
    /// nil when the server does not version rosters.
    func versionToSend(serverVersions: Bool) throws -> String? {
        guard serverVersions else { return nil }
        return try database.account(id: accountID)?.rosterVersion ?? ""
    }

    /// Stores what a roster get returned.
    mutating func apply(_ fetch: RosterFetch) throws {
        switch fetch {
        case .unchanged:
            try load()
        case .full(let fetched, let version):
            try database.replaceRoster(
                accountID: accountID,
                with: fetched.filter { $0.subscription != .remove }.map {
                    $0.record(accountID: accountID)
                }, version: version)
            try load()
        }
    }

    /// Stores a roster push.
    mutating func apply(_ push: RosterPush) throws {
        let removed = push.item.subscription == .remove
        try database.applyRosterPush(
            accountID: accountID, jid: push.item.jid.bare.description,
            item: removed ? nil : push.item.record(accountID: accountID), version: push.version)
        let bare = push.item.jid.bare
        if push.item.subscription == .remove {
            items[bare] = nil
        } else {
            items[bare] = push.item
        }
    }

    func item(_ jid: JID) -> RosterItem? {
        items[jid.bare]
    }

    /// The contact may see the account's presence (subscription `from` or `both`), so it
    /// learns nothing new from receipts, markers, chat states or a ringing call: the privacy
    /// line for all of them.
    func sharesPresence(with jid: JID) -> Bool {
        items[jid.bare]?.sharesPresence == true
    }

    /// The account sees the contact's presence (subscription `to` or `both`): who it hears
    /// from anyway, and whose avatar it may ask for.
    func receivesPresence(from jid: JID) -> Bool {
        switch items[jid.bare]?.subscription {
        case .to, .both: true
        default: false
        }
    }
}

/// The roster as last stored, readable from any thread: what call routing asks while the
/// session's actor is busy.
final class RosterSnapshot: Sendable {
    private let items = Mutex<[JID: RosterItem]>([:])

    func set(_ items: [JID: RosterItem]) {
        self.items.withLock { $0 = items }
    }

    /// See `RosterSync.sharesPresence(with:)`.
    func sharesPresence(with jid: JID) -> Bool {
        items.withLock { $0[jid.bare]?.sharesPresence == true }
    }

    func name(of jid: JID) -> String? {
        items.withLock { $0[jid.bare]?.name }
    }
}

extension RosterItem {
    var sharesPresence: Bool { subscription == .from || subscription == .both }

    init?(record: RosterItemRecord) {
        guard let jid = try? JID(record.jid) else { return nil }
        self.init(
            jid: jid, name: record.name,
            subscription: Subscription(rawValue: record.subscription) ?? .none,
            ask: record.ask == "subscribe", groups: record.groups, approved: record.approved)
    }

    func record(accountID: Int64) -> RosterItemRecord {
        RosterItemRecord(
            accountID: accountID, jid: jid.bare.description, name: name,
            subscription: subscription.rawValue, ask: ask ? "subscribe" : nil, approved: approved,
            groups: groups)
    }
}
