import Foundation
import Testing
import XippiStore

@testable import XippiSession

@Suite("NotificationPolicy")
struct NotificationPolicyTests {
    typealias Policy = NotificationPolicy

    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A place in a chat's order: `minutes` after `base`, then the row id.
    private func at(_ minutes: Double, _ id: Int64) -> Policy.Position {
        Policy.Position(timestamp: Self.base.addingTimeInterval(minutes * 60), id: id)
    }

    private func chat(
        id: Int64 = 7, kind: ChatKind = .direct, muted: Bool = false, notify: NotifyLevel = .all,
        lastRead: Int64? = nil, encryption: EncryptionMode = .none
    ) -> ChatRecord {
        ChatRecord(
            id: id, accountID: 1, jid: kind == .direct ? "bob@example.com" : "room@conf.example",
            kind: kind, name: nil, pinned: false, muted: muted, notify: notify, draft: nil,
            encryption: encryption, nick: nil, password: nil, autojoin: false, lastActivity: nil,
            unreadCount: 1, mentionCount: 0, lastReadMessageID: lastRead, avatarHash: nil)
    }

    private func message(
        id: Int64 = 40, chatID: Int64 = 7, direction: MessageDirection = .incoming,
        body: String? = "Is 13.1 out yet?", nick: String? = nil, kind: MessageKind = .text,
        encryption: EncryptionMode = .none, retracted: Bool = false, mentionsMe: Bool = false,
        at timestamp: Date = Self.base
    ) -> MessageRecord {
        MessageRecord(
            id: id, accountID: 1, chatID: chatID, direction: direction,
            senderJID: "bob@example.com/phone", senderNick: nick, occupantID: nil, body: body,
            archiveID: nil, originID: nil, stanzaMessageID: nil, timestamp: timestamp,
            receivedAt: timestamp, state: .sent, errorText: nil, encryption: encryption,
            senderDeviceFingerprint: nil, replyToMessageID: nil, replyToSenderLabel: nil,
            replyQuote: nil, editedAt: nil, retracted: retracted, moderatedBy: nil,
            moderationReason: nil, kind: kind, mentionsMe: mentionsMe)
    }

    private func context(
        contact: Bool = true, unknownSenders: Bool = false, keywords: [String] = [],
        open: Int64? = nil, previews: Policy.Previews = .whenUnlocked, doNotDisturb: Bool = false,
        marker: Policy.Position? = nil, messageText: Policy.MessageText = .show
    ) -> Policy.Context {
        Policy.Context(
            senderIsContact: contact, notifyUnknownSenders: unknownSenders, keywords: keywords,
            openChatID: open, previews: previews, messageText: messageText,
            doNotDisturb: doNotDisturb, readMarker: marker)
    }

    private func posted(_ decision: Policy.Decision) -> Policy.Notification? {
        if case .post(let notification) = decision { return notification }
        return nil
    }

    // MARK: Posting

    @Test func directMessageFromContactPostsItsText() throws {
        let notification = try #require(
            posted(Policy.decide(message(), in: chat(), context: context())))
        #expect(notification.text == .body("Is 13.1 out yet?"))
        #expect(notification.identifier == "message-40")
        #expect(notification.thread == "chat-7")
        #expect(notification.chatID == 7)
        #expect(notification.messageID == 40)
        #expect(notification.position == at(0, 40))
        #expect(notification.accountID == 1)
        #expect(notification.sender == nil)
        #expect(notification.interruption == .active)
        #expect(notification.sound)
    }

    @Test func roomMessageNamesTheSender() throws {
        let notification = try #require(
            posted(
                Policy.decide(
                    message(nick: "Alice"), in: chat(kind: .room, notify: .all),
                    context: context(contact: false))))
        #expect(notification.sender == "Alice")
        #expect(notification.thread == "chat-7")
    }

    @Test func fileAndLocationSayWhatTheyAre() throws {
        let file = try #require(
            posted(
                Policy.decide(
                    message(body: "https://example.com/a.png", kind: .file), in: chat(),
                    context: context())))
        #expect(file.text == .file)
        let location = try #require(
            posted(
                Policy.decide(
                    message(body: "geo:52.5,13.4", kind: .location), in: chat(),
                    context: context())))
        #expect(location.text == .location)
    }

    // MARK: Never posted

    @Test func ownMessagesAreNotPosted() {
        #expect(
            Policy.decide(message(direction: .outgoing), in: chat(), context: context())
                == .suppress(.notIncoming))
    }

    /// Calls are announced through the call alert only, never as a message.
    @Test func callEntriesAreNotPosted() {
        #expect(
            Policy.decide(
                message(body: "Missed call", kind: .callLog), in: chat(), context: context())
                == .suppress(.call))
    }

    @Test func eventsAndRetractionsAreNotPosted() {
        #expect(
            Policy.decide(
                message(body: "Alice joined", kind: .system), in: chat(), context: context())
                == .suppress(.notContent))
        #expect(
            Policy.decide(message(retracted: true), in: chat(), context: context())
                == .suppress(.notContent))
        #expect(
            Policy.decide(message(chatID: 8), in: chat(), context: context())
                == .suppress(.notContent))
    }

    @Test func encryptedMessageThisDeviceCannotReadSaysNewMessage() throws {
        let notification = try #require(
            posted(
                Policy.decide(
                    message(
                        body: "Not encrypted for this device", kind: .system, encryption: .omemo),
                    in: chat(encryption: .omemo), context: context(previews: .always))))
        #expect(notification.text == .hidden)
    }

    /// Read means at or before the read marker in the chat's order (timestamp, then row id),
    /// as the store counts unread messages.
    @Test func messageReadMeanwhileIsNotPosted() {
        #expect(
            Policy.decide(
                message(id: 40), in: chat(lastRead: 40), context: context(marker: at(0, 40)))
                == .suppress(.alreadyRead))
        #expect(
            Policy.decide(
                message(id: 40), in: chat(lastRead: 41), context: context(marker: at(1, 41)))
                == .suppress(.alreadyRead))
        #expect(
            posted(
                Policy.decide(
                    message(id: 40), in: chat(lastRead: 39), context: context(marker: at(-1, 39))))
                != nil)
    }

    /// A message stored after older ones the archive filled in has a lower id than they do: a
    /// marker on one of them, older in time, does not make it read.
    @Test func newerMessageWithALowerIdIsNotRead() {
        #expect(
            posted(
                Policy.decide(
                    message(id: 200, at: Self.base), in: chat(lastRead: 240),
                    context: context(marker: at(-10, 240)))) != nil)
    }

    /// A message whose stamp puts it before the marker is read, whatever its id.
    @Test func delayedMessageBeforeTheMarkerIsRead() {
        #expect(
            Policy.decide(
                message(id: 260, at: Self.base.addingTimeInterval(-20 * 60)),
                in: chat(lastRead: 240), context: context(marker: at(-10, 240)))
                == .suppress(.alreadyRead))
    }

    /// A marker that is not the chat's (read before the chat moved on) counts for nothing.
    @Test func staleMarkerCountsForNothing() {
        #expect(
            posted(
                Policy.decide(
                    message(id: 40), in: chat(lastRead: 39), context: context(marker: at(5, 50))))
                != nil)
    }

    @Test func mutedChatIsNotPosted() {
        #expect(
            Policy.decide(
                message(mentionsMe: true), in: chat(kind: .room, muted: true), context: context())
                == .suppress(.muted))
    }

    @Test func notifyNothingIsNotPosted() {
        #expect(
            Policy.decide(message(), in: chat(notify: .none), context: context())
                == .suppress(.notifyNone))
    }

    @Test func openChatInFrontIsNotPosted() {
        #expect(
            Policy.decide(message(), in: chat(id: 7), context: context(open: 7))
                == .suppress(.chatOpen))
        #expect(posted(Policy.decide(message(), in: chat(id: 7), context: context(open: 9))) != nil)
    }

    // MARK: Unknown senders

    @Test func unknownSenderNeedsTheSetting() {
        #expect(
            Policy.decide(message(), in: chat(), context: context(contact: false))
                == .suppress(.unknownSender))
        #expect(
            posted(
                Policy.decide(
                    message(), in: chat(), context: context(contact: false, unknownSenders: true)))
                != nil)
    }

    /// R84: a private message through a room from an occupant who is not a contact is from an
    /// unknown sender: it needs the setting, like a direct chat with a stranger.
    @Test func privateMessagesFromOccupantsWhoAreNotContactsNeedTheSetting() {
        let chat = chat(kind: .roomPrivate)
        #expect(
            Policy.decide(message(nick: "Carol"), in: chat, context: context(contact: false))
                == .suppress(.unknownSender))
        #expect(
            posted(
                Policy.decide(
                    message(nick: "Carol"), in: chat,
                    context: context(contact: false, unknownSenders: true))) != nil)
        #expect(
            posted(Policy.decide(message(nick: "Carol"), in: chat, context: context(contact: true)))
                != nil)
    }

    /// Whose roster item makes the sender a contact (R84): the peer of a direct chat, the
    /// occupant's real address for a private message through a room, nobody for a room.
    @Test func theSenderToLookUpInTheRoster() {
        #expect(Policy.senderCheck(for: message(), in: chat()) == .roster("bob@example.com"))
        #expect(
            Policy.senderCheck(for: message(nick: "Carol"), in: chat(kind: .room)) == .notNeeded)
        #expect(
            Policy.senderCheck(for: message(nick: "Carol"), in: chat(kind: .channel))
                == .notNeeded)
        var known = message(nick: "Carol")
        known.senderRealJID = "carol@example.net/laptop"
        #expect(
            Policy.senderCheck(for: known, in: chat(kind: .roomPrivate))
                == .roster("carol@example.net"))
        #expect(
            Policy.senderCheck(for: message(nick: "Carol"), in: chat(kind: .roomPrivate))
                == .unknown)
    }

    @Test func roomOccupantsAreNotUnknownSenders() {
        #expect(
            posted(
                Policy.decide(
                    message(nick: "Carol"), in: chat(kind: .room, notify: .all),
                    context: context(contact: false))) != nil)
    }

    // MARK: Mentions and keywords

    @Test func mentionsLevelSkipsOrdinaryRoomMessages() {
        #expect(
            Policy.decide(
                message(nick: "Carol"), in: chat(kind: .room, notify: .mentions),
                context: context(keywords: ["prosody"]))
                == .suppress(.notMentioned))
    }

    @Test func mentionOfTheNickIsPosted() throws {
        let notification = try #require(
            posted(
                Policy.decide(
                    message(body: "alice: look", nick: "Carol", mentionsMe: true),
                    in: chat(kind: .room, notify: .mentions), context: context())))
        #expect(notification.mentionsMe)
    }

    @Test func keywordIsAMention() throws {
        let notification = try #require(
            posted(
                Policy.decide(
                    message(body: "New Prosody release", nick: "Carol"),
                    in: chat(kind: .channel, notify: .mentions),
                    context: context(keywords: ["prosody"]))))
        #expect(notification.mentionsMe)
        // Whole words only.
        #expect(
            Policy.decide(
                message(body: "prosodyctl is fine", nick: "Carol"),
                in: chat(kind: .room, notify: .mentions), context: context(keywords: ["prosody"]))
                == .suppress(.notMentioned))
    }

    @Test func allLevelPostsEveryRoomMessage() throws {
        let notification = try #require(
            posted(
                Policy.decide(
                    message(nick: "Carol"), in: chat(kind: .room, notify: .all), context: context())
            ))
        #expect(!notification.mentionsMe)
    }

    // MARK: Encrypted text

    @Test func encryptedTextOnlyWhenPreviewsAreAllowed() throws {
        let encrypted = message(encryption: .omemo)
        let omemo = chat(encryption: .omemo)
        for previews in [Policy.Previews.always, .whenUnlocked] {
            let shown = try #require(
                posted(Policy.decide(encrypted, in: omemo, context: context(previews: previews))))
            #expect(shown.text == .body("Is 13.1 out yet?"))
        }
        let hidden = try #require(
            posted(Policy.decide(encrypted, in: omemo, context: context(previews: .never))))
        #expect(hidden.text == .hidden)
        let file = try #require(
            posted(
                Policy.decide(
                    message(kind: .file, encryption: .omemo), in: omemo,
                    context: context(previews: .never))))
        #expect(file.text == .hidden)
    }

    /// R58: the app's "Message text" and the system's "Show previews", the stricter wins.
    /// Hidden text is "New message"; names (the chat's and the sender's) go too only when the
    /// system shows no previews at all.
    @Test func messageTextAndPreviewsTheStricterWins() throws {
        typealias Row = (
            app: Policy.MessageText, system: Policy.Previews, encrypted: Bool, hidden: Bool,
            names: Bool
        )
        let table: [Row] = [
            (.show, .always, false, false, true),
            (.show, .always, true, false, true),
            (.show, .whenUnlocked, false, false, true),
            (.show, .whenUnlocked, true, false, true),
            (.show, .never, false, true, false),
            (.show, .never, true, true, false),
            (.hideInEncryptedChats, .always, false, false, true),
            (.hideInEncryptedChats, .always, true, true, true),
            (.hideInEncryptedChats, .whenUnlocked, false, false, true),
            (.hideInEncryptedChats, .whenUnlocked, true, true, true),
            (.hideInEncryptedChats, .never, false, true, false),
            (.hideInEncryptedChats, .never, true, true, false),
            (.hide, .always, false, true, true),
            (.hide, .always, true, true, true),
            (.hide, .whenUnlocked, false, true, true),
            (.hide, .whenUnlocked, true, true, true),
            (.hide, .never, false, true, false),
            (.hide, .never, true, true, false),
        ]
        #expect(table.count == Policy.MessageText.allCases.count * 3 * 2)
        for row in table {
            let encryption: EncryptionMode = row.encrypted ? .omemo : .none
            let notification = try #require(
                posted(
                    Policy.decide(
                        message(nick: "Carol", encryption: encryption),
                        in: chat(kind: .room, encryption: encryption),
                        context: context(previews: row.system, messageText: row.app))))
            let label = "\(row.app) \(row.system) encrypted=\(row.encrypted)"
            #expect(
                notification.text == (row.hidden ? .hidden : .body("Is 13.1 out yet?")),
                "\(label)")
            #expect(notification.showsNames == row.names, "\(label)")
            #expect(notification.sender == (row.names ? "Carol" : nil), "\(label)")
        }
    }

    @Test func defaultMessageTextHidesEncryptedChatsOnly() {
        #expect(Policy.MessageText.default == .hideInEncryptedChats)
    }

    /// "Hide in encrypted chats" is about the chat: a plain message that reaches an OMEMO chat
    /// (a peer without OMEMO, a server notice) is hidden too, and so is an encrypted one in a
    /// chat switched to plain since.
    @Test func hideInEncryptedChatsFollowsTheChat() throws {
        typealias Row = (chat: EncryptionMode, message: EncryptionMode, hidden: Bool)
        let table: [Row] = [
            (.omemo, .none, true),
            (.omemo, .omemo, true),
            (.none, .omemo, true),
            (.none, .none, false),
        ]
        for row in table {
            for kind in [ChatKind.direct, .room] {
                let notification = try #require(
                    posted(
                        Policy.decide(
                            message(nick: kind == .room ? "Carol" : nil, encryption: row.message),
                            in: chat(kind: kind, encryption: row.chat),
                            context: context(previews: .always, messageText: .hideInEncryptedChats)
                        )))
                #expect(
                    notification.text == (row.hidden ? .hidden : .body("Is 13.1 out yet?")),
                    "chat=\(row.chat) message=\(row.message) \(kind)")
            }
        }
    }

    // MARK: Interruption

    @Test func doNotDisturbIsQuiet() throws {
        let notification = try #require(
            posted(Policy.decide(message(), in: chat(), context: context(doNotDisturb: true))))
        #expect(notification.interruption == .passive)
        #expect(!notification.sound)
    }

    // MARK: Withdrawing

    private func delivered(
        _ messageID: Int64, chatID: Int64 = 7, minutes: Double = 0, seen: Bool = false
    ) -> Policy.Delivered {
        Policy.Delivered(
            identifier: "message-\(messageID)", chatID: chatID, position: at(minutes, messageID),
            chatSeen: seen)
    }

    @Test func readChatsTakeTheirNotificationsBack() {
        let result = Policy.reconcile(
            [delivered(40), delivered(41, minutes: 1), delivered(50, chatID: 9)],
            chats: [chat(id: 7, lastRead: 40), chat(id: 9, lastRead: nil)],
            markers: [7: at(0, 40)])
        #expect(result.withdrawn == ["message-40"])
        #expect(result.kept.map(\.identifier) == ["message-41", "message-50"])
        #expect(result.kept.map(\.chatSeen) == [true, true])
    }

    /// After a wake: a live message L (row 200) is posted, the archive fills in older rows
    /// 201-250, and MDS moves the marker to row 240, older than L. L stays unread, and so
    /// does its notification.
    @Test func markerOnOlderArchiveRowsKeepsTheLiveNotification() {
        let live = delivered(200, minutes: 0)
        let result = Policy.reconcile(
            [live], chats: [chat(id: 7, lastRead: 240)], markers: [7: at(-10, 240)])
        #expect(result.withdrawn.isEmpty)
        #expect(result.kept.map(\.identifier) == ["message-200"])
    }

    /// A delayed message placed before the marker is read, though its id is higher.
    @Test func delayedNotificationBeforeTheMarkerIsTakenBack() {
        let result = Policy.reconcile(
            [delivered(260, minutes: -20)], chats: [chat(id: 7, lastRead: 240)],
            markers: [7: at(-10, 240)])
        #expect(result.withdrawn == ["message-260"])
    }

    /// Without the marker's place (not read yet, or not the chat's marker), nothing is taken
    /// back: an unread notification is never withdrawn by a guess.
    @Test func unknownMarkerTakesNothingBack() {
        let missing = Policy.reconcile(
            [delivered(40)], chats: [chat(id: 7, lastRead: 40)], markers: [:])
        #expect(missing.withdrawn.isEmpty)
        let stale = Policy.reconcile(
            [delivered(40)], chats: [chat(id: 7, lastRead: 40)], markers: [7: at(0, 39)])
        #expect(stale.withdrawn.isEmpty)
    }

    /// A chat list from before the chat existed must not take its notification back; once the
    /// chat was listed, its absence means it was deleted.
    @Test func deletedChatTakesItsNotificationsBackOnceSeen() {
        let early = Policy.reconcile([delivered(40)], chats: [], markers: [:])
        #expect(early.withdrawn.isEmpty)
        #expect(early.kept == [delivered(40)])
        let listed = Policy.reconcile(early.kept, chats: [chat(id: 7)], markers: [:])
        #expect(listed.withdrawn.isEmpty)
        let gone = Policy.reconcile(listed.kept, chats: [], markers: [:])
        #expect(gone.withdrawn == ["message-40"])
        #expect(gone.kept.isEmpty)
    }

    // MARK: After a relaunch

    /// A store that cannot be read follows nothing and takes back nothing but calls: an
    /// unread notification is never taken back for a read error.
    @Test func unreadableStoreTakesBackOnlyCalls() {
        let restored = Policy.restore(
            [
                Policy.Leftover(identifier: "call-abc", chatID: nil, messageID: nil),
                Policy.Leftover(identifier: "message-41", chatID: 7, messageID: 41),
            ],
            positions: nil)
        #expect(restored.withdrawn == ["call-abc"])
        #expect(restored.delivered.isEmpty)
    }

    /// What an earlier run left in Notification Center is followed again: a message's
    /// notification becomes delivered again, and the first chat list takes it back when the
    /// chat was read meanwhile.
    @Test func leftoverNotificationIsTakenBackWhenRead() {
        let restored = Policy.restore(
            [Policy.Leftover(identifier: "message-40", chatID: 7, messageID: 40)],
            positions: [40: at(0, 40)])
        #expect(restored.withdrawn.isEmpty)
        #expect(restored.delivered == [delivered(40)])
        let result = Policy.reconcile(
            restored.delivered, chats: [chat(id: 7, lastRead: 40)], markers: [7: at(0, 40)])
        #expect(result.withdrawn == ["message-40"])
    }

    /// No call rings across a relaunch; a message that is gone takes its notification along.
    /// Anything else is not ours to judge and stays.
    @Test func leftoverCallsAndVanishedMessagesGo() {
        let restored = Policy.restore(
            [
                Policy.Leftover(identifier: "call-abc", chatID: nil, messageID: nil),
                Policy.Leftover(identifier: "message-41", chatID: 7, messageID: 41),
                Policy.Leftover(identifier: "message-42", chatID: 7, messageID: 42),
                Policy.Leftover(identifier: "other", chatID: nil, messageID: nil),
            ],
            positions: [42: at(1, 42)])
        #expect(restored.withdrawn == ["call-abc", "message-41"])
        #expect(restored.delivered == [delivered(42, minutes: 1)])
    }
}
