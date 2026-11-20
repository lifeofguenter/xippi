#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import XMPPCore
    import XippiSession
    import XippiStore

    /// `-UITestAction` steps for the final fix wave's views, on seeded data:
    /// - `ff-avatars`: pictures for "Bob Chen", "Carol Diaz" and "prosody".
    /// - `ff-offer`: a file offered over Jingle in the open chat (R79).
    /// - `ff-distrusted`, `ff-reveal`: a message from a distrusted device in the open chat, and
    ///   its text shown (I-2).
    /// - `ff-gap`: history missing from the open chat's archive (I6).
    /// - `ff-contacts`: contacts of the first account that have no chat (C1).
    /// - `ff-private`: a private chat with "romeo" of the room "prosody", opened (R80).
    /// - `ff-own <text>`: our own message in the open chat, sent and archived.
    /// - `ff-retract`: asks to remove our newest message for everyone.
    /// - `ff-textsize <points>`: the "Message text size" setting.
    /// - `ff-keys <text>`: types into whatever has the keyboard focus.
    /// - `ff-newchat`, `ff-addcontact`: saves `<name>.newchat.png` or `.addcontact.png`.
    /// - `ff-windows <suffix>`: saves every other visible window (sheets, dialogs).
    /// - `ff-focus`: the composer takes the keyboard; `ff-collapse`: the sidebar collapses;
    ///   `ff-searchall`: ⇧⌘F; `ff-midnight`: the day changes.
    /// - `ff-dump`: saves `<name>.ff.txt`: the newest messages' menus, their actions for
    ///   VoiceOver, the quick switcher's contacts and the open chat's label.
    extension DebugSnapshot {
        /// What `ff-midnight` saw.
        private static var midnight = "-"

        static func performFinalFix(_ parts: [String]) async -> Bool {
            guard let model, let step = parts.first, step.hasPrefix("ff-") else { return false }
            let argument = parts.count > 1 ? parts[1] : ""
            switch step {
            case "ff-avatars": avatars(model)
            case "ff-offer": offer(model)
            case "ff-distrusted": distrusted(model)
            case "ff-reveal":
                if let chatID = model.selection,
                    let id = try? model.database.page(chatID: chatID, before: nil, limit: 50)
                        .last(where: \.isFromDistrustedDevice)?.id
                {
                    transcript?.setDistrustedTextShown(true, messageID: id)
                }
            case "ff-gap": gap(model)
            case "ff-contacts": contacts(model)
            case "ff-private": privateChat(model)
            case "ff-own": own(argument, model: model)
            case "ff-retract": retract(model)
            case "ff-textsize": model.settings.messageTextSize = Double(argument)
            case "ff-keys":
                let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
                (window?.firstResponder as? NSTextView)?.insertText(
                    argument, replacementRange: NSRange(location: NSNotFound, length: 0))
            case "ff-newchat":
                await renderOffscreen(
                    NewChatSheet(model: model) {}, size: NSSize(width: 480, height: 220),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling("newchat"))
            case "ff-addcontact":
                await renderOffscreen(
                    AddContactSheet(model: model) {}, size: NSSize(width: 480, height: 300),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling("addcontact"))
            case "ff-windows": windows(suffix: argument)
            case "ff-focus": composer?.focus()
            case "ff-midnight":
                // The day rows are labelled again when the day changes.
                let before = DaySeparatorView.labelled
                NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
                try? await Task.sleep(for: .milliseconds(300))
                midnight = "day rows labelled again: \(DaySeparatorView.labelled - before)"
            case "ff-collapse": model.sidebarVisible = false
            case "ff-searchall": model.showSearchEverywhere()
            case "ff-dump": await dump(model)
            default: return false
            }
            return true
        }

        // MARK: Data

        private static func chat(_ name: String, in model: AppModel) -> ChatListItem? {
            model.chats.first { $0.displayName == name }
        }

        private static func avatars(_ model: AppModel) {
            let directory = model.services.avatarDirectory
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let pictures: [(String, NSColor, String)] = [
                ("Bob Chen", .systemOrange, "B"), ("Carol Diaz", .systemPurple, "C"),
                ("prosody", .systemTeal, "P"),
            ]
            for (index, (name, color, letter)) in pictures.enumerated() {
                guard let item = chat(name, in: model) else { continue }
                let size = NSSize(width: 128, height: 128)
                let image = NSImage(size: size, flipped: false) { rect in
                    color.setFill()
                    rect.fill()
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 34, y: 54, width: 60, height: 60)).fill()
                    NSBezierPath(ovalIn: NSRect(x: 14, y: -40, width: 100, height: 90)).fill()
                    NSAttributedString(
                        string: letter,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
                            .foregroundColor: color,
                        ]
                    ).draw(at: NSPoint(x: 54, y: 66))
                    return true
                }
                guard let tiff = image.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(
                        using: .png, properties: [:])
                else { continue }
                let hash = "ffavatar\(index)" + String(repeating: "0", count: 32)
                let file = directory.appending(path: hash + ".png")
                try? png.write(to: file)
                try? model.database.storeAvatar(
                    AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: Int64(png.count)))
                try? model.database.showAvatar(
                    accountID: item.chat.accountID, jid: item.chat.jid, hash: hash, own: false)
            }
        }

        private static func offer(_ model: AppModel) {
            guard let item = model.selectedChat else { return }
            let now = Date()
            _ = try? model.database.upsertIncoming(
                IncomingMessage(
                    accountID: item.chat.accountID, chatID: item.id,
                    senderJID: item.chat.jid + "/phone", body: nil, originID: UUID().uuidString,
                    timestamp: now, receivedAt: now, kind: .file,
                    attachments: [
                        AttachmentDraft(
                            mimeType: "application/pdf", byteSize: 2_400_000,
                            fileName: "Quarterly report.pdf", state: .offered)
                    ]))
        }

        private static func distrusted(_ model: AppModel) {
            guard let item = model.selectedChat else { return }
            let now = Date()
            _ = try? model.database.upsertIncoming(
                IncomingMessage(
                    accountID: item.chat.accountID, chatID: item.id,
                    senderJID: item.chat.jid + "/stolen-phone", body: Copy.fromDistrustedDevice,
                    originID: UUID().uuidString, timestamp: now, receivedAt: now,
                    errorText: "Please send me the door code", encryption: .omemo,
                    senderDeviceFingerprint: "05ab12cd34ef", kind: .system))
        }

        /// Two stretches of the open chat's archive with history missing between them: the
        /// gap sits above the middle message of the newest page.
        private static func gap(_ model: AppModel) {
            guard let item = model.selectedChat,
                let page = try? model.database.page(chatID: item.id, before: nil, limit: 12),
                page.count > 4
            else { return }
            let middle = page[page.count / 2]
            let archive = item.isGroup ? item.chat.jid : ChatDisplay.bareJID(item.accountJID)
            try? model.database.recordPage(
                accountID: item.chat.accountID, archive: archive, after: nil, first: "ff-a1",
                last: "ff-a2", startTime: page[0].timestamp,
                endTime: middle.timestamp.addingTimeInterval(-3600))
            try? model.database.recordPage(
                accountID: item.chat.accountID, archive: archive, after: nil, first: "ff-b1",
                last: "ff-b2", startTime: middle.timestamp, endTime: Date())
        }

        private static func contacts(_ model: AppModel) {
            guard let account = model.chats.first?.chat.accountID else { return }
            let existing = (try? model.database.rosterItems(accountID: account)) ?? []
            let added = [("zoe@example.com", "Zoe Quinn"), ("ivan@example.com", nil)].map {
                RosterItemRecord(
                    accountID: account, jid: $0.0, name: $0.1, subscription: "both", ask: nil,
                    approved: false, groups: ["Friends"])
            }
            try? model.database.replaceRoster(
                accountID: account, with: existing + added, version: nil)
        }

        private static func privateChat(_ model: AppModel) {
            guard let room = chat("prosody", in: model),
                let chat = try? model.database.ensureChat(
                    accountID: room.chat.accountID, jid: room.chat.jid + "/romeo",
                    kind: .roomPrivate),
                let chatID = chat.id
            else { return }
            let now = Date()
            _ = try? model.database.upsertIncoming(
                IncomingMessage(
                    accountID: room.chat.accountID, chatID: chatID,
                    senderJID: room.chat.jid + "/romeo", senderNick: "romeo",
                    body: "Can we talk about the release here?", originID: UUID().uuidString,
                    timestamp: now, receivedAt: now))
            model.selection = chatID
        }

        private static func own(_ text: String, model: AppModel) {
            guard let item = model.selectedChat else { return }
            let now = Date()
            let account = model.accounts.first { $0.id == item.chat.accountID }?.jid ?? ""
            _ = try? model.database.upsertIncoming(
                IncomingMessage(
                    accountID: item.chat.accountID, chatID: item.id, direction: .outgoing,
                    senderJID: account, body: text.isEmpty ? "Sent to the wrong chat" : text,
                    archiveID: UUID().uuidString, originID: UUID().uuidString, timestamp: now,
                    receivedAt: now, state: .displayed))
        }

        private static func retract(_ model: AppModel) {
            guard let chatID = model.selection,
                let message = try? model.database.page(chatID: chatID, before: nil, limit: 50)
                    .last(where: { $0.direction == .outgoing && !$0.retracted }),
                let id = message.id
            else { return }
            chatSheets?.retraction = PendingRetraction(
                messageID: id, excerpt: message.body.map(ChatDisplay.quoteExcerpt) ?? Copy.file)
        }

        // MARK: Output

        private static func windows(suffix: String) {
            let main = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
            for (index, window) in NSApp.windows.enumerated()
            where window.isVisible && window !== main {
                guard let view = window.contentView?.superview ?? window.contentView,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                write(
                    rep.representation(using: .png, properties: [:]),
                    to: sibling("window-\(suffix)-\(index)"))
            }
        }

        private static func dump(_ model: AppModel) async {
            var lines: [String] = []
            if let chatID = model.selection, let transcript,
                let page = try? model.database.page(chatID: chatID, before: nil, limit: 30)
            {
                for message in page.suffix(6) {
                    guard let id = message.id else { continue }
                    let titles = transcript.menuItems(forMessage: id).map {
                        $0.isSeparatorItem ? "|" : $0.title
                    }
                    lines.append(
                        "menu \(message.direction) \(message.kind) "
                            + "\"\(message.body ?? "")\": \(titles.joined(separator: ", "))")
                }
            }
            func walk(_ view: NSView) {
                if let cell = view as? MessageCellView {
                    let actions = cell.accessibilityCustomActions()?.map(\.name) ?? []
                    let children = cell.subviews.filter { $0.isAccessibilityElement() }.map {
                        String(describing: type(of: $0))
                    }
                    lines.append(
                        "cell label=\"\(cell.accessibilityLabel() ?? "")\" "
                            + "actions=\(actions) elements=\(children)")
                }
                for subview in view.subviews { walk(subview) }
            }
            if let root = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview {
                walk(root)
            }
            let accounts = model.accounts.filter(\.enabled).compactMap(\.id)
            let chats = Set(
                model.chats.map { SwitcherContact.key($0.chat.accountID, $0.chat.jid) })
            let contacts = await SwitcherContact.withoutChat(
                accounts: accounts, chats: chats, in: model.database)
            let ranked = QuickSwitcherRanking.rank(
                SwitcherEntry.all(chats: model.chats, contacts: contacts), query: "zo",
                limit: 8)
            lines.append("switcher zo: \(ranked.map(\.name))")
            lines.append(
                "open=\(model.openChat?.name ?? "-") label=\(model.openChat?.privateLabel ?? "-")"
                    + " encrypted=\(model.openChat?.encrypted == true)"
                    + " kind=\(model.openChat.map { "\($0.kind)" } ?? "-")")
            lines.append("composer=\(composer?.text ?? "")")
            lines.append("midnight=\(midnight)")
            let responder = NSApp.windows.first { $0.isVisible && $0.contentView != nil }?
                .firstResponder
            lines.append(
                "firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "-")"
                    + " sidebarVisible=\(model.sidebarVisible)")
            lines.append("textsize=\(model.settings.messageTextSize.map { "\($0)" } ?? "system")")
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("ff.txt"))
        }
    }
#endif
