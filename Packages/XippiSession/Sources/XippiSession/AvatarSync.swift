import Foundation
import UniformTypeIdentifiers
import XMPPCore
import XippiStore
import os

/// Avatars of the account's contacts and of the account itself, kept as files named by their
/// SHA-1 and shown on their chats: the PEP avatar (XEP-0084) when the contact publishes one,
/// otherwise the vCard avatar its presence names (XEP-0153), as XEP-0398 orders them.
///
/// - Who: the session hands over only the account's own avatar and those of contacts whose
///   presence it receives; nobody else is asked for anything.
/// - Fetches run one at a time in the background, the newest wish per contact served, so a
///   presence flood after login does not flood the server. An image is fetched once per hash:
///   a hash already stored is shown at once.
/// - Disk: images nothing shows are removed (files too), and all images together stay within
///   `budget`; an image that does not fit even after that is not kept.
/// - Names: an image is named, in the store, by the chat and roster row of each contact that
///   shows it and by the account's own profile row for its own (Task 26a), so files outlive the
///   session that fetched them only while something shows them (`AvatarCleanup`).
/// - Cleanups of other sessions and of `AvatarCleanup` may run at any moment. They decide and
///   delete inside one store write, and this side names an image in the same write that
///   records it, then checks its file is still there and writes it again if a cleanup took it
///   in between. So an image shown is never left without its file.
actor AvatarSync {
    enum Wanted: Sendable, Equatable {
        case pep(Avatars.Info)
        case vcard(hash: String)

        var hash: String {
            switch self {
            case .pep(let info): info.id
            case .vcard(let hash): hash
            }
        }
    }

    let accountID: Int64
    let database: AppDatabase
    let sender: any StanzaSending
    let directory: URL
    let budget: Int64
    /// The account's bare JID: its avatar is named by its own profile row.
    let ownJID: JID
    /// Tests: runs after an image's file is written, before its record.
    private var afterFileWrite: (@Sendable () -> Void)?

    /// Contacts whose PEP metadata is known: their vCard hashes are ignored.
    private var publishesPEP: Set<JID> = []
    /// The hash shown for each contact, and the wish it came from.
    private var shown: [JID: Wanted] = [:]
    private var wanted: [JID: Wanted] = [:]
    private var worker: Task<Void, Never>?
    /// The account's own published avatar, kept whatever the chats show.
    private var ownHash: String?

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    init(
        accountID: Int64, database: AppDatabase, sender: any StanzaSending, directory: URL,
        budget: Int64, ownJID: JID
    ) {
        self.accountID = accountID
        self.database = database
        self.sender = sender
        self.directory = directory
        self.budget = budget
        self.ownJID = ownJID.bare
    }

    func setAfterFileWrite(_ hook: (@Sendable () -> Void)?) {
        afterFileWrite = hook
    }

    /// A fresh session: who publishes what is learnt again from the notifications that
    /// follow, and images left from earlier are tidied up.
    func sessionStarted() {
        publishesPEP = []
        wanted = [:]
        removeUnused()
    }

    /// A metadata notification (XEP-0084), from someone the session lets through.
    func metadataChanged(_ update: Avatars.Update) {
        let jid = update.from.bare
        publishesPEP.insert(jid)
        switch Avatars.reference(pep: update.metadata, vcard: nil) {
        case .pep(let info): want(.pep(info), for: jid)
        case .some(.none): show(nil, for: jid)
        // Formats this client does not fetch (only a URL): keep what is shown.
        case .vcard, nil: break
        }
    }

    /// The vCard hash a presence names (XEP-0153), from someone the session lets through.
    func presenceHash(_ hash: Presence.AvatarHash, from jid: JID) {
        let bare = jid.bare
        guard !publishesPEP.contains(bare) else { return }
        switch hash {
        case .hash(let hash): want(.vcard(hash: hash), for: bare)
        case .noAvatar: show(nil, for: bare)
        case .notReady: break
        }
    }

    /// A chat was created for `jid`: it shows the avatar already known, fetched again when
    /// its file went meanwhile.
    func chatCreated(for jid: JID) {
        let bare = jid.bare
        guard let wish = shown[bare] else { return }
        if (try? storedFile(hash: wish.hash)) != nil {
            setChatAvatar(wish.hash, for: bare)
        } else {
            shown[bare] = nil
            want(wish, for: bare)
        }
    }

    /// Stores an image the account published itself, so its own hash shows without a fetch.
    func storeOwn(_ data: Data, type: String) throws {
        let hash = Avatars.sha1(data)
        ownHash = hash
        guard try store(data, hash: hash, type: type, for: ownJID) else { return }
        try database.showAvatar(
            accountID: accountID, jid: ownJID.description, hash: hash, own: true)
    }

    /// The account's own picture as stored here, with its type; nil without one.
    func ownImage() -> (data: Data, type: String)? {
        let hash =
            ownHash ?? (try? database.ownProfile(accountID: accountID))?.flatMap(\.avatarHash)
        guard let hash, let url = try? storedFile(hash: hash),
            let data = try? Data(contentsOf: url)
        else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return (data, type)
    }

    /// The SHA-1 of the account's own picture as stored here; nil without one.
    func ownPictureHash() -> String? {
        ownHash ?? (try? database.ownProfile(accountID: accountID))?.flatMap(\.avatarHash)
    }

    /// The account took its avatar down.
    func ownRemoved() {
        ownHash = nil
        show(nil, for: ownJID)
    }

    // MARK: Fetching

    private func want(_ wish: Wanted, for jid: JID) {
        guard shown[jid]?.hash != wish.hash else { return }
        if (try? storedFile(hash: wish.hash)) != nil {
            show(wish, for: jid)
            return
        }
        wanted[jid] = wish
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    private func drain() async {
        while let (jid, wish) = wanted.first {
            wanted[jid] = nil
            await fetch(wish, for: jid)
        }
        worker = nil
    }

    private func fetch(_ wish: Wanted, for jid: JID) async {
        let hash = wish.hash
        let image: (data: Data, type: String)
        switch wish {
        case .pep(let info):
            do {
                image = (try await Avatars.fetchData(hash: hash, from: jid, via: sender), info.type)
            } catch {
                Self.log.notice("Avatar not fetched")
                return
            }
        case .vcard:
            guard let profile = try? await VCardTemp.fetch(jid, via: sender),
                case .data(let data, let type)? = profile.avatar, Avatars.sha1(data) == hash
            else {
                Self.log.notice("vCard avatar not fetched")
                return
            }
            image = (data, type ?? "image/png")
        }
        // A newer wish for this contact may have come meanwhile; it is served next.
        guard wanted[jid] == nil else { return }
        do {
            guard try store(image.data, hash: hash, type: image.type, for: jid) else { return }
        } catch {
            Self.log.error("Avatar not stored")
            return
        }
        show(wish, for: jid)
    }

    // MARK: Showing and storing

    private func show(_ wish: Wanted?, for jid: JID) {
        guard wish == nil || shown[jid]?.hash != wish?.hash else { return }
        shown[jid] = wish
        setChatAvatar(wish?.hash, for: jid)
        // A cleanup took the image between the check and the naming: fetch it again.
        if let wish, (try? storedFile(hash: wish.hash)) == nil {
            shown[jid] = nil
            want(wish, for: jid)
        }
        removeUnused()
    }

    /// Names the image on the contact's chat and roster row, or on the account's own profile.
    private func setChatAvatar(_ hash: String?, for jid: JID) {
        do {
            try database.showAvatar(
                accountID: accountID, jid: jid.description, hash: hash, own: jid == ownJID)
        } catch {
            Self.log.error("Chat avatar not stored")
        }
    }

    private func owner(_ jid: JID?) -> AvatarOwner? {
        jid.map { AvatarOwner(accountID: accountID, jid: $0.description, own: $0 == ownJID) }
    }

    /// The stored file for `hash`, when the record and the file are both there.
    private func storedFile(hash: String) throws -> URL? {
        guard let record = try database.avatar(hash: hash) else { return nil }
        let url = directory.appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps the image when it fits the budget, after removing what nobody shows and, if
    /// that is not enough, the image `jid` showed so far (this one replaces it). Returns
    /// whether it is kept.
    private func store(_ data: Data, hash: String, type: String, for jid: JID?) throws -> Bool {
        if try storedFile(hash: hash) != nil { return true }
        let size = Int64(data.count)
        if try database.avatarBytes() + size > budget {
            removeUnused()
            if try database.avatarBytes() + size > budget, let jid, shown[jid] != nil {
                show(nil, for: jid)
            }
            guard try database.avatarBytes() + size <= budget else {
                Self.log.notice("Avatar not kept: over the size budget")
                return false
            }
        }
        let ext = UTType(mimeType: type)?.preferredFilenameExtension ?? "img"
        let name = hash + "." + ext
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        afterFileWrite?()
        // Recorded and named in one write: no cleanup sees it unnamed from here on.
        try database.storeAvatar(
            AvatarRecord(hash: hash, fileName: name, byteSize: size), shownBy: owner(jid))
        // A cleanup that ran between the file and the record took the file: it stays now.
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return true
    }

    /// Removes the images nothing names, apart from those this session still shows and the
    /// account's own, with their files. The files go inside the store's write (see the type's
    /// notes).
    private func removeUnused() {
        let keep = Set(shown.values.map(\.hash)).union(ownHash.map { [$0] } ?? [])
        let directory = self.directory
        do {
            try database.removeUnusedAvatars(keeping: keep) { record in
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(record.fileName))
            }
        } catch {
            Self.log.error("Unused avatars not removed")
        }
    }
}
