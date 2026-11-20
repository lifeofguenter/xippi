import SwiftUI
import XippiStore

/// ⌘K: a floating panel that finds a chat by a few letters of its name or address, or a
/// contact of an enabled account that has no chat yet, whose chat it then opens.
///
/// With 5,000 contacts a keystroke must not stall the window: names and addresses are folded
/// once, off the main actor, when the panel reads its lists, and the ranking runs only when
/// the query or a list changes, never when the highlight moves (about 1 ms for 5,050 entries
/// in a release build).
struct QuickSwitcher: View {
    @Bindable var model: AppModel

    @State private var query = ""
    @State private var highlighted = 0
    /// The chats, folded, as of the chat list's last change.
    @State private var chats: [SwitcherCandidate] = []
    /// Contacts without a chat, folded, read when the panel opens.
    @State private var contacts: [SwitcherCandidate] = []
    /// Both lists, chats first: what a keystroke ranks.
    @State private var candidates: [SwitcherCandidate] = []
    /// What the query matches, best first.
    @State private var matches: [SwitcherEntry] = []
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    TextField(Copy.goToChatPrompt, text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .accessibilityIdentifier("quick-switcher-field")
                        .onSubmit { open(matches) }
                        .onKeyPress(.downArrow) {
                            highlighted = min(highlighted + 1, max(matches.count - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                }
                .padding(.horizontal, 16)
                .frame(height: ControlHeight.Search.field)
                if !matches.isEmpty {
                    Divider()
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                open(entry)
                            } label: {
                                QuickSwitcherRow(entry: entry)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        index == highlighted
                                            ? Color.accentColor.opacity(0.22) : .clear,
                                        in: .rect(cornerRadius: 10)
                                    )
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .pointerStyle(.link)
                            .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: ControlHeight.Search.panelWidth)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.top, 72)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Copy.goToChat)
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { close() }
        .onAppear {
            fieldFocused = true
            rank()
        }
        .onChange(of: query) {
            highlighted = 0
            rank()
        }
        .task(id: model.chats) {
            let folded = await SwitcherCandidate.folded(model.chats.map(SwitcherEntry.chat))
            guard !Task.isCancelled else { return }
            chats = folded
            candidates = chats + contacts
            rank()
        }
        .task { await loadContacts() }
    }

    /// Ranks the lists for the query. Without one, the newest chats as they are, so the panel
    /// shows them before the lists are folded.
    private func rank() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            matches = Array(model.chats.prefix(Self.limit).map(SwitcherEntry.chat))
        } else {
            matches = QuickSwitcherRanking.rank(candidates, query: query, limit: Self.limit)
        }
        highlighted = min(highlighted, max(matches.count - 1, 0))
    }

    private static let limit = 8

    private func open(_ matches: [SwitcherEntry]) {
        guard matches.indices.contains(highlighted) else { return }
        open(matches[highlighted])
    }

    private func open(_ entry: SwitcherEntry) {
        close()
        switch entry {
        case .chat(let item):
            model.open(chatID: item.id)
        case .contact(let contact):
            Task { await model.startChat(accountID: contact.accountID, jid: contact.jid) }
        }
    }

    private func close() {
        model.quickSwitcherVisible = false
    }

    private func loadContacts() async {
        let accounts = model.accounts.filter(\.enabled).compactMap(\.id)
        let chatKeys = Set(
            model.chats.map { SwitcherContact.key($0.chat.accountID, $0.chat.jid) })
        let found = await SwitcherContact.withoutChat(
            accounts: accounts, chats: chatKeys, in: model.database)
        contacts = await SwitcherCandidate.folded(found.map(SwitcherEntry.contact))
        candidates = chats + contacts
        rank()
    }
}

/// A switcher entry with its name and address folded for matching, once, when its list is
/// read: a keystroke then only scores.
struct SwitcherCandidate: Sendable {
    var entry: SwitcherEntry
    var name: [Character]
    var address: [Character]

    init(_ entry: SwitcherEntry) {
        self.entry = entry
        name = FuzzyMatch.fold(entry.name)
        address = FuzzyMatch.fold(entry.address)
    }

    /// Folds a list off the main actor.
    @concurrent static func folded(_ entries: [SwitcherEntry]) async -> [SwitcherCandidate] {
        entries.map(SwitcherCandidate.init)
    }
}

/// A contact of an enabled account, by its roster entry.
struct SwitcherContact: Equatable, Sendable {
    var accountID: Int64
    var jid: String
    /// The roster name, or the address's local part.
    var name: String
    var avatarHash: String?

    static func key(_ accountID: Int64, _ jid: String) -> String {
        "\(accountID) \(jid)"
    }

    /// Every roster entry of the accounts whose address has no chat on that account.
    @concurrent static func withoutChat(
        accounts: [Int64], chats: Set<String>, in database: AppDatabase
    ) async -> [SwitcherContact] {
        var contacts: [SwitcherContact] = []
        for accountID in accounts {
            let items = (try? database.rosterItems(accountID: accountID)) ?? []
            for item in items where !chats.contains(key(accountID, item.jid)) {
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                contacts.append(
                    SwitcherContact(
                        accountID: accountID, jid: item.jid,
                        name: name.isEmpty ? ChatDisplay.localPart(of: item.jid) : name,
                        avatarHash: item.avatarHash))
            }
        }
        return contacts
    }
}

/// What the quick switcher lists: chats first, then contacts without one.
enum SwitcherEntry: Identifiable, Equatable, Sendable {
    case chat(ChatListItem)
    case contact(SwitcherContact)

    var id: String {
        switch self {
        case .chat(let item): "chat:\(item.id)"
        case .contact(let contact): "contact:\(SwitcherContact.key(contact.accountID, contact.jid))"
        }
    }

    var name: String {
        switch self {
        case .chat(let item): item.displayName
        case .contact(let contact): contact.name
        }
    }

    var address: String {
        switch self {
        case .chat(let item): item.chat.jid
        case .contact(let contact): contact.jid
        }
    }

    var isGroup: Bool {
        if case .chat(let item) = self { return item.isGroup }
        return false
    }

    var avatarHash: String? {
        switch self {
        case .chat(let item): item.chat.avatarHash
        case .contact(let contact): contact.avatarHash
        }
    }

    static func all(chats: [ChatListItem], contacts: [SwitcherContact]) -> [SwitcherEntry] {
        chats.map(SwitcherEntry.chat) + contacts.map(SwitcherEntry.contact)
    }
}

/// A chat or contact in the quick switcher, and a chat in search results.
struct QuickSwitcherRow: View {
    let name: String
    let address: String
    let isGroup: Bool
    let avatarHash: String?

    init(entry: SwitcherEntry) {
        name = entry.name
        address = entry.address
        isGroup = entry.isGroup
        avatarHash = entry.avatarHash
    }

    init(item: ChatListItem) {
        self.init(entry: .chat(item))
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                name: name, identifier: address, isGroup: isGroup, size: 28, hash: avatarHash)
            Text(name)
                .font(.appEmphasized)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(address)
                .font(.appBody)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: ControlHeight.Search.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(address)
        .accessibilityIdentifier("switch:\(name)")
    }
}

/// Orders chats and contacts by how well a query matches their name or address. Without a
/// query, the first ones as given (the chats, newest first).
enum QuickSwitcherRanking {
    static func rank(_ chats: [ChatListItem], query: String, limit: Int) -> [ChatListItem] {
        rank(chats, name: \.displayName, address: \.chat.jid, query: query, limit: limit)
    }

    static func rank(_ entries: [SwitcherEntry], query: String, limit: Int) -> [SwitcherEntry] {
        rank(entries, name: \.name, address: \.address, query: query, limit: limit)
    }

    /// Entries folded beforehand (`SwitcherCandidate`): a keystroke only scores.
    static func rank(_ candidates: [SwitcherCandidate], query: String, limit: Int)
        -> [SwitcherEntry]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates.prefix(limit).map(\.entry) }
        let folded = FuzzyMatch.fold(trimmed)
        var scored: [(index: Int, score: Int)] = []
        for index in candidates.indices {
            guard
                let score = best(
                    FuzzyMatch.score(folded, in: candidates[index].name),
                    FuzzyMatch.score(folded, in: candidates[index].address))
            else { continue }
            scored.append((index, score))
        }
        return top(scored, limit: limit).map { candidates[$0].entry }
    }

    static func rank<Item>(
        _ items: [Item], name: (Item) -> String, address: (Item) -> String, query: String,
        limit: Int
    ) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(items.prefix(limit)) }
        let folded = FuzzyMatch.fold(trimmed)
        var scored: [(index: Int, score: Int)] = []
        for (index, item) in items.enumerated() {
            guard
                let score = best(
                    FuzzyMatch.score(folded, in: FuzzyMatch.fold(name(item))),
                    FuzzyMatch.score(folded, in: FuzzyMatch.fold(address(item))))
            else { continue }
            scored.append((index, score))
        }
        return top(scored, limit: limit).map { items[$0] }
    }

    /// The better of a name's and an address's score; an address counts a little less.
    private static func best(_ byName: Int?, _ byAddress: Int?) -> Int? {
        switch (byName, byAddress.map { $0 - 2 }) {
        case (let name?, let address?): max(name, address)
        case (let name?, nil): name
        case (nil, let address?): address
        case (nil, nil): nil
        }
    }

    /// The indexes of the best scores, best first; equal scores keep the given order.
    private static func top(_ scored: [(index: Int, score: Int)], limit: Int) -> [Int] {
        scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit).map(\.index)
    }
}

/// Subsequence matching that favours word starts, runs of consecutive letters and prefixes.
enum FuzzyMatch {
    static func fold(_ text: String) -> [Character] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    /// Nil unless every character of `query` appears in `candidate` in order.
    static func score(_ query: [Character], in candidate: [Character]) -> Int? {
        guard !query.isEmpty else { return 0 }
        var score = 0
        var next = 0
        var previous = -2
        for (index, character) in candidate.enumerated() where next < query.count {
            guard character == query[next] else { continue }
            score += 1
            if index == previous + 1 { score += 4 }
            if index == 0 || !(candidate[index - 1].isLetter || candidate[index - 1].isNumber) {
                score += 6
            }
            previous = index
            next += 1
        }
        guard next == query.count else { return nil }
        if candidate.starts(with: query) { score += 20 }
        return score - candidate.count / 8
    }
}
