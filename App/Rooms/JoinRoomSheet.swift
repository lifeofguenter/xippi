import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// Joins a room (⇧⌘N): its address, the nick, a password when it has one. "Find rooms" lists
/// the public rooms of the server's room service (XEP-0045 6.3); picking one fills the address.
struct JoinRoomSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var accounts: [AccountRecord]
    @State private var accountID: Int64?
    @State private var address = ""
    @State private var nick = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var search = RoomSearch()

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let (accounts, first) = AccountPicker.start(model)
        _accounts = State(initialValue: accounts)
        _accountID = State(initialValue: first)
        _nick = State(initialValue: Self.userName(accounts.first { $0.id == first }))
    }

    var body: some View {
        SheetForm(
            title: Copy.joinRoom, confirmTitle: Copy.join, canConfirm: room != nil && validNick,
            busy: busy, error: error, identifier: "join-room", onCancel: onClose, onConfirm: join
        ) {
            AccountPicker(accounts: accounts, accountID: $accountID)
            TextField(
                Copy.roomAddress, text: $address,
                prompt: Text(verbatim: "room@conference.example.org")
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("join-room-address")
            TextField(Copy.nickname, text: $nick)
                .autocorrectionDisabled()
                .accessibilityIdentifier("join-room-nick")
            SecureField(Copy.password, text: $password, prompt: Text(Copy.optional))
                .accessibilityIdentifier("join-room-password")
            RoomSearchView(search: search, onFind: find) { item in
                address = item.jid.bare.description
            }
        }
        .task(id: accountID) {
            search.reset()
        }
        .onChange(of: accountID) { _, id in
            nick = Self.userName(accounts.first { $0.id == id })
        }
    }

    private func find() {
        guard let accountID else { return }
        Task { await search.find(model: model, accountID: accountID) }
    }

    private var room: JID? {
        guard let jid = try? JID(address.trimmingCharacters(in: .whitespaces)),
            jid.localpart != nil
        else { return nil }
        return jid.bare
    }

    private var validNick: Bool {
        !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func join() {
        guard let room, let accountID, validNick else { return }
        busy = true
        error = nil
        let nick = nick
        let password = password.isEmpty ? nil : password
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.notJoined(Copy.notConnectedReason)
                return
            }
            do throws(SessionError) {
                let chatID = try await session.joinRoom(jid: room, nick: nick, password: password)
                onClose()
                model.open(chatID: chatID)
            } catch {
                self.error = Copy.notJoined(ChatCommandError.words(error))
            }
        }
    }

    static func userName(_ account: AccountRecord?) -> String {
        account?.jid.split(separator: "@").first.map(String.init) ?? ""
    }
}

/// The rooms a server's room service lists, filtered by what is typed.
@MainActor @Observable final class RoomSearch {
    enum Phase: Equatable {
        case idle, searching, found, noService
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var rooms: [DiscoItem] = []
    var filter = ""

    func reset() {
        phase = .idle
        rooms = []
        filter = ""
    }

    func find(model: AppModel, accountID: Int64) async {
        phase = .searching
        guard let session = await model.session(accountID: accountID) else {
            phase = .failed(Copy.notConnectedReason)
            return
        }
        guard let service = await session.roomServices().first else {
            phase = .noService
            return
        }
        do {
            rooms = try await session.publicRooms(on: service)
            phase = .found
        } catch {
            phase = .failed(ChatCommandError.words(error))
        }
    }

    /// Shown at most: the filter narrows the rest.
    static let shown = 50

    var matches: [DiscoItem] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let hits =
            query.isEmpty
            ? rooms
            : rooms.filter {
                ($0.name ?? "").localizedCaseInsensitiveContains(query)
                    || $0.jid.description.localizedCaseInsensitiveContains(query)
            }
        return Array(hits.prefix(Self.shown))
    }
}

/// "Find rooms", then a search field and the matching rooms.
struct RoomSearchView: View {
    let search: RoomSearch
    let onFind: () -> Void
    let onPick: (DiscoItem) -> Void

    var body: some View {
        @Bindable var search = search
        switch search.phase {
        case .idle:
            Button(Copy.findRooms, action: onFind)
                .pointerStyle(.link)
                .accessibilityIdentifier("join-room-find")
        case .searching:
            ProgressView()
                .controlSize(.small)
        case .noService:
            Text(Copy.noRoomService)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(Copy.failed(Copy.findRooms, reason))
                .foregroundStyle(.red)
        case .found:
            TextField(Copy.searchRooms, text: $search.filter)
                .accessibilityIdentifier("join-room-search")
            if search.matches.isEmpty {
                Text(Copy.noRoomsFound)
                    .foregroundStyle(.secondary)
            }
            ForEach(search.matches, id: \.jid) { item in
                Button {
                    onPick(item)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name ?? item.jid.localpart ?? item.jid.description)
                            .foregroundStyle(.primary)
                        Text(item.jid.description)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityIdentifier("found-room-\(item.jid.description)")
            }
        }
    }
}
