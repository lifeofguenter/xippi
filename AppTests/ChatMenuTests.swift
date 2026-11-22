import AppKit
import Foundation
import Testing

@testable import Xippi
@testable import XippiSession
@testable import XippiStore

/// The sidebar's chat menu, run the way a click on its items runs them.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChatMenuTests {
    /// A room or channel stored for a new account in the test host's database.
    static func room(_ jid: String) throws -> (AppModel, ChatListItem) {
        let model = try #require(DebugSnapshot.model, "the test host's model")
        let account = try model.database.addAccount(
            AccountRecord(
                jid: "pin-\(UUID().uuidString.prefix(8))@example.org", enabled: false,
                resource: "test", clientID: UUID().uuidString, hostOverride: nil,
                portOverride: nil, directTLSOverride: nil, pinnedCertSHA256: [],
                rosterVersion: nil, smResume: nil, createdAt: Date()))
        let accountID = try #require(account.id)
        let chat = try model.database.ensureChat(accountID: accountID, jid: jid, kind: .room)
        let item = ChatListItem(
            id: try #require(chat.id), chat: chat, accountJID: account.jid, lastMessage: nil)
        return (model, item)
    }

    static func perform(_ title: String, in items: [NSMenuItem]) throws {
        let item = try #require(items.first { $0.title == title }, "\(title) in the menu")
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    /// The chat as stored once `pinned` is `wanted`, waiting for the write.
    static func stored(_ item: ChatListItem, in model: AppModel, pinned wanted: Bool)
        async throws -> ChatRecord?
    {
        var stored: ChatRecord?
        for _ in 0..<100 {
            stored = try model.database.chat(accountID: item.chat.accountID, jid: item.chat.jid)
            if stored?.pinned == wanted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return stored
    }

    /// A clicked item runs its closure. Named `perform(_:)`, the handler's selector was
    /// NSObject's `performSelector:`, and no closure item of any menu ran (Pin, Mark as read,
    /// Block, Report spam).
    @Test func aMenuItemRunsItsClosure() throws {
        var ran = false
        try Self.perform("Run", in: [MenuAction.item(title: "Run") { ran = true }])
        #expect(ran)
    }

    /// Pin from a room's menu is stored, and Unpin from the next menu takes it back.
    @Test func pinningARoomFromItsMenuIsStored() async throws {
        let (model, item) = try Self.room("lounge@conference.example.org")
        try Self.perform(
            Copy.pin, in: ChatRowActions.items(for: item, model: model, sheets: ChatSheets()))
        let pinned = try #require(try await Self.stored(item, in: model, pinned: true))
        #expect(pinned.pinned)

        let again = ChatListItem(
            id: item.id, chat: pinned, accountJID: item.accountJID, lastMessage: nil)
        try Self.perform(
            Copy.unpin, in: ChatRowActions.items(for: again, model: model, sheets: ChatSheets()))
        #expect(try await Self.stored(item, in: model, pinned: false)?.pinned == false)
    }

    /// A room the account is not in has Close; a joined room does not. Close takes the chat
    /// out of the list and off the screen, and opening it again puts it back.
    @Test func closingARoomNotJoinedAndOpeningItAgain() async throws {
        let (model, item) = try Self.room("old@conference.example.org")
        model.status.rooms[item.id] = .joined
        #expect(
            !ChatRowActions.items(for: item, model: model, sheets: ChatSheets()).contains {
                $0.title == Copy.closeChat
            })

        model.status.rooms[item.id] = .notJoined
        model.selection = item.id
        try Self.perform(
            Copy.closeChat,
            in: ChatRowActions.items(for: item, model: model, sheets: ChatSheets()))
        #expect(model.selection == nil)
        #expect(try await Self.stored(item, in: model) { $0.closed }?.closed == true)

        model.selection = item.id
        #expect(try await Self.stored(item, in: model) { !$0.closed }?.closed == false)
        model.selection = nil
        model.status.rooms[item.id] = nil
    }

    /// The chat as stored once `done` holds, waiting for the write.
    static func stored(
        _ item: ChatListItem, in model: AppModel, until done: (ChatRecord) -> Bool
    ) async throws -> ChatRecord? {
        var stored: ChatRecord?
        for _ in 0..<100 {
            stored = try model.database.chat(accountID: item.chat.accountID, jid: item.chat.jid)
            if let stored, done(stored) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return stored
    }
}
