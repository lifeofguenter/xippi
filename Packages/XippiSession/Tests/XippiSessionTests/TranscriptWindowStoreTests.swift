import Foundation
import Testing
import XippiSession
import XippiStore

/// The window against a real store: messages loaded well above the newest ones still follow
/// corrections, retractions and reactions.
@Suite(.timeLimit(.minutes(1))) struct TranscriptWindowStoreTests {
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let db: AppDatabase
        let accountID: Int64
        let chatID: Int64

        init() throws {
            db = try AppDatabase.inMemory()
            let account = try db.addAccount(
                AccountRecord(
                    jid: "me@x", enabled: true, resource: "r", clientID: "c", hostOverride: nil,
                    portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                    rosterVersion: nil, smResume: nil, createdAt: TranscriptWindowStoreTests.base))
            accountID = try #require(account.id)
            chatID = try #require(
                try db.ensureChat(accountID: accountID, jid: "bob@x", kind: .direct).id)
        }

        func fromBob(_ body: String?, at seconds: Int, origin: String) -> IncomingMessage {
            let date = TranscriptWindowStoreTests.base.addingTimeInterval(TimeInterval(seconds))
            return IncomingMessage(
                accountID: accountID, chatID: chatID, senderJID: "bob@x/phone", body: body,
                originID: origin, timestamp: date, receivedAt: date)
        }
    }

    @Test func loadedOlderPagesFollowEditsRetractionsAndReactions() async throws {
        let f = try Fixture()
        _ = try f.db.upsertIncoming((0..<300).map { f.fromBob("m\($0)", at: $0, origin: "o\($0)") })

        // Open at the newest 100, then load the page above them.
        let newest = try f.db.transcriptItems(
            for: try f.db.page(chatID: f.chatID, before: nil, limit: 100))
        var window = TranscriptWindow(messages: newest, reachesStart: false, reachesEnd: true)
        guard case .older(let before) = window.nextLoad(visible: 0..<20) else {
            Issue.record("No older page requested")
            return
        }
        let older = try f.db.transcriptItems(
            for: try f.db.page(chatID: f.chatID, before: before.cursor, limit: 100))
        window.prepend(older, complete: false)
        #expect(window.messages.count == 200)
        #expect(window.messages.first?.message.body == "m100")

        let range = window.observedRange
        var updates = f.db.transcriptUpdates(
            chatID: f.chatID, from: range.from?.cursor, through: range.through?.cursor,
            limit: window.limits.observation
        ).makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(window.merge(observed: initial).isEmpty)

        // m120 and m150 are in the older page, far outside the newest 80.
        var correction = f.fromBob("m150 fixed", at: 400, origin: "fix")
        correction.correctionOf = "o150"
        var retraction = f.fromBob(nil, at: 401, origin: "del")
        retraction.retractionOf = "o120"
        var reaction = f.fromBob(nil, at: 402, origin: "react")
        reaction.reactions = ReactionUpdate(targetID: "o130", emojis: ["👍"])
        _ = try f.db.upsertIncoming([correction, retraction, reaction])

        let id150 = try #require(window.messages.first { $0.message.originID == "o150" }?.id)
        let id120 = try #require(window.messages.first { $0.message.originID == "o120" }?.id)
        let id130 = try #require(window.messages.first { $0.message.originID == "o130" }?.id)
        var changed = Set<Int64>()
        while !changed.isSuperset(of: [id120, id130, id150]) {
            let next = try #require(await updates.next())
            changed.formUnion(window.merge(observed: next).changed)
        }
        let byID = Dictionary(uniqueKeysWithValues: window.messages.map { ($0.id, $0) })
        #expect(byID[id150]?.message.body == "m150 fixed")
        #expect(byID[id150]?.message.editedAt != nil)
        #expect(byID[id120]?.message.retracted == true)
        #expect(byID[id120]?.message.body == nil)
        #expect(byID[id130]?.reactions.map(\.emojis) == [["👍"]])
        #expect(window.messages.count == 200)
    }

    @Test func aWindowAroundAnOldMessageOpensThere() throws {
        let f = try Fixture()
        _ = try f.db.upsertIncoming(
            (0..<3_000).map { f.fromBob("m\($0)", at: $0, origin: "o\($0)") })
        let target = try #require(
            try f.db.search("m17", chatID: f.chatID).first { $0.body == "m17" }?.messageID)
        let around = try #require(
            try f.db.window(chatID: f.chatID, around: target, before: 40, after: 80))
        let window = TranscriptWindow(
            messages: try f.db.transcriptItems(for: around.messages),
            reachesStart: !around.hasOlder, reachesEnd: !around.hasNewer)
        #expect(window.messages.contains { $0.id == target })
        #expect(window.reachesStart)
        #expect(!window.reachesEnd)
        #expect(window.messages.count == 17 + 1 + 80)
    }
}
