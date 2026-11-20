import SwiftUI
import XippiStore

/// Chats and messages matching a query. With `chatID`, only that chat's messages. Choosing a
/// result opens the chat at the message.
struct SearchResultsView: View {
    let model: AppModel
    let query: String
    let chatID: Int64?

    @State private var hits: [SearchHit] = []
    @State private var searchedQuery: String?
    @State private var selected: SearchResult?

    var body: some View {
        let chats =
            chatID == nil ? QuickSwitcherRanking.rank(model.chats, query: query, limit: 5) : []
        let names = Dictionary(model.chats.map { ($0.id, $0.displayName) }) { first, _ in first }
        List(selection: $selected) {
            if !chats.isEmpty {
                Section {
                    ForEach(chats) { item in
                        QuickSwitcherRow(item: item)
                            .pointerStyle(.link)
                            .tag(SearchResult.chat(item.id))
                    }
                } header: {
                    SectionTitle(Copy.chats)
                }
            }
            if !hits.isEmpty {
                Section {
                    ForEach(hits) { hit in
                        SearchHitRow(
                            hit: hit,
                            chatName: names[hit.chatID] ?? ChatDisplay.localPart(of: hit.chatJID),
                            showsChat: chatID == nil
                        )
                        .pointerStyle(.link)
                        .tag(SearchResult.message(chatID: hit.chatID, messageID: hit.messageID))
                    }
                } header: {
                    SectionTitle(Copy.messages)
                }
            }
        }
        .accessibilityIdentifier("search-results")
        .overlay {
            if searchedQuery == query, hits.isEmpty, chats.isEmpty {
                ContentUnavailableView {
                    Label(Copy.noResults, systemImage: "magnifyingglass")
                        .font(.appTitle)
                }
            }
        }
        .onChange(of: selected) { _, result in
            switch result {
            case .chat(let id): model.open(chatID: id)
            case .message(let chatID, let messageID):
                model.open(chatID: chatID, revealing: messageID)
            case nil: break
            }
        }
        .task(id: SearchRequest(query: query, chatID: chatID)) {
            // Waits for typing to pause before searching.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await Self.search(query, chatID: chatID, in: model.database)
            guard !Task.isCancelled else { return }
            hits = found
            searchedQuery = query
        }
    }

    @concurrent private static func search(
        _ query: String, chatID: Int64?, in database: AppDatabase
    ) async -> [SearchHit] {
        (try? database.search(query, chatID: chatID, limit: 200)) ?? []
    }
}

private struct SearchRequest: Hashable {
    var query: String
    var chatID: Int64?
}

private enum SearchResult: Hashable {
    case chat(Int64)
    case message(chatID: Int64, messageID: Int64)
}

/// One matching message: who, where, when, and the text.
private struct SearchHitRow: View {
    let hit: SearchHit
    let chatName: String
    let showsChat: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sender)
                    .font(.appEmphasized)
                    .lineLimit(1)
                if showsChat, sender != chatName {
                    Text(chatName)
                        .font(.appBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(RelativeDay.short(hit.timestamp))
                    .font(.appBody)
                    .foregroundStyle(.secondary)
            }
            Text(MessageStyling.attributed(ChatDisplay.singleLine(hit.body), base: .appBody))
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sender: String {
        if hit.direction == .outgoing { return Copy.you }
        // Room messages carry the occupant's nick; in direct chats the sender is the chat.
        if let nick = hit.senderNick, !nick.isEmpty { return nick }
        return chatName
    }
}
