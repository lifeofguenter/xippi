import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Every chat of every account: pinned first, then by last activity, with filters and search.
struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(ChatSheets.self) private var sheets

    var body: some View {
        let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        Group {
            if searching {
                SearchResultsView(model: model, query: model.searchText, chatID: nil)
            } else {
                ChatList(model: model)
            }
        }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                SidebarSearchField(model: model)
                if !searching {
                    SidebarFilterBar(filter: $model.sidebarFilter)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .safeAreaBar(edge: .bottom) {
            AccountStatusFooter(model: model)
        }
        .toolbar {
            ToolbarItem {
                NewChatMenu(sheets: sheets)
            }
        }
    }
}

/// The chat list. The open chat stays listed under every filter, so opening an unread chat
/// with the Unread filter on does not make it vanish. Requests sit above the chats; the chats
/// are an AppKit table (R73).
private struct ChatList: View {
    @Bindable var model: AppModel
    @Environment(ChatSheets.self) private var sheets
    /// Room invitations of every account, followed while the list shows.
    @State private var invitations = RoomInvitationsModel()

    var body: some View {
        let filter = model.sidebarFilter
        let selection = model.selection
        let items = model.chats.filter { filter.includes($0) || $0.id == selection }
        let rows = Self.rows(items, model: model, selection: selection)
        VStack(spacing: 0) {
            RequestsPanel(model: model, invitations: invitations)
            GeometryReader { proxy in
                SidebarTable(
                    model: model, sheets: sheets, rows: rows, selection: selection,
                    topInset: proxy.safeAreaInsets.top, bottomInset: proxy.safeAreaInsets.bottom
                )
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
        }
        .task(id: SessionsKey(model)) { await invitations.follow(model) }
        .overlay {
            if items.isEmpty && model.chatsLoaded {
                ContentUnavailableView {
                    Label(filter.emptyTitle, systemImage: "bubble.left.and.bubble.right")
                        .font(.appTitle)
                }
            }
        }
    }

    /// "Pinned" and its chats, then "Chats" and the rest; a room that is not joined says so.
    static func rows(_ items: [ChatListItem], model: AppModel, selection: Int64?) -> [SidebarRow] {
        let pinned = items.filter(\.chat.pinned)
        let others = items.filter { !$0.chat.pinned }
        var rows: [SidebarRow] = []
        for (title, section) in [(Copy.pinned, pinned), (Copy.chats, others)]
        where !section.isEmpty {
            rows.append(.header(title))
            for item in section {
                rows.append(
                    .chat(
                        item, stateLabel: model.roomLabel(for: item),
                        showsDraft: item.id != selection))
            }
        }
        return rows
    }
}

/// All, Unread, People, Groups: one row of text buttons, one height, at the app's text size.
private struct SidebarFilterBar: View {
    @Binding var filter: SidebarFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarFilter.allCases) { option in
                let selected = option == filter
                Button {
                    filter = option
                } label: {
                    Text(option.title)
                        .font(.appBody)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: ControlHeight.Sidebar.filter)
                        .background(
                            selected ? Color.accentColor.opacity(0.18) : .clear, in: .capsule
                        )
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("filter-\(option.rawValue)")
            }
        }
        .padding(2)
        .background(.quaternary, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.filter)
        .accessibilityIdentifier("sidebar-filter")
    }
}

/// Searches chats and messages of every account. ⇧⌘F focuses it, also when it comes in with
/// a sidebar that was collapsed; Escape clears it.
private struct SidebarSearchField: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    /// Counts ⇧⌘F, each of which focuses the field.
    @State private var focusRequest = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(Copy.search, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.appBody)
                .focused($focused)
                .onExitCommand {
                    model.searchText = ""
                    focused = false
                }
                .accessibilityIdentifier("sidebar-search")
            if !model.searchText.isEmpty {
                Button(Copy.clearSearch, systemImage: "xmark.circle.fill") {
                    model.searchText = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .pointerStyle(.link)
                .help(Copy.clearSearch)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ControlHeight.Sidebar.search)
        .background(.quaternary, in: .capsule)
        .onChange(of: model.searchPresented, initial: true) { _, requested in
            guard requested else { return }
            model.searchPresented = false
            focusRequest += 1
        }
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            // A collapsed sidebar slides in first, and the window hands the focus around while
            // it does: the field asks for it until the sidebar has settled.
            for _ in 0..<6 {
                focused = true
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
