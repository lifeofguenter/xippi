import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// The account's blocklist on the server (XEP-0191): nothing from these addresses reaches any
/// of the account's devices. It follows the server's pushes, so a change made on another
/// device shows here at once.
struct BlocklistView: View {
    let model: AppModel
    let account: AccountRecord
    @State private var address = ""
    @State private var supported: Bool?
    @State private var busy = false
    @State private var error: String?
    /// Everyone ignored in rooms and channels on this Mac (R72): by real JID, occupant id,
    /// participant id or nickname. A real JID may also be on the server's list above.
    @State private var ignored: [IgnoredParticipant] = []

    var body: some View {
        let online = model.status(of: account) == .online
        let blocked = account.id.flatMap { model.status.blocklists[$0] }
        Form {
            Section {
                HStack {
                    TextField(
                        Copy.blockAddressPrompt, text: $address,
                        prompt: Text(Copy.addressPrompt)
                    )
                    .labelsHidden()
                    .onSubmit(block)
                    .accessibilityIdentifier("block-address")
                    Button(Copy.block, action: block)
                        .disabled(!online || busy || supported == false || trimmed.isEmpty)
                        .pointerStyle(.link)
                        .accessibilityIdentifier("block-confirm")
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("blocklist-error")
                }
                if !online {
                    Text(Copy.notConnected)
                        .foregroundStyle(.secondary)
                } else if supported == false {
                    Text(Copy.blockingUnavailable)
                        .foregroundStyle(.secondary)
                }
            }
            Section(Copy.paneBlocked) {
                if let blocked, !blocked.isEmpty {
                    ForEach(blocked.sorted(), id: \.self) { jid in
                        LabeledContent {
                            Button(Copy.unblock) { unblock(jid) }
                                .disabled(!online || busy)
                                .pointerStyle(.link)
                                .accessibilityIdentifier("unblock:\(jid)")
                        } label: {
                            Text(jid)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                } else if blocked != nil {
                    Text(Copy.noBlockedAddresses)
                        .foregroundStyle(.secondary)
                } else if online, supported != false {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !ignored.isEmpty {
                Section {
                    ForEach(ignored, id: \.id) { entry in
                        LabeledContent {
                            Button(Copy.unignore) { unignore(entry) }
                                .pointerStyle(.link)
                                .accessibilityIdentifier(
                                    "unignore:\(entry.room ?? ""):\(entry.value)")
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Copy.ignoredName(entry))
                                    .lineLimit(1)
                                Text(Copy.ignoredWhere(entry))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } header: {
                    Text(Copy.ignoredInRooms)
                } footer: {
                    Text(Copy.onThisMacOnly)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .accessibilityIdentifier("blocklist")
        .task(id: account.id) {
            guard let id = account.id else { return }
            for await list in model.database.ignoreListUpdates(accountID: id) {
                ignored = list.entries
            }
        }
        .task(id: online) {
            guard online, let id = account.id else { return }
            supported = await model.session(of: id)?.supportsBlocking
        }
    }

    /// Ignoring is kept on this Mac only: taking it back needs no connection. A real JID
    /// stays on the server's list until it is unblocked there.
    private func unignore(_ entry: IgnoredParticipant) {
        let database = model.database
        Task {
            if !(await Self.unignore(entry, in: database)) { error = Copy.notUnignored }
        }
    }

    /// Off the main thread (I-1): the write re-checks the hidden messages.
    @concurrent private static func unignore(_ entry: IgnoredParticipant, in database: AppDatabase)
        async -> Bool
    {
        do {
            if entry.kind == .realJID {
                try database.unignore(accountID: entry.accountID, realJID: entry.value)
            } else if let room = entry.room {
                try database.unignore(
                    accountID: entry.accountID, room: room, kind: entry.kind, value: entry.value)
            }
            return true
        } catch {
            return false
        }
    }

    private var trimmed: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func block() {
        guard let jid = try? JID(trimmed) else {
            error = Copy.invalidAccountAddress
            return
        }
        change { session throws(SessionError) in
            try await session.block(jid)
            address = ""
        } failure: {
            Copy.notBlocked($0)
        }
    }

    private func unblock(_ text: String) {
        guard let jid = try? JID(text) else { return }
        change { session throws(SessionError) in
            try await session.unblock(jid)
        } failure: {
            Copy.notUnblocked($0)
        }
    }

    private func change(
        _ work: @escaping (AccountSession) async throws(SessionError) -> Void,
        failure: @escaping (SessionError) -> String
    ) {
        guard let id = account.id, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            guard let session = await model.session(of: id) else {
                error = failure(.notConnected)
                return
            }
            do throws(SessionError) {
                try await work(session)
            } catch {
                self.error = failure(error)
            }
        }
    }
}
