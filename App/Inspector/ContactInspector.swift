import SwiftUI
import XippiSession
import XippiStore
import os

/// A direct chat's details: presence and status, encryption and devices, shared media, and the
/// contact itself (name, roster, blocking, spam reports).
struct ContactInspector: View {
    let model: AppModel
    let info: OpenChatInfo
    let contact: ContactInspectorModel
    let sheets: ChatSheets
    let media: [SharedMediaItem]

    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var confirmReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: ControlHeight.Inspector.sectionSpacing) {
            presence
            InspectorSection(title: Copy.encryption, identifier: "inspector-encryption") {
                EncryptionToggle(model: model, chatID: info.id)
                EncryptionDevicesView(
                    name: info.name, identities: contact.identities,
                    ownIdentities: contact.ownIdentities, isVerified: contact.isVerified,
                    busy: contact.busy, fetchingKeys: contact.fetchingKeys,
                    onTrust: { trust, identity in contact.setTrust(trust, for: identity) },
                    onReset: { contact.resetSessions() }
                )
                .task(id: contact.chatID) { await contact.fetchKeys() }
                InspectorError(text: contact.trustError)
            }
            InspectorSection(title: Copy.notifications, identifier: "inspector-notifications") {
                ChatNotificationSettings(model: model, chatID: info.id)
            }
            InspectorSection(title: Copy.sharedMedia, identifier: "inspector-media") {
                SharedMediaView(items: media) { item in
                    model.open(chatID: info.id, revealing: item.messageID)
                }
            }
            if let profile = contact.profile {
                InspectorSection(title: Copy.profile, identifier: "inspector-profile") {
                    ContactProfileFields(profile: profile)
                }
            }
            InspectorSection(title: Copy.contact, identifier: "inspector-contact") {
                if let groups = contact.roster?.groups, !groups.isEmpty {
                    LabeledContent(Copy.groups, value: groups.joined(separator: ", "))
                        .font(.appBody)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("contact-groups")
                }
                actions
                InspectorError(text: contact.error)
            }
        }
        .task(id: info.id) { await contact.followRoster() }
        .task(id: info.id) { await contact.loadProfile() }
    }

    /// "Online: Back at 3", or "Offline", and what the subscription lets each side see.
    private var presence: some View {
        let summary = model.status.presence[PresenceKey(accountID: info.accountID, jid: info.jid)]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(summary == nil ? Color.secondary : Self.color(summary?.availability))
                    .frame(width: ControlHeight.Inspector.dot, height: ControlHeight.Inspector.dot)
                Text(summary.map { Copy.availability($0.availability) } ?? Copy.offline)
                    .font(.appBody)
            }
            if let status = summary?.status {
                Text(status)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let subscription = contact.roster.flatMap({ Copy.subscription($0.subscription) }) {
                Text(subscription)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
            }
            if contact.isBlocked {
                Label(Copy.blocked, systemImage: "hand.raised.fill")
                    .font(.appBody)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector-presence")
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if contact.roster != nil {
                InspectorButton(title: Copy.rename, identifier: "contact-rename") {
                    sheets.sheet = .renameContact(chatID: info.id)
                }
                InspectorButton(
                    title: Copy.removeContact, role: .destructive, identifier: "contact-remove"
                ) {
                    confirmRemove = true
                }
                .confirmationDialog(Copy.removeContactTitle(info.name), isPresented: $confirmRemove)
                {
                    Button(Copy.removeContact, role: .destructive) { contact.remove() }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                InspectorButton(title: Copy.addToContacts, identifier: "contact-add") {
                    contact.add()
                }
            }
            if contact.isBlocked {
                InspectorButton(title: Copy.unblockContact, identifier: "contact-unblock") {
                    contact.setBlocked(false)
                }
            } else {
                InspectorButton(
                    title: Copy.blockContact, role: .destructive, identifier: "contact-block"
                ) {
                    confirmBlock = true
                }
                .confirmationDialog(Copy.blockTitle(info.name), isPresented: $confirmBlock) {
                    Button(Copy.blockContact, role: .destructive) { contact.setBlocked(true) }
                    Button(Copy.cancel, role: .cancel) {}
                        .keyboardShortcut(.defaultAction)
                }
            }
            InspectorButton(
                title: Copy.reportSpam, role: .destructive, identifier: "contact-report"
            ) {
                confirmReport = true
            }
            .confirmationDialog(Copy.reportTitle(info.name), isPresented: $confirmReport) {
                Button(Copy.reportAndBlock, role: .destructive) { contact.reportSpam() }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(Copy.reportDetail)
            }
        }
        .disabled(contact.busy)
    }

    private static func color(_ availability: PresenceSummary.Availability?) -> Color {
        switch availability {
        case .available?, .chat?: .green
        case .away?, .extendedAway?: .orange
        case .doNotDisturb?: .red
        case nil: .secondary
        }
    }
}

/// What the contact published of themselves: only the fields they filled in.
private struct ContactProfileFields: View {
    let profile: ProfileFields

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(Copy.fullName, profile.fullName)
            row(Copy.nickname, profile.nickname)
            row(Copy.email, profile.email)
            row(Copy.webPage, profile.webPage)
            if !profile.note.isEmpty {
                Text(profile.note)
                    .font(.appBody)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.appBody)
        }
    }
}

/// OMEMO for the chat: Undecided (a new chat whose contact's devices could not be read yet,
/// R63), On or Off. Off is the chat's choice to send in the clear; choosing it for an
/// undecided chat with messages waiting asks first, as they then go unencrypted (M31).
struct EncryptionToggle: View {
    let model: AppModel
    let chatID: Int64
    @State private var settled = true
    @State private var waiting: Int?
    @State private var confirmOff = false

    enum Choice: Hashable {
        case undecided, on, off
    }

    var body: some View {
        let on =
            model.openChatSettings.flatMap { $0.id == chatID ? $0 : nil }?.encryption == .omemo
        let choice: Choice = settled ? (on ? .on : .off) : .undecided
        Picker(
            Copy.omemoEncryption,
            selection: Binding(get: { choice }, set: { choose($0, from: choice) })
        ) {
            if !settled { Text(Copy.encryptionUndecided).tag(Choice.undecided) }
            Text(Copy.encryptionOn).tag(Choice.on)
            Text(Copy.encryptionOff).tag(Choice.off)
        }
        .pickerStyle(.segmented)
        .font(.appBody)
        .pointerStyle(.link)
        .accessibilityIdentifier("encryption-toggle")
        .task(id: chatID) {
            for await value in model.database.encryptionSettledChanges(chatID: chatID) {
                settled = value
            }
        }
        .confirmationDialog(Copy.sendUnencryptedTitle(waiting), isPresented: $confirmOff) {
            Button(Copy.sendUnencrypted, role: .destructive) { write(.none) }
            Button(Copy.cancel, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        }
    }

    private func choose(_ next: Choice, from current: Choice) {
        switch next {
        case .undecided: return
        case .on: write(.omemo)
        case .off:
            guard current == .undecided else {
                write(.none)
                return
            }
            // Messages written while it was undecided go in the clear: asked first.
            let database = model.database
            let chatID = chatID
            Task {
                // A count that cannot be read asks too (fail closed).
                let count = await Self.waitingMessages(chatID, in: database)
                if UnencryptedChoice.asks(waiting: count) {
                    waiting = count
                    confirmOff = true
                } else {
                    write(.none)
                }
            }
        }
    }

    private func write(_ mode: EncryptionMode) {
        let database = model.database
        let chatID = chatID
        Task { await Self.choose(mode, chatID: chatID, in: database) }
    }

    @concurrent private static func waitingMessages(_ chatID: Int64, in database: AppDatabase)
        async -> Int?
    {
        try? database.pendingOutgoingCount(chatID: chatID)
    }

    @concurrent private static func choose(
        _ mode: EncryptionMode, chatID: Int64, in database: AppDatabase
    ) async {
        do {
            try database.chooseEncryption(chatID: chatID, mode)
        } catch {
            appLog.error("Chat update failed: \(String(describing: error), privacy: .private)")
        }
    }
}

/// Changes when the account's session comes or goes, so what is read from it is read again.
struct ConnectionKey: Hashable {
    let accountID: Int64
    let state: String

    @MainActor init(model: AppModel, accountID: Int64) {
        self.accountID = accountID
        state = model.status.connection[accountID].map { String(describing: $0) } ?? ""
    }
}
