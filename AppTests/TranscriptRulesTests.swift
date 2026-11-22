import AppKit
import SwiftUI
import Testing

@testable import Xippi
@testable import XippiSession
@testable import XippiStore

/// Who you are in the open chat, and the reactions under a message.
@MainActor @Suite struct TranscriptRulesTests {
    static func info(kind: ChatKind, nick: String?) -> OpenChatInfo {
        let record = ChatRecord(
            id: 1, accountID: 1, jid: "room@conference.example.org", kind: kind, name: "Room",
            pinned: false, muted: false, notify: .all, draft: nil, encryption: .none, nick: nick,
            password: nil, autojoin: false, lastActivity: nil, unreadCount: 0, mentionCount: 0,
            lastReadMessageID: nil, avatarHash: nil)
        return OpenChatInfo(
            ChatListItem(id: 1, chat: record, accountJID: "me@example.org", lastMessage: nil))
    }

    /// With more than one account the chat says which one you are in it, and in a room under
    /// which nick; with one there is nothing to mix up.
    @Test func theChatSaysWhoYouAreWithMoreThanOneAccount() {
        let room = Self.info(kind: .room, nick: "alice")
        #expect(AppModel.identity(for: room, accounts: 1) == nil)
        #expect(AppModel.identity(for: room, accounts: 2) == "as alice · me@example.org")
        let direct = Self.info(kind: .direct, nick: "alice")
        #expect(AppModel.identity(for: direct, accounts: 2) == "as me@example.org")
    }

    static let roomChat = TranscriptChat(
        id: 1, jid: "room@conference.example.org", name: "Room", isRoom: true, ownNick: "me",
        accountJID: "me@example.org")

    static func name(_ key: String, _ chat: TranscriptChat, _ occupants: Reactors.Occupants)
        -> String
    {
        Reactors.person(of: key, chat: chat, occupants: occupants).name
    }

    /// Who reacted, by name: "You" for the account however its reaction was keyed, a nick in
    /// a room (an occupant id through the messages it wrote), the contact in a direct chat.
    @Test func reactorsAreNamed() {
        let occupants = Reactors.Occupants(nicks: ["occ-carol": "carol"], own: ["occ-me"])
        let room = Self.roomChat
        #expect(Self.name("me@example.org", room, occupants) == Copy.you)
        #expect(Self.name("occ-me", room, occupants) == Copy.you)
        #expect(Self.name("room@conference.example.org/me", room, occupants) == Copy.you)
        #expect(Self.name("occ-carol", room, occupants) == "carol")
        #expect(Self.name("room@conference.example.org/dave", room, occupants) == "dave")
        #expect(Self.name("occ-gone", room, occupants) == Copy.someone)
        var direct = room
        direct.isRoom = false
        direct.name = "Bob Chen"
        #expect(Self.name("bob@example.org", direct, .init()) == "Bob Chen")
    }

    /// An occupant id is base64 and may hold a slash: it is never read as "room/nick". The
    /// list of who reacted showed the part after the slash ("lepIQuZwhpASU0=") as a name.
    @Test func anOccupantIDWithASlashIsNeverANick() {
        let room = Self.roomChat
        let id = "q7Xc/lepIQuZwhpASU0="
        #expect(Self.name(id, room, .init()) == Copy.someone)
        #expect(Self.name(id, room, .init(nicks: [id: "carol"])) == "carol")
        #expect(Self.name(id, room, .init(own: [id])) == Copy.you)
    }

    /// The room's members name the ids of everyone there, and say which one is the account,
    /// before anyone wrote in the loaded messages: your own reaction says "You".
    @Test func theRoomsMembersNameWhoReacted() {
        let members = [
            RoomMember(
                nick: "me", occupantID: "q7Xc/lepIQuZwhpASU0=", realJID: nil, role: nil,
                affiliation: nil, show: nil, status: nil, isSelf: true),
            RoomMember(
                nick: "carol", occupantID: "c4r0l=", realJID: nil, role: nil, affiliation: nil,
                show: nil, status: nil, isSelf: false),
        ]
        let occupants = Reactors.Occupants(messages: [], members: members)
        let room = Self.roomChat
        #expect(Self.name("q7Xc/lepIQuZwhpASU0=", room, occupants) == Copy.you)
        #expect(Self.name("c4r0l=", room, occupants) == "carol")
    }

    /// The list has your reactions first, then everyone's in the order they came: one line
    /// per person and emoji.
    @Test func yourReactionsComeFirstOnePerEmoji() {
        let records = [
            ReactionRecord(messageID: 1, reactorKey: "carol", emojis: ["👍", "🎉"]),
            ReactionRecord(messageID: 1, reactorKey: "me", emojis: ["👍"]),
            ReactionRecord(messageID: 1, reactorKey: "dave", emojis: ["👍"]),
        ]
        let given = Reactors.given(records) { key in
            key == "me"
                ? Reactor(name: Copy.you, colorKey: key, isSelf: true)
                : Reactor(name: key, colorKey: key)
        }
        #expect(given.map(\.reactor.name) == [Copy.you, "carol", "carol", "dave"])
        #expect(given.map(\.emoji) == ["👍", "👍", "🎉", "👍"])
    }

    /// "All" and a tab per emoji, counted, in the order the message shows them; a tab lists
    /// only its emoji.
    @Test func theTabsCountAndFilterTheList() {
        let carol = Reactor(name: "carol", colorKey: "carol")
        let given = [
            GivenReaction(
                emoji: "😂", reactor: Reactor(name: Copy.you, colorKey: "me", isSelf: true)),
            GivenReaction(emoji: "❤️", reactor: carol),
            GivenReaction(emoji: "😂", reactor: carol),
        ]
        let tabs = ReactionsList.tabs(given, emojis: ["😂", "❤️", "👍"])
        #expect(tabs.map(\.emoji) == ["😂", "❤️"])
        #expect(tabs.map(\.count) == [2, 1])
        #expect(ReactionsList.shown(given, filter: nil) == given)
        #expect(ReactionsList.shown(given, filter: "❤️").map(\.reactor) == [carol])
    }

    /// Each person shows with their picture: yours from your profile, the contact's in a
    /// direct chat, an occupant's from their presence in a room.
    @Test func eachPersonComesWithTheirPicture() {
        let room = Self.roomChat
        let occupants = Reactors.Occupants(
            nicks: ["occ-carol": "carol"], own: ["occ-me"], avatars: ["carol": "hash-carol"])
        func picture(_ key: String, _ chat: TranscriptChat, _ occupants: Reactors.Occupants)
            -> String?
        {
            Reactors.person(of: key, chat: chat, occupants: occupants, ownAvatarHash: "hash-me")
                .avatarHash
        }
        #expect(picture("occ-me", room, occupants) == "hash-me")
        #expect(picture("occ-carol", room, occupants) == "hash-carol")
        #expect(picture("room@conference.example.org/carol", room, occupants) == "hash-carol")
        var direct = room
        direct.isRoom = false
        direct.avatarHash = "hash-bob"
        #expect(picture("bob@example.org", direct, .init()) == "hash-bob")
    }

    /// Your own line takes your reaction back and closes the list; nobody else's line does
    /// anything, and where reactions cannot be sent yours does not either. The face opens
    /// the reaction picker.
    @Test func yourLineTakesYourReactionBack() throws {
        let you = GivenReaction(
            emoji: "👍", reactor: Reactor(name: Copy.you, colorKey: "me", isSelf: true))
        let carol = GivenReaction(emoji: "👍", reactor: Reactor(name: "carol", colorKey: "carol"))
        #expect(ReactionsList.takesBack(you, canRemove: true))
        #expect(!ReactionsList.takesBack(carol, canRemove: true))
        #expect(!ReactionsList.takesBack(you, canRemove: false))

        let (window, view) = Self.pill()
        defer {
            view.closePopover()
            window.close()
        }
        var removed: [String] = []
        var added = 0
        view.onRemove = { removed.append($0) }
        view.onAdd = { added += 1 }
        func list() throws -> ReactionsList {
            let popover = try #require(view.shownPopover)
            return try #require(
                (popover.contentViewController as? NSHostingController<ReactionsList>)?.rootView)
        }
        view.canChange = { false }
        view.openList()
        let fixed = try list()
        let changes = fixed.remove != nil || fixed.add != nil
        #expect(!changes)
        view.closePopover()

        view.canChange = { true }
        view.openList()
        let remove = try #require(try list().remove)
        remove("👍")
        #expect(removed == ["👍"])
        #expect(view.shownPopover == nil)
        view.openList()
        let add = try #require(try list().add)
        add()
        #expect(added == 1)
        #expect(view.shownPopover == nil)
    }

    /// The pill, with carol's 👍, in a window of its own.
    static func pill() -> (NSWindow, ReactionsView) {
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ReactionsView(frame: NSRect(x: 120, y: 80, width: 60, height: 24))
        window.contentView?.addSubview(view)
        view.show([(emoji: "👍", count: 1)], font: .systemFont(ofSize: 14))
        view.given = {
            [GivenReaction(emoji: "👍", reactor: Reactor(name: "carol", colorKey: "carol"))]
        }
        window.orderFront(nil)
        return (window, view)
    }

    static func click(_ view: NSView, at time: TimeInterval) throws -> NSEvent {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: time,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    /// A click outside the list closes it; when that click is on the pill, it does not open
    /// the list again at once. The next click does.
    @Test func theClickThatClosesTheListDoesNotOpenItAgain() throws {
        let (window, view) = Self.pill()
        defer {
            view.closePopover()
            window.close()
        }
        let clicked = ProcessInfo.processInfo.systemUptime
        view.openList()
        #expect(view.shownPopover != nil)
        // The list begins to close on the click, before the pill hears of it.
        view.shownPopover?.close()
        view.mouseDown(with: try Self.click(view, at: clicked))
        #expect(view.shownPopover == nil)
        view.mouseDown(with: try Self.click(view, at: ProcessInfo.processInfo.systemUptime))
        #expect(view.shownPopover != nil)
    }

    /// A click on the reactions opens the list of who gave them right over the pill, and
    /// changes no reaction: before, a click added or took back your own. Shown before its
    /// content had a size, a popover opened some 280 points away.
    @Test func aClickOnTheReactionsOpensTheListOverThem() throws {
        let (window, view) = Self.pill()
        var removed: [String] = []
        view.canChange = { true }
        view.onRemove = { removed.append($0) }
        defer {
            view.closePopover()
            window.close()
        }
        view.mouseDown(with: try Self.click(view, at: ProcessInfo.processInfo.systemUptime))
        let popover = try #require(view.shownPopover)
        #expect(popover.contentViewController is NSHostingController<ReactionsList>)
        let shown = try #require(popover.contentViewController?.view.window)
        let pill = window.convertToScreen(view.convert(view.bounds, to: nil))
        #expect(abs(shown.frame.minY - pill.maxY) < 12, "list \(shown.frame), pill \(pill)")
        #expect(shown.frame.minX < pill.midX && shown.frame.maxX > pill.midX)
        #expect(removed.isEmpty)
    }
}
