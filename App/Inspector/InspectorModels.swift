import Foundation
import ImageIO
import OMEMO
import Observation
import UniformTypeIdentifiers
import XMPPCore
import XippiSession
import XippiStore

/// What the contact inspector shows of a direct chat and what it does: the roster entry,
/// blocking, OMEMO devices and their trust. Commands go to the account's session; without one
/// (the account is disabled or offline) they say so.
@MainActor @Observable final class ContactInspectorModel {
    let chatID: Int64
    let accountID: Int64
    /// The contact's bare JID.
    let jid: JID
    private(set) var roster: RosterItemRecord?
    private(set) var isBlocked = false
    /// The contact's identities (R60): one per key, whichever versions and devices show it,
    /// as the engine keeps trust for them.
    private(set) var identities: [OMEMOIdentityInfo] = []
    /// The account's own identities, this Mac first.
    private(set) var ownIdentities: [OMEMOIdentityInfo] = []
    private(set) var busy = false
    var error: String?
    /// What a trust decision or a reset could not do, shown beside the devices.
    var trustError: String?
    /// The contact's published profile (vCard), once read; nil while unknown or empty.
    private(set) var profile: ProfileFields?

    @ObservationIgnored private let model: AppModel

    init(model: AppModel, chatID: Int64, accountID: Int64, jid: JID) {
        self.model = model
        self.chatID = chatID
        self.accountID = accountID
        self.jid = jid.bare
    }

    var isVerified: Bool { OMEMOTrustSummary.isVerified(identities) }

    /// A verified contact has a device nobody verified, or a key that waits for the user's
    /// decision, as when a verified key changed (spec 11, I-2).
    var needsAttention: Bool { OMEMOTrustSummary.needsAttention(identities) }

    /// What the banner says of it.
    var attentionText: String {
        OMEMOTrustSummary.hasUnverifiedNewDevice(identities)
            ? Copy.newDeviceNotVerified : Copy.keyNotVerified
    }

    /// The session is reading the keys of devices nobody has shown yet (I-3).
    private(set) var fetchingKeys = false

    /// Follows the roster entry while the inspector shows the contact.
    func followRoster() async {
        for await item in model.database.rosterItemUpdates(
            accountID: accountID, jid: jid.description)
        {
            roster = item
        }
    }

    /// Reads what the session knows now: blocking and devices. Without a session (the
    /// account is off) what was read last stays.
    func refresh() async {
        guard let session = await model.session(accountID: accountID) else { return }
        isBlocked = await session.isBlocked(jid)
        identities = await session.omemoIdentities(of: jid).filter { !$0.isThisDevice }
        let own = await session.omemoIdentities(of: session.jid)
        ownIdentities = own.filter(\.isThisDevice) + own.filter { !$0.isThisDevice }
    }

    /// Reads the contact's profile once per opening: it changes rarely, and it is a request
    /// to the contact's server. What cannot be read shows nothing.
    func loadProfile() async {
        guard let session = await model.session(accountID: accountID),
            let fetched = try? await session.fetchProfile(of: jid)
        else { return }
        let fields = ProfileFields(fetched).normalized
        profile = Self.isEmpty(fields) ? nil : fields
    }

    private static func isEmpty(_ fields: ProfileFields) -> Bool {
        [fields.fullName, fields.nickname, fields.email, fields.webPage, fields.note]
            .allSatisfy(\.isEmpty)
    }

    /// Has the session read the keys of the contact's listed devices that nobody has shown
    /// yet (I-3), then reads what it knows again. Those devices show "Fetching key" meanwhile.
    func fetchKeys() async {
        guard let session = await model.session(accountID: accountID) else { return }
        fetchingKeys = true
        await session.refreshOMEMOIdentities(of: jid)
        fetchingKeys = false
        await refresh()
    }

    // MARK: Trust

    /// The user's decision on an identity as it was shown: every record of that key, in
    /// both versions (R60). A key that changed since is refused with the one it has now (I3).
    func setTrust(_ trust: DeviceTrust, for identity: OMEMOIdentityInfo) {
        let owner = identity.jid
        #if DEBUG || UITEST_HOOKS
            // The UI tests' sample devices have no session: the decision is kept here.
            if DebugSnapshot.usesInspectorSamples {
                for index in identities.indices where identities[index].id == identity.id {
                    identities[index].trust = trust
                }
                return
            }
        #endif
        run(Copy.trustState(trust), trust: true) { session in
            try await session.setOMEMOTrust(trust, identity: identity, of: owner)
        }
    }

    /// New sessions with every device of the contact that is not distrusted (R39).
    func resetSessions() {
        run(Copy.resetSessions, trust: true) { session in
            try await session.replaceOMEMOSessions(with: self.jid)
        }
    }

    // MARK: Contact

    func setBlocked(_ blocked: Bool) {
        run(blocked ? Copy.blockContact : Copy.unblockContact) { session in
            if blocked {
                try await session.block(self.jid)
            } else {
                try await session.unblock(self.jid)
            }
        }
    }

    /// Reports the contact as spam (XEP-0377), which also blocks it.
    func reportSpam() {
        run(Copy.reportSpam) { session in
            try await session.report(self.jid, reason: .spam)
        }
    }

    func rename(_ name: String) {
        run(Copy.rename) { session in
            try await session.renameContact(self.jid, name: name)
        }
    }

    func remove() {
        run(Copy.removeContact) { session in
            try await session.removeContact(self.jid)
        }
    }

    func add() {
        run(Copy.addToContacts) { session in
            try await session.addContact(self.jid)
        }
    }

    /// Runs a session command; a refusal shows as "<what> failed: <why>", beside the devices
    /// for `trust`. Then reads again.
    private func run(
        _ what: String, trust: Bool = false,
        _ work: @escaping @MainActor (AccountSession) async throws -> Void
    ) {
        error = nil
        trustError = nil
        busy = true
        Task {
            defer { busy = false }
            var failure: String?
            if let session = await model.session(accountID: accountID) {
                do {
                    try await work(session)
                } catch {
                    failure = Copy.failed(what, ChatCommandError.words(error))
                }
            } else {
                failure = Copy.failed(what, Copy.notConnectedReason)
            }
            if trust { trustError = failure } else { error = failure }
            await refresh()
        }
    }
}

/// What the room inspector shows of a room and what it does: the account's role, who is in
/// it, moderation, subject and settings. Follows the room's changes while it is shown.
@MainActor @Observable final class RoomInspectorModel {
    let chatID: Int64
    let accountID: Int64
    /// Bare.
    let room: JID
    private(set) var snapshot: RoomSnapshot?
    private(set) var busy = false
    var error: String?
    /// The owner's configuration form, while its sheet is open.
    var configuration: DataForm?

    @ObservationIgnored private let model: AppModel

    init(model: AppModel, chatID: Int64, accountID: Int64, room: JID) {
        self.model = model
        self.chatID = chatID
        self.accountID = accountID
        self.room = room.bare
    }

    /// Reads the room now and again after each change, a change in a burst (a join of a
    /// large room) read once.
    func follow() async {
        guard let session = await model.session(accountID: accountID) else {
            #if DEBUG || UITEST_HOOKS
                // The UI tests' sample members stand in for a session.
                if DebugSnapshot.usesInspectorSamples { return }
            #endif
            snapshot = nil
            return
        }
        snapshot = await session.roomSnapshot(chatID: chatID)
        for await _ in await session.roomChanges(chatID: chatID) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            snapshot = await session.roomSnapshot(chatID: chatID)
        }
    }

    /// The action on the member the user picked: roles by nick only while the nick is still
    /// theirs, affiliations by their address only (R13).
    func perform(_ action: RoomMemberAction, on member: RoomMember) {
        let chatID = chatID
        run(Copy.memberAction(action)) { session in
            switch action {
            case .kick:
                try await session.kick(chatID: chatID, member: member)
            case .grantVoice:
                try await session.setRole(chatID: chatID, member: member, role: .participant)
            case .revokeVoice:
                try await session.setRole(chatID: chatID, member: member, role: .visitor)
            case .grantMembership:
                try await session.setAffiliation(
                    chatID: chatID, member: member, affiliation: .member)
            case .revokeMembership:
                try await session.setAffiliation(
                    chatID: chatID, member: member, affiliation: MUCPresence.Affiliation.none)
            case .ban:
                try await session.setAffiliation(
                    chatID: chatID, member: member, affiliation: .outcast)
            }
        }
    }

    /// Asks the room for another nick for the account; the room's answer shows on the chat.
    func changeNick(_ nick: String) {
        let chatID = chatID
        run(Copy.changeNickname) { session in
            try await session.changeRoomNick(chatID: chatID, to: nick)
        }
    }

    /// XEP-0425: removes the message for everyone, as a moderator. A refusal also goes to
    /// `onError`, shown where it was asked for (the transcript's error line).
    func moderate(messageID: Int64, onError: ((String) -> Void)? = nil) {
        run(Copy.removeForEveryone, onError: onError) { session in
            try await session.moderate(messageID: messageID)
        }
    }

    func setSubject(_ subject: String) {
        let chatID = chatID
        run(Copy.editSubject) { session in
            try await session.setRoomSubject(chatID: chatID, subject)
        }
    }

    func leave() {
        let chatID = chatID
        run(Copy.leave) { session in try await session.leaveRoom(chatID: chatID) }
    }

    /// Leaves and removes the bookmark everywhere; the chat and its history stay.
    func forget() {
        let chatID = chatID
        run(Copy.forget) { session in try await session.forgetRoom(chatID: chatID) }
    }

    /// Joins again with the nick and password the chat keeps.
    func join(nick: String, password: String?) {
        let room = room
        run(Copy.join) { session in
            try await session.joinRoom(jid: room, nick: nick, password: password)
        }
    }

    func loadConfiguration() {
        let chatID = chatID
        run(Copy.roomSettings) { session in
            let form = try await session.roomConfiguration(chatID: chatID)
            self.configuration = form
        }
    }

    func submitConfiguration(_ form: DataForm) {
        let chatID = chatID
        run(Copy.roomSettings) { session in
            try await session.configureRoom(chatID: chatID, form)
            self.configuration = nil
        }
    }

    private func run(
        _ what: String, onError: ((String) -> Void)? = nil,
        _ work: @escaping @MainActor (AccountSession) async throws -> Void
    ) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            guard let session = await model.session(accountID: accountID) else {
                error = Copy.failed(what, Copy.notConnectedReason)
                onError?(error ?? "")
                return
            }
            do {
                try await work(session)
            } catch {
                self.error = Copy.failed(what, ChatCommandError.words(error))
                onError?(self.error ?? "")
            }
        }
    }
}

#if DEBUG || UITEST_HOOKS
    extension ContactInspectorModel {
        /// What a session would have said, for the snapshot hook.
        func debugSeed(
            identities: [OMEMOIdentityInfo], own: [OMEMOIdentityInfo], blocked: Bool = false
        ) {
            self.identities = identities
            ownIdentities = own
            isBlocked = blocked
        }
    }

    extension RoomInspectorModel {
        /// What a session would have said, for the snapshot hook.
        func debugSeed(_ snapshot: RoomSnapshot?) {
            self.snapshot = snapshot
        }
    }
#endif

/// A file or picture shared in a chat, for the inspector.
struct SharedMediaItem: Identifiable, Sendable, Equatable {
    /// The attachment's id.
    let id: Int64
    let messageID: Int64
    let fileName: String
    let isImage: Bool
    /// The file here, when it was downloaded.
    let file: URL?
    let date: Date
}

/// A chat's newest files, read off the main thread from the store's shared media query.
enum SharedMedia {
    /// Files shown at most.
    static let shown = 60

    @concurrent static func load(
        chatID: Int64, database: AppDatabase, library: MediaLibrary?
    ) async -> [SharedMediaItem] {
        guard let files = try? database.sharedMedia(chatID: chatID, limit: shown) else {
            return []
        }
        return files.compactMap { file in
            let attachment = file.attachment
            guard let id = attachment.id else { return nil }
            let type = attachment.sniffedMimeType ?? attachment.mimeType ?? ""
            let local = attachment.localPath.flatMap { path in
                library?.existingFile(for: path)
                    ?? (FileManager.default.fileExists(atPath: path)
                        ? URL(fileURLWithPath: path) : nil)
            }
            return SharedMediaItem(
                id: id, messageID: file.messageID, fileName: attachment.fileName ?? Copy.file,
                isImage: UTType(mimeType: type)?.conforms(to: .image) == true, file: local,
                date: file.timestamp)
        }
    }

    /// A small picture of an image file, decoded off the main thread.
    @concurrent static func thumbnail(of url: URL, pixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
