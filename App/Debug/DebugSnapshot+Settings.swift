#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import XMPPCore
    import XippiSession
    import XippiStore

    /// `-UITestAction` steps for the account settings (UI test launches only). Each acts as the
    /// first account unless an account is named:
    /// - `setprofile <full name>`: publishes the profile with that full name and an email.
    /// - `setavatar <path>`: crops the picture at `path` to its middle square and publishes it.
    /// - `dropavatar`: takes the avatar down.
    /// - `visibility <contacts|everyone>`: who can read the profile and picture (R64); the
    ///   two steps above publish for the audience chosen last (contacts at first).
    /// - `block <jid>`, `unblock <jid>`: the blocklist.
    /// - `archive <always|roster|never>`: the archive default.
    /// - `connopts <resource> <priority>`: the connection options.
    /// - `forgetpassword`: keeps a wrong password and reconnects, as when the password changed
    ///   elsewhere; `enterpassword <password>`: enters it again.
    /// - `groupnotify <all|mentions|none>`: the Settings default for new group chats.
    /// - `publiccopyshot`: saves `<name>.public-copy.png`, the confirmation before a public
    ///   vcard-temp is cleared.
    /// - `accountshot <pane> <suffix> [jid]`: saves the Accounts tab on that pane as
    ///   `<name>.account-<pane>-<suffix>.png`, and `<name>.settings-<suffix>.txt` with what the
    ///   account settings show: states, blocklists, own profiles, archive default, avatars on
    ///   every chat, and each account's view of the others' profiles.
    extension DebugSnapshot {
        private static var settingsResults: [String] = []
        private static var visibility = ProfileVisibility.contacts

        static func performSettings(_ parts: [String]) async {
            guard let model else { return }
            let words = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            let argument = parts.count > 1 ? parts[1] : ""
            guard let account = model.accounts.first, let id = account.id else { return }
            let session = await model.session(of: id)
            switch parts.first {
            case "setprofile":
                do {
                    try await session?.updateOwnProfile(
                        ProfileFields(fullName: argument, email: "\(account.jid)"),
                        visibility: visibility)
                    settingsResults.append("setprofile=ok")
                } catch {
                    settingsResults.append("setprofile=\(Copy.notSaved(error))")
                }
            case "setavatar":
                guard let data = FileManager.default.contents(atPath: argument),
                    let image = AvatarCrop.uprightImage(from: data)
                else {
                    settingsResults.append("setavatar=unreadable")
                    return
                }
                var crop = AvatarCrop(
                    imageSize: CGSize(width: image.width, height: image.height))
                crop.zoom = 1.25
                guard let png = AvatarCrop.render(image, crop: crop) else { return }
                do {
                    try await session?.publishAvatar(imageData: png, visibility: visibility)
                    settingsResults.append("setavatar=ok bytes=\(png.count)")
                } catch {
                    settingsResults.append("setavatar=\(Copy.pictureNotPublished(error))")
                }
            case "visibility":
                guard let chosen = ProfileVisibility(rawValue: argument) else { return }
                do {
                    try await session?.setProfileVisibility(chosen)
                    visibility = chosen
                    settingsResults.append("visibility=\(chosen.rawValue)")
                } catch {
                    settingsResults.append("visibility=\(Copy.visibilityNotChanged(error))")
                }
            case "dropavatar":
                do {
                    try await session?.removeAvatar()
                    settingsResults.append("dropavatar=ok")
                } catch {
                    settingsResults.append("dropavatar=\(Copy.pictureNotPublished(error))")
                }
            case "block", "unblock":
                guard let jid = try? JID(argument) else { return }
                do {
                    if parts.first == "block" {
                        try await session?.block(jid)
                    } else {
                        try await session?.unblock(jid)
                    }
                    settingsResults.append("\(parts.first ?? "")=ok \(jid)")
                } catch {
                    settingsResults.append("\(parts.first ?? "")=\(Copy.notBlocked(error))")
                }
            case "archive":
                guard let value = MAMPreferences.Default(rawValue: argument),
                    var preferences = try? await session?.archivePreferences()
                else {
                    settingsResults.append("archive=not read")
                    return
                }
                preferences.default = value
                let saved = try? await session?.setArchivePreferences(preferences)
                settingsResults.append("archive=\(saved?.default.rawValue ?? "not saved")")
            case "connopts":
                // The server stays as it is: `host` or `host:port`, as the field shows it.
                let server =
                    (account.hostOverride ?? "")
                    + (account.portOverride.map { ":\($0)" } ?? "")
                let failure = await model.setConnectionOptions(
                    resource: words.first ?? "", priority: Int(words.last ?? "") ?? 0,
                    server: server, accountID: id)
                settingsResults.append("connopts=\(failure ?? "ok")")
            case "forgetpassword":
                guard let jid = try? JID(account.jid) else { return }
                try? model.services.credentials.setPassword("not-the-password", for: jid)
                await model.reconnect(accountID: id)
            case "enterpassword":
                let failure = await model.enterPassword(argument, accountID: id)
                settingsResults.append("enterpassword=\(failure ?? "ok")")
            case "groupnotify":
                if let level = NotifyLevel(rawValue: argument) {
                    try? model.database.setGroupNotifyDefault(level)
                }
            case "publiccopyshot":
                await renderOffscreen(
                    RemovePublicCopySheet(
                        fields: [
                            PublicField(name: "FN", value: "Alice Liddell"),
                            PublicField(name: "TEL", value: "+31 20 555 0100"),
                            PublicField(name: "PHOTO", value: ""),
                        ], onRemove: {}, onCancel: {}),
                    size: NSSize(width: 420, height: 190),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling("public-copy"))
            case "accountshot":
                await accountShot(words, model: model)
            default:
                break
            }
        }

        private static func accountShot(_ words: [String], model: AppModel) async {
            let pane = AccountPane(rawValue: words.first ?? "") ?? .account
            let suffix = words.count > 1 ? words[1] : ""
            let jid = words.count > 2 ? words[2] : model.accounts.first?.jid
            guard let account = model.accounts.first(where: { $0.jid == jid }) else { return }
            let dark = NSApp.effectiveAppearance.isDark
            await renderOffscreen(
                AccountDetail(model: model, account: account, pane: pane) { _ in },
                size: NSSize(width: 540, height: 580), dark: dark,
                to: sibling("account-\(pane.rawValue)-\(suffix)"))
            await describeSettings(model, suffix: suffix)
        }

        /// What the account settings show, as text beside the pictures.
        private static func describeSettings(_ model: AppModel, suffix: String) async {
            var lines = settingsResults
            let database = model.database
            for account in model.accounts {
                guard let id = account.id else { continue }
                let status = model.status(of: account)
                lines.append(
                    "account \(account.jid) status=\(Copy.statusLine(status))"
                        + " detail=\(Copy.statusDetail(status) ?? "-")"
                        + " needsPassword=\(status.needsPassword) resource=\(account.resource)"
                        + " priority=\(account.priority) pins=\(account.pinnedCertSHA256.count)"
                        + " blocked=\(model.status.blocklists[id]?.sorted() ?? [])")
                let own = try? database.ownProfile(accountID: id)
                lines.append(
                    "  own profile fullName=\(own?.fullName ?? "-") avatar=\(own?.avatarHash ?? "-")"
                        + " file=\(avatarFileExists(own?.avatarHash, model: model))")
                for chat in (try? database.chats(accountID: id)) ?? [] {
                    lines.append(
                        "  chat \(chat.jid) kind=\(chat.kind.rawValue) notify=\(chat.notify.rawValue)"
                            + " avatar=\(chat.avatarHash ?? "-")"
                            + " file=\(avatarFileExists(chat.avatarHash, model: model))")
                }
                guard let session = await model.session(of: id) else { continue }
                lines.append(
                    "  visibility=\(Self.audienceText(await session.profileAudience()))")
                if let preferences = try? await session.archivePreferences() {
                    lines.append("  archive default=\(preferences.default.rawValue)")
                }
                for other in model.accounts where other.jid != account.jid {
                    guard let peer = try? JID(other.jid) else { continue }
                    let profile = try? await session.fetchProfile(of: peer)
                    lines.append(
                        "  sees \(other.jid) fullName=\(profile?.fullName ?? "-")"
                            + " email=\(profile?.emails.first ?? "-")")
                }
            }
            lines.append("groupDefault=\((try? database.groupNotifyDefault())?.rawValue ?? "-")")
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension(
                    "settings-\(suffix).txt"))
        }

        private static func audienceText(_ reading: ProfileAudienceReading?) -> String {
            guard let reading else { return "-" }
            let audience =
                switch reading.audience {
                case .contacts: "contacts"
                case .everyone: "everyone"
                case .mixed: "mixed"
                case .unknown: "unknown"
                }
            return audience + " setting=\(reading.setting?.rawValue ?? "-")"
                + " publicCopy=\(reading.publicCopy.map(Copy.publicField))"
                + " serverCopy=\(reading.serverCopy.map(Copy.publicField))"
                + " note=\(Copy.publicNote(reading.serverCopy, certain: reading.serverCopyCertain) ?? "-")"
        }

        private static func avatarFileExists(_ hash: String?, model: AppModel) -> String {
            guard let hash, let record = try? model.database.avatar(hash: hash) else { return "-" }
            let url = model.sessions.avatarDirectory.appending(path: record.fileName)
            return FileManager.default.fileExists(atPath: url.path) ? "yes" : "missing"
        }
    }
#endif
