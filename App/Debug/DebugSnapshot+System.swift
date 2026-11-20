#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import UserNotifications
    import XMPPCore
    import XippiSession
    import XippiStore
    import os

    /// `-UITestAction` steps for notifications, links, status, the menu bar and the Dock:
    /// - `uri <link>`: handles an `xmpp:` link as one opened from outside; `linkconfirm`:
    ///   confirms the link sheet as shown; `urishot <suffix>`: saves the link sheet and
    ///   `<name>.links-<suffix>.txt` (the request, the open chat, the composer, the account
    ///   sheet).
    /// - `sendas <account> <contact> <text>`: that account sends a message to the contact.
    /// - `notifyaction <action> <chat> [text]`: answers the newest notification of the chat
    ///   (by its name) as a click would: `reply`, `mark-read` or `open`.
    /// - `fakeincoming <chat>`: a message for the chat (by its name) handed to the
    ///   notifications as the sessions would, without storing it.
    /// - `notifyclear`: takes every notification of the app off the screen and out of
    ///   Notification Center (after a check).
    /// - `notifyshot <suffix>`: `<name>.notifications-<suffix>.txt` with every decision, what
    ///   is on screen, the permission, the Dock badge and the unread count.
    /// - `status <available|away|doNotDisturb> [message]`: every account's status;
    ///   `statusshot <suffix>`: saves the status window and the footer's account list, and
    ///   `<name>.status-<suffix>.txt` with the statuses, the presence sent and the menu.
    /// - `windows`: lists the windows' identifiers in the notifications text.
    extension DebugSnapshot {
        static weak var notifications: NotificationController?
        static weak var links: XMPPURIHandler?

        static func performSystem(_ parts: [String]) async {
            guard let model else { return }
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "uri":
                guard let url = URL(string: argument) else { return }
                await links?.handle(url)
            case "linkconfirm":
                guard let links, let request = links.request else { return }
                var fields = URIFields(request.intent)
                if case .joinRoom = request.intent, fields.nick.isEmpty {
                    fields.nick = links.defaultNick(for: request, account: request.account)
                }
                linkResult =
                    await links.confirm(request, account: request.account, fields: fields)
                    ?? "done"
            case "urishot":
                await linkShot(argument, model: model)
            case "sendas":
                await sendAs(argument.split(separator: " ", maxSplits: 2).map(String.init), model)
            case "notifyaction":
                let words = argument.split(separator: " ", maxSplits: 2).map(String.init)
                guard words.count > 1,
                    let chat = model.chats.first(where: { $0.displayName == words[1] })
                else { return }
                let action =
                    switch words[0] {
                    case "reply": NotificationController.Action.reply
                    case "mark-read": NotificationController.Action.markRead
                    default: UNNotificationDefaultActionIdentifier
                    }
                let newest = try? model.database.page(chatID: chat.id, before: nil, limit: 1)
                    .last?.id
                await notifications?.debugRespond(
                    action: action, chatID: chat.id, messageID: newest,
                    text: words.count > 2 ? words[2] : nil)
            case "fakeincoming":
                // `fakeincoming <chat>`: a message in that chat as the sessions would hand it
                // over (not stored), to see the decision for an open or a closed chat.
                guard let item = model.chats.first(where: { $0.displayName == argument }) else {
                    return
                }
                let message = MessageRecord(
                    id: 9_000_000 + item.id, accountID: item.chat.accountID, chatID: item.id,
                    direction: .incoming, senderJID: item.chat.jid, senderNick: nil,
                    occupantID: nil, body: "Test", archiveID: nil, originID: nil,
                    stanzaMessageID: nil, timestamp: Date(), receivedAt: Date(), state: .sent,
                    errorText: nil, encryption: item.chat.encryption, senderDeviceFingerprint: nil,
                    replyToMessageID: nil, replyToSenderLabel: nil, replyQuote: nil,
                    editedAt: nil, retracted: false, moderatedBy: nil, moderationReason: nil,
                    kind: .text)
                var chat = item.chat
                chat.notify = .all
                await notifications?.messageArrived(
                    message, in: chat, senderIsContact: true, notifyUnknownSenders: false)
            case "notifyclear":
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            case "notifyshot":
                notificationShot(argument, model: model)
            case "status":
                let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard let show = UserStatus.Show(rawValue: words.first ?? "") else { return }
                for account in model.accounts {
                    model.userStatus.set(
                        UserStatus(show: show, message: words.count > 1 ? words[1] : nil),
                        for: account)
                }
            case "statusshot":
                await statusShot(argument, model: model)
            default:
                // Account settings: see `DebugSnapshot+Settings.swift`.
                await performSettings(parts)
            }
        }

        private static var linkResult: String?

        private static func linkShot(_ suffix: String, model: AppModel) async {
            let dark = NSApp.effectiveAppearance.isDark
            if let links, let request = links.request {
                await renderOffscreen(
                    URIActionSheet(handler: links, request: request, accounts: model.accounts),
                    size: NSSize(width: 460, height: 340), dark: dark,
                    to: sibling("link-\(suffix)"))
            }
            var lines: [String] = []
            if let request = links?.request {
                lines.append(
                    "request intent=\(request.intent) accounts=\(request.accounts)"
                        + " account=\(request.account)")
            } else {
                lines.append("request -")
            }
            lines.append("result=\(linkResult ?? "-")")
            lines.append("open=\(model.openChat?.jid ?? "-") name=\(model.openChat?.name ?? "-")")
            lines.append("composer=\(composer?.text ?? "-")")
            lines.append("onboarding=\(model.onboarding.map(\.id) ?? "-")")
            lines.append("rooms=\(model.status.rooms.mapValues { "\($0)" })")
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("links-\(suffix).txt"))
        }

        /// `<account> <contact> <text>`: the account sends the text to the contact.
        private static func sendAs(_ words: [String], _ model: AppModel) async {
            guard words.count > 2,
                let account = model.accounts.first(where: { $0.jid == words[0] }),
                let id = account.id, let session = await model.sessions.session(for: id),
                let contact = try? JID(words[1]),
                let chatID = try? model.database.ensureChat(
                    accountID: id, jid: contact.bare.description, kind: .direct
                ).id
            else { return }
            do {
                try await session.send(text: words[2], chatID: chatID, replyTo: nil)
            } catch {
                appLog.error("Debug send failed: \(String(describing: error), privacy: .public)")
            }
        }

        private static func notificationShot(_ suffix: String, model: AppModel) {
            var lines = notifications?.log ?? ["no controller"]
            lines.append("delivered=\(notifications?.deliveredIdentifiers ?? [])")
            lines.append("authorization=\(notifications?.authorization.rawValue ?? -1)")
            lines.append(
                "badge=\(NSApp.dockTile.badgeLabel ?? "-") unread=\(model.dockBadge.unread)")
            lines.append(
                "open=\(model.openChat?.jid ?? "-") active=\(NSApp.isActive)"
                    + " front=\(MainWindowPresenter.isInFront) filter=\(model.sidebarFilter)"
                    + " inspector=\(model.inspectorVisible)")
            lines.append(
                "chats="
                    + model.chats.map {
                        "\($0.displayName):\($0.chat.unreadCount)/\($0.chat.lastReadMessageID ?? 0)"
                    }.joined(separator: ","))
            lines.append(
                "windows="
                    + NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")/\($0.isVisible)" }
                    .joined(separator: ","))
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension(
                    "notifications-\(suffix).txt"))
        }

        private static func statusShot(_ suffix: String, model: AppModel) async {
            let dark = NSApp.effectiveAppearance.isDark
            await renderOffscreen(
                StatusWindow(model: model), size: NSSize(width: 440, height: 260), dark: dark,
                to: sibling("status-\(suffix)"))
            await renderOffscreen(
                VStack(spacing: 0) {
                    AccountStatusFooter(model: model)
                    Divider()
                    AccountStatusList(model: model)
                    Spacer(minLength: 0)
                },
                size: NSSize(width: 360, height: 340), dark: dark,
                to: sibling("status-footer-\(suffix)"))
            var lines: [String] = []
            for account in model.accounts {
                let status = model.userStatus.status(of: account)
                lines.append(
                    "account \(account.jid) show=\(status.show) message=\(status.message ?? "-")")
            }
            // What the other accounts see of each other: the presence the server passed on.
            for (key, summary) in model.status.presence.sorted(by: { $0.key.jid < $1.key.jid }) {
                lines.append(
                    "seen by \(key.accountID): \(key.jid) \(summary.availability)"
                        + " status=\(summary.status ?? "-")")
            }
            lines.append(
                "menu unread=\(model.dockBadge.unread)"
                    + " common=\(model.userStatus.commonShow(of: model.accounts).map { "\($0)" } ?? "mixed")"
                    + " lines="
                    + model.accounts.map { Copy.accountLine($0.jid, model.status(of: $0)) }
                    .joined(separator: " | "))
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("status-\(suffix).txt")
            )
        }
    }
#endif
