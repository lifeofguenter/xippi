import SwiftUI
import XippiSession
import XippiStore

/// Someone who gave a reaction, as the list of reactions shows them.
struct Reactor: Equatable {
    var name: String
    /// Whose colour the initials take: the same key the transcript colours them by.
    var colorKey: String
    /// Their picture, where one is known; initials otherwise.
    var avatarHash: String?
    var isSelf = false
}

/// One person's reaction with one emoji: a line of the list.
struct GivenReaction: Equatable {
    var emoji: String
    var reactor: Reactor
}

/// Who reacted with what, for the list a click on a message's reactions opens.
enum Reactors {
    /// A room's occupant ids: the nick each id goes by and the ids that are the account's
    /// own. Read off the room's members (who is there now, and which one is the account)
    /// and the loaded messages (who wrote under an id; our outgoing messages carry ours).
    struct Occupants: Equatable {
        var nicks: [String: String] = [:]
        var own: Set<String> = []
        /// Pictures by nick, as the room's presences give them.
        var avatars: [String: String] = [:]

        init(
            nicks: [String: String] = [:], own: Set<String> = [], avatars: [String: String] = [:]
        ) {
            self.nicks = nicks
            self.own = own
            self.avatars = avatars
        }

        init(
            messages: [MessageRecord], members: [RoomMember] = [], avatars: [String: String] = [:]
        ) {
            for message in messages {
                guard let id = message.occupantID else { continue }
                if message.direction == .outgoing {
                    own.insert(id)
                } else if let nick = message.senderNick {
                    nicks[id] = nick
                }
            }
            // Who is in the room now wins over what older messages said.
            for member in members {
                guard let id = member.occupantID else { continue }
                if member.isSelf {
                    own.insert(id)
                } else {
                    nicks[id] = member.nick
                }
            }
            self.avatars = avatars
        }
    }

    /// Whoever reacted under `key`. A direct or private chat has one other person: anyone but
    /// the account is them. A room keys reactions by occupant id where it has them, else by
    /// occupant JID (the room's address, a slash, the nick). An occupant id is opaque and may
    /// itself hold a slash, so a key is a nick only after the room's own address.
    static func person(
        of key: String, chat: TranscriptChat, occupants: Occupants, ownAvatarHash: String? = nil
    ) -> Reactor {
        let you = Reactor(
            name: Copy.you, colorKey: chat.accountJID, avatarHash: ownAvatarHash, isSelf: true)
        if key == chat.accountJID { return you }
        guard chat.isRoom else {
            return Reactor(name: chat.name, colorKey: key, avatarHash: chat.avatarHash)
        }
        if occupants.own.contains(key) { return you }
        if let nick = occupants.nicks[key] {
            return Reactor(name: nick, colorKey: key, avatarHash: occupants.avatars[nick])
        }
        if let nick = nick(in: key, room: chat.jid) {
            if nick == chat.ownNick { return you }
            return Reactor(name: nick, colorKey: nick, avatarHash: occupants.avatars[nick])
        }
        return Reactor(name: Copy.someone, colorKey: key)
    }

    /// The nick of an occupant JID of `room`; nil for anything else.
    static func nick(in key: String, room: String) -> String? {
        let prefix = room + "/"
        guard key.count > prefix.count,
            key.prefix(prefix.count).lowercased() == prefix.lowercased()
        else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    /// Every reaction, one line per person and emoji: yours first, then in the order the
    /// reactions came.
    static func given(
        _ reactions: [ReactionRecord], person: (String) -> Reactor
    ) -> [GivenReaction] {
        var yours: [GivenReaction] = []
        var others: [GivenReaction] = []
        for reaction in reactions {
            let who = person(reaction.reactorKey)
            for emoji in reaction.emojis {
                if who.isSelf {
                    yours.append(GivenReaction(emoji: emoji, reactor: who))
                } else {
                    others.append(GivenReaction(emoji: emoji, reactor: who))
                }
            }
        }
        return yours + others
    }
}

/// The list over a message's reactions: how many, a tab per emoji, and who gave each, with
/// their picture. Your own line takes your reaction back.
struct ReactionsList: View {
    let reactions: [GivenReaction]
    /// The emoji in the order the message shows them.
    let emojis: [String]
    /// The picture for a hash, from the window's avatar cache.
    let image: (String?) -> NSImage?
    /// Your reaction with this emoji, taken back; nil where reactions cannot be sent.
    let remove: ((String) -> Void)?
    /// The reaction picker, for another emoji; nil where reactions cannot be sent.
    let add: (() -> Void)?

    /// The emoji whose tab is chosen; nil for all.
    @State private var filter: String?

    /// Lines shown before the list scrolls.
    static let visibleLines = 7
    static let width: CGFloat = 300

    /// The lines under the chosen tab.
    static func shown(_ reactions: [GivenReaction], filter: String?) -> [GivenReaction] {
        guard let filter else { return reactions }
        return reactions.filter { $0.emoji == filter }
    }

    /// Whether a line takes its reaction back on a click: only your own, where reactions can
    /// be sent.
    static func takesBack(_ given: GivenReaction, canRemove: Bool) -> Bool {
        canRemove && given.reactor.isSelf
    }

    /// How many gave each emoji, in the order the message shows them.
    static func tabs(_ reactions: [GivenReaction], emojis: [String]) -> [(
        emoji: String, count: Int
    )] {
        emojis.compactMap { emoji in
            let count = reactions.count { $0.emoji == emoji }
            return count > 0 ? (emoji, count) : nil
        }
    }

    var body: some View {
        let lines = Self.shown(reactions, filter: filter)
        let line = ControlHeight.Transcript.reactorLine
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.reactionCount(reactions.count))
                .font(.appEmphasized)
            HStack(spacing: 6) {
                if let add {
                    Button(action: add) {
                        Image(systemName: "face.smiling")
                            .font(.appBody)
                            .frame(
                                width: ControlHeight.Transcript.reactionTab,
                                height: ControlHeight.Transcript.reactionTab
                            )
                            .background(.quaternary, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help(Copy.addReaction)
                    .accessibilityLabel(Copy.addReaction)
                }
                // Many emoji scroll sideways rather than squeeze.
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        tab(nil, label: Copy.reactionsAll(reactions.count))
                        ForEach(Self.tabs(reactions, emojis: emojis), id: \.emoji) { tab in
                            self.tab(tab.emoji, label: Copy.reactions(tab.emoji, tab.count))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, given in
                        row(given)
                            .frame(height: line)
                    }
                }
            }
            .scrollIndicators(.automatic)
            // As tall as all the lines, up to `visibleLines`: a tab with fewer keeps the size.
            .frame(height: line * CGFloat(min(reactions.count, Self.visibleLines)))
        }
        .padding(12)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reactions-list")
    }

    private func tab(_ emoji: String?, label: String) -> some View {
        let selected = filter == emoji
        return Button {
            filter = emoji
        } label: {
            Text(label)
                .font(.appBody)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: ControlHeight.Transcript.reactionTab)
                .background(
                    selected ? Color.accentColor.opacity(0.25) : Color.clear, in: .capsule
                )
                .overlay(Capsule().strokeBorder(.quaternary))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func row(_ given: GivenReaction) -> some View {
        let content = HStack(spacing: 10) {
            Image(nsImage: avatar(given.reactor))
                .frame(
                    width: ControlHeight.Transcript.reactorAvatar,
                    height: ControlHeight.Transcript.reactorAvatar)
            VStack(alignment: .leading, spacing: 0) {
                Text(given.reactor.name)
                    .font(.appBody)
                    .lineLimit(1)
                if Self.takesBack(given, canRemove: remove != nil) {
                    Text(Copy.clickToRemove)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(given.emoji)
                .font(.system(size: 20))
        }
        .contentShape(.rect)
        if Self.takesBack(given, canRemove: remove != nil), let remove {
            Button {
                remove(given.emoji)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel("\(given.reactor.name), \(given.emoji)")
            .accessibilityHint(Copy.clickToRemove)
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    /// Drawn as the transcript draws a sender's: the picture, else initials on their colour.
    private func avatar(_ reactor: Reactor) -> NSImage {
        let size = ControlHeight.Transcript.reactorAvatar
        let picture = image(reactor.avatarHash)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            // Your initials are your address's, not those of "You".
            ChatRowCell.drawAvatar(
                in: rect, image: picture, name: reactor.isSelf ? reactor.colorKey : reactor.name,
                identifier: reactor.colorKey, isGroup: false)
            return true
        }
    }
}
