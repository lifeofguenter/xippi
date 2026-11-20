import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// What the account's server keeps in its message archive (XEP-0441): every message, those
/// with contacts, or none, with addresses that are always or never kept. Read from the server
/// while online; each change is saved at once.
struct ArchiveSettings: View {
    let model: AppModel
    let account: AccountRecord
    @State private var preferences: MAMPreferences?
    @State private var unavailable = false
    @State private var busy = false
    @State private var error: String?
    @State private var alwaysAddress = ""
    @State private var neverAddress = ""

    var body: some View {
        let online = model.status(of: account) == .online
        Form {
            if !online {
                Section {
                    Text(Copy.notConnected)
                        .foregroundStyle(.secondary)
                }
            } else if unavailable {
                Section {
                    Text(Copy.archiveUnavailable)
                        .foregroundStyle(.secondary)
                }
            } else if let preferences {
                Section {
                    Picker(
                        Copy.archiveMessages,
                        selection: Binding(
                            get: { preferences.default },
                            set: { value in
                                var changed = preferences
                                changed.default = value
                                save(changed)
                            })
                    ) {
                        Text(Copy.archiveAlways).tag(MAMPreferences.Default.always)
                        Text(Copy.archiveRoster).tag(MAMPreferences.Default.roster)
                        Text(Copy.archiveNever).tag(MAMPreferences.Default.never)
                    }
                    .pointerStyle(.link)
                    .accessibilityIdentifier("archive-default")
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("archive-error")
                    }
                }
                list(Copy.alwaysArchive, preferences.always, address: $alwaysAddress, id: "always")
                {
                    $0.always = $1
                }
                list(Copy.neverArchive, preferences.never, address: $neverAddress, id: "never") {
                    $0.never = $1
                }
            } else if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("archive-error")
                }
            } else {
                Section {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .font(.appBody)
        .disabled(busy)
        .accessibilityIdentifier("archive-settings")
        .task(id: online) {
            guard online else { return }
            await load()
        }
    }

    /// An always or never list, with adding and removing addresses.
    private func list(
        _ title: String, _ jids: [JID], address: Binding<String>, id: String,
        set: @escaping (inout MAMPreferences, [JID]) -> Void
    ) -> some View {
        Section(title) {
            if jids.isEmpty {
                Text(Copy.noAddresses)
                    .foregroundStyle(.secondary)
            }
            ForEach(jids, id: \.self) { jid in
                LabeledContent {
                    Button(Copy.remove) {
                        guard var changed = preferences else { return }
                        set(&changed, jids.filter { $0 != jid })
                        save(changed)
                    }
                    .pointerStyle(.link)
                    .accessibilityIdentifier("archive-\(id)-remove:\(jid.description)")
                } label: {
                    Text(jid.description)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack {
                TextField(Copy.addressToAdd, text: address, prompt: Text(Copy.addressPrompt))
                    .labelsHidden()
                    .onSubmit { add(address, to: jids, set: set) }
                    .accessibilityIdentifier("archive-\(id)-address")
                Button(Copy.add) { add(address, to: jids, set: set) }
                    .disabled(address.wrappedValue.allSatisfy(\.isWhitespace))
                    .pointerStyle(.link)
                    .accessibilityIdentifier("archive-\(id)-add")
            }
        }
    }

    private func add(
        _ address: Binding<String>, to jids: [JID],
        set: (inout MAMPreferences, [JID]) -> Void
    ) {
        let text = address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jid = try? JID(text) else {
            error = Copy.invalidAccountAddress
            return
        }
        guard var changed = preferences else { return }
        if !jids.contains(jid) { set(&changed, jids + [jid]) }
        address.wrappedValue = ""
        save(changed)
    }

    private func load() async {
        guard let id = account.id, let session = await model.session(of: id) else { return }
        do throws(SessionError) {
            preferences = try await session.archivePreferences()
            unavailable = false
            error = nil
        } catch .unavailable {
            unavailable = true
        } catch {
            self.error = Copy.notLoaded(error)
        }
    }

    private func save(_ changed: MAMPreferences) {
        guard let id = account.id, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            guard let session = await model.session(of: id) else {
                error = Copy.notSaved(.notConnected)
                return
            }
            do throws(SessionError) {
                preferences = try await session.setArchivePreferences(changed)
            } catch {
                self.error = Copy.notSaved(error)
            }
        }
    }
}
