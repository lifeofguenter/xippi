import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XMPPCore
import XippiSession
import XippiStore

/// The account's own profile: its picture (picked, cropped and published as its avatar) and
/// the vCard fields people see. Shown from what was last read or published while offline;
/// edited only while online.
struct AccountProfilePane: View {
    let model: AppModel
    let account: AccountRecord
    @State private var fields = ProfileFields()
    /// The fields as last read or published, to tell what changed.
    @State private var saved = ProfileFields()
    @State private var avatar: NSImage?
    /// Who can read the profile and picture, as last read from the server (R64, R68), with
    /// the generation of the read: a read overtaken by a newer read or a switch is dropped.
    @State private var tracker = ProfileAudienceTracker()
    /// A read of the audience is under way.
    @State private var readingAudience = false
    /// The public copy's fields shown in the confirmation; nil while it is closed. Exactly
    /// these are deleted (R70).
    @State private var removing: PublicCopySnapshot?
    /// The public copy changed after the confirmation first showed it (m26).
    @State private var changedSinceShown = false
    @State private var choosing = false
    @State private var crop: PictureToCrop?
    @State private var busy = false
    /// The picture on its way to the server: shown with a progress bar until it is there or
    /// failed.
    @State private var uploading: NSImage?
    @State private var error: String?

    var body: some View {
        let online = model.status(of: account) == .online
        Form {
            Section(Copy.picture) {
                HStack(spacing: 16) {
                    Group {
                        if let shown = uploading ?? avatar {
                            Image(nsImage: shown)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(.circle)
                        } else {
                            AvatarView(
                                name: fields.fullName.isEmpty ? account.jid : fields.fullName,
                                identifier: account.jid, size: 72)
                        }
                    }
                    .accessibilityHidden(true)
                    if uploading != nil {
                        // The server's answer is the only sign of how far it is: no percentage.
                        ProgressView(Copy.uploading(nil))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 180)
                            .accessibilityIdentifier("picture-uploading")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(Copy.choosePicture) { choosing = true }
                                .accessibilityIdentifier("choose-picture")
                            Button(role: .destructive, action: removePicture) {
                                Text(Copy.removePicture)
                                    .foregroundStyle(.red)
                            }
                            .disabled(avatar == nil)
                            .accessibilityIdentifier("remove-picture")
                        }
                        .pointerStyle(.link)
                        .disabled(!online || busy || chosenVisibility == nil)
                    }
                }
            }
            Section(Copy.paneProfile) {
                Picker(
                    selection: Binding(
                        get: { chosenVisibility },
                        set: { chosen in chosen.map(requestVisibility) })
                ) {
                    if chosenVisibility == nil {
                        Text(
                            reading != nil && reading?.audience != .unknown
                                ? Copy.visibilityMixed : Copy.visibilityNotKnown
                        )
                        .tag(ProfileVisibility?.none)
                    }
                    Text(Copy.visibleToContacts).tag(ProfileVisibility?.some(.contacts))
                    Text(Copy.visibleToEveryone).tag(ProfileVisibility?.some(.everyone))
                } label: {
                    Text(Copy.visibleTo)
                    if let help = visibilityHelp {
                        Text(help)
                    }
                }
                // Not read yet, or the read failed: nothing to apply a choice over.
                .disabled(busy || reading == nil || reading?.audience == .unknown)
                .pointerStyle(.link)
                .accessibilityIdentifier("profile-visibility")
                if online, !readingAudience, reading == nil || reading?.audience == .unknown {
                    Button(Copy.readAgain) { Task { await readAudience() } }
                        .pointerStyle(.link)
                        .accessibilityIdentifier("profile-visibility-read-again")
                }
                if let copy = reading?.publicCopySnapshot, !copy.fields.isEmpty {
                    Button(role: .destructive) {
                        changedSinceShown = false
                        removing = copy
                    } label: {
                        Text(Copy.removePublicCopy)
                            .foregroundStyle(.red)
                    }
                    .disabled(busy)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("remove-public-copy")
                }
                TextField(Copy.fullName, text: $fields.fullName)
                    .textContentType(.name)
                    .accessibilityIdentifier("profile-full-name")
                TextField(Copy.nickname, text: $fields.nickname)
                    .textContentType(.nickname)
                    .accessibilityIdentifier("profile-nickname")
                TextField(Copy.email, text: $fields.email, prompt: Text(Copy.addressPrompt))
                    .textContentType(.emailAddress)
                    .accessibilityIdentifier("profile-email")
                TextField(Copy.webPage, text: $fields.webPage, prompt: Text(Copy.webPagePrompt))
                    .textContentType(.URL)
                    .accessibilityIdentifier("profile-web-page")
                TextField(Copy.note, text: $fields.note, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("profile-note")
                ForEach(fields.problems, id: \.self) { problem in
                    Text(Copy.profileProblem(problem))
                        .foregroundStyle(.red)
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("profile-error")
                }
                HStack {
                    if !online {
                        Text(Copy.notConnected)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if busy, uploading == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(Copy.save, action: save)
                        .disabled(
                            !online || busy || chosenVisibility == nil
                                || fields.normalized == saved.normalized
                                || !fields.problems.isEmpty
                        )
                        .pointerStyle(.link)
                        .accessibilityIdentifier("profile-save")
                }
            }
            .disabled(!online)
        }
        .formStyle(.grouped)
        .font(.appBody)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { load(url) }
        }
        .sheet(
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            RemovePublicCopySheet(
                fields: removing?.fields ?? [], changed: changedSinceShown,
                onRemove: removePublicCopy, onCancel: { removing = nil })
        }
        .sheet(item: $crop) { picture in
            AvatarCropSheet(picture: picture, cancel: { crop = nil }, use: publish)
        }
        .task(id: account.jid) { await followStored() }
        .task(id: online) { if online { await refresh() } }
    }

    // MARK: Reading

    /// The own profile row: the picture, and the fields while nothing newer was read.
    private func followStored() async {
        guard let id = account.id else { return }
        let database = model.database
        let directory = model.sessions.avatarDirectory
        for await row in database.ownProfileUpdates(accountID: id) {
            avatar = await AppModel.ownAvatar(
                hash: row?.avatarHash, database: database, directory: directory)
            if let stored = row.flatMap({ ProfileFields(stored: $0.data) }),
                fields.normalized == saved.normalized
            {
                fields = stored
                saved = stored
            }
        }
    }

    /// The profile as the server has it now, unless the user is editing.
    private func refresh() async {
        await readAudience()
        guard let id = account.id, let session = await model.session(of: id) else { return }
        guard let read = try? await session.ownProfileFields(),
            fields.normalized == saved.normalized
        else { return }
        fields = read
        saved = read
    }

    // MARK: Changing

    private func save() {
        guard let id = account.id, fields.problems.isEmpty, let visibility = chosenVisibility
        else { return }
        let edited = fields
        run(id) { session throws(SessionError) in
            try await session.updateOwnProfile(edited, visibility: visibility)
            saved = edited
        } failure: {
            Copy.notSaved($0)
        } then: {
            await readAudience()
        }
    }

    private func removePicture() {
        guard let id = account.id else { return }
        run(id) { session throws(SessionError) in
            try await session.removeAvatar()
        } failure: {
            Copy.pictureNotPublished($0)
        } then: {
            await readAudience()
        }
    }

    private func publish(_ png: Data) {
        crop = nil
        guard let id = account.id, let visibility = chosenVisibility, !busy else { return }
        let picture = NSImage(data: png)
        uploading = picture
        run(id) { session throws(SessionError) in
            try await session.publishAvatar(imageData: png, visibility: visibility)
            // Until the stored copy replaces it, so the old picture does not flash back.
            avatar = picture
        } failure: {
            Copy.pictureNotPublished($0)
        } then: {
            uploading = nil
            await readAudience()
        }
    }

    /// The audience as last read; nil until read.
    private var reading: ProfileAudienceReading? { tracker.reading }

    /// What saving and the picture take: the setting read, when it is one.
    private var chosenVisibility: ProfileVisibility? {
        reading?.audience == .unknown ? nil : reading?.setting
    }

    /// What the row tells beside the choice: what the server shows to everyone beyond the
    /// setting, else who can see it; nothing while it is not known.
    private var visibilityHelp: String? {
        guard let reading, reading.audience != .unknown else { return nil }
        // I10: a public picture while the account shows none is said whatever the setting.
        if avatar == nil, reading.publicCopy.contains(where: { $0.name == "PHOTO" }) {
            return Copy.publicNote(reading.publicCopy.filter { $0.name == "PHOTO" }, certain: true)
        }
        // What is public beyond the setting, while the setting is Contacts or mixed (m22).
        if reading.setting != .everyone {
            if let note = Copy.publicNote(reading.publicCopy, certain: true) { return note }
            if let note = Copy.publicNote(reading.serverCopy, certain: reading.serverCopyCertain) {
                return note
            }
        }
        switch reading.setting {
        case .contacts?: return Copy.visibleToContactsHelp
        case .everyone?: return Copy.visibleToEveryoneHelp
        case nil: return Copy.visibilityMixedHelp
        }
    }

    /// A choice from the picker; the vcard-temp is never touched by it (R70).
    private func requestVisibility(_ chosen: ProfileVisibility) {
        guard chosen != chosenVisibility else { return }
        applyVisibility(chosen)
    }

    /// Deletes the public copy, exactly the fields the confirmation shows. When it changed
    /// meanwhile, the confirmation shows it again as it is now.
    private func removePublicCopy() {
        guard let id = account.id, let shown = removing, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            guard let session = await model.session(of: id) else {
                removing = nil
                error = Copy.notSaved(.notConnected)
                return
            }
            do throws(SessionError) {
                switch try await session.removePublicCopy(shown) {
                case .removed:
                    removing = nil
                case .changed(let now):
                    removing = now.fields.isEmpty ? nil : now
                    changedSinceShown = true
                }
            } catch {
                removing = nil
                self.error = Copy.notSaved(error)
            }
            if removing == nil {
                busy = false
                await readAudience()
            }
        }
    }

    /// Applies one audience to the profile and picture on the server, then reads what the
    /// server holds, and the profile's fields, whether it all went through or not.
    private func applyVisibility(_ chosen: ProfileVisibility) {
        guard let id = account.id, !busy else { return }
        tracker.beginSwitch()
        run(id) { session throws(SessionError) in
            try await session.setProfileVisibility(chosen)
        } failure: {
            Copy.visibilityNotChanged($0)
        } then: {
            await refresh()
        }
    }

    /// Reads who can read the profile and picture, waiting while the session sets up and its
    /// account disco answers. A read overtaken by a newer read or a switch is dropped.
    private func readAudience() async {
        guard let id = account.id else { return }
        let generation = tracker.beginRead()
        readingAudience = true
        defer { if tracker.isCurrent(generation) { readingAudience = false } }
        for _ in 0..<60 {
            guard let session = await model.session(of: id) else { return }
            if let read = await session.profileAudience() {
                tracker.finishRead(read, generation: generation)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, tracker.isCurrent(generation) else { return }
        }
    }

    private func run(
        _ accountID: Int64, _ work: @escaping (AccountSession) async throws(SessionError) -> Void,
        failure: @escaping (SessionError) -> String, then: @escaping () async -> Void = {}
    ) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            if let session = await model.session(of: accountID) {
                do throws(SessionError) {
                    try await work(session)
                } catch {
                    self.error = failure(error)
                }
            } else {
                error = failure(.notConnected)
            }
            busy = false
            await then()
        }
    }

    /// Reads the picked file (at most 50 MB) and opens the crop sheet on it.
    private func load(_ url: URL) {
        error = nil
        Task {
            if let picture = await PictureToCrop.load(url) {
                crop = picture
            } else {
                error = Copy.pictureNotReadable
            }
        }
    }
}

/// A picture picked for the avatar, upright and at most 2048 pixels on its longest side.
struct PictureToCrop: Identifiable {
    let id = UUID()
    let image: CGImage

    static let maxFileBytes = 50 * 1_048_576

    @concurrent static func load(_ url: URL) async -> PictureToCrop? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            size <= maxFileBytes, let data = try? Data(contentsOf: url),
            let image = AvatarCrop.uprightImage(from: data)
        else { return nil }
        return PictureToCrop(image: image)
    }
}

/// Zoom and move the picture until the square shows what the avatar should.
struct AvatarCropSheet: View {
    let picture: PictureToCrop
    let cancel: () -> Void
    let use: (Data) -> Void
    @State private var crop: AvatarCrop
    @State private var drag = CGSize.zero
    @State private var failed = false

    private static let viewport: CGFloat = 280

    init(picture: PictureToCrop, cancel: @escaping () -> Void, use: @escaping (Data) -> Void) {
        self.picture = picture
        self.cancel = cancel
        self.use = use
        _crop = State(
            initialValue: AvatarCrop(
                imageSize: CGSize(width: picture.image.width, height: picture.image.height)))
    }

    var body: some View {
        let shown = shownCrop
        let scale = Self.viewport / shown.side
        VStack(spacing: 16) {
            Text(Copy.picture)
                .font(.appTitle)
            Image(decorative: picture.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: shown.imageSize.width * scale, height: shown.imageSize.height * scale
                )
                .offset(x: -shown.rect.minX * scale, y: -shown.rect.minY * scale)
                .frame(width: Self.viewport, height: Self.viewport, alignment: .topLeading)
                .clipped()
                .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2) }
                .contentShape(.rect)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            crop.pan(
                                byViewportPoints: value.translation, viewportSide: Self.viewport)
                            drag = .zero
                        }
                )
                .pointerStyle(.grabIdle)
                .accessibilityLabel(Copy.picture)
            LabeledContent(Copy.zoom) {
                Slider(value: $crop.zoom, in: 1...AvatarCrop.maxZoom)
                    .frame(width: 200)
                    .accessibilityIdentifier("crop-zoom")
            }
            if failed {
                Text(Copy.pictureNotReadable)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(Copy.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(Copy.usePicture) {
                    guard let png = AvatarCrop.render(picture.image, crop: crop) else {
                        failed = true
                        return
                    }
                    use(png)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("crop-use")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 380)
    }

    /// The crop with the drag under way applied, as it would be if the drag ended now.
    private var shownCrop: AvatarCrop {
        var shown = crop
        if drag != .zero { shown.pan(byViewportPoints: drag, viewportSide: Self.viewport) }
        return shown
    }
}

/// Asks before the public copy of the profile (a vcard-temp the server keeps apart, which
/// anyone can read) is deleted, listing exactly the fields deleted (R70). "Remove public
/// copy" is red and never the default; Cancel is.
struct RemovePublicCopySheet: View {
    let fields: [PublicField]
    /// It changed after it was first shown: the list is what it holds now.
    var changed = false
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.removePublicCopyTitle)
                .font(.appTitle)
                .fixedSize(horizontal: false, vertical: true)
            if changed {
                Text(Copy.publicCopyChanged)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("remove-public-copy-changed")
            }
            Text(Copy.removePublicCopyDetail)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    Text(Copy.publicField(field))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, 8)
            .accessibilityIdentifier("remove-public-copy-fields")
            HStack(spacing: 10) {
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Text(Copy.removePublicCopy)
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("remove-public-copy-confirm")
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("remove-public-copy-cancel")
            }
            .controlSize(.large)
            .pointerStyle(.link)
        }
        .font(.appBody)
        .padding(24)
        .frame(width: 440)
        .onExitCommand(perform: onCancel)
    }
}
