#if DEBUG || UITEST_HOOKS
    import AppKit
    import OMEMO
    import SwiftUI
    import XMPPCore
    import XippiSession
    import XippiStore

    /// `-UITestAction` steps for the inspector, rooms, contacts and OMEMO trust (UI test
    /// launches only). The seeded accounts have no session, so these fill the views with
    /// what a session would say:
    /// - `seedroom`: the open room's members (we own it, it supports moderation) and
    ///   `seedcontact`: the open contact's devices (one verified, one new and undecided).
    /// - `seedbigroom <count>`: the open room with that many members; `inspectorscroll`
    ///   scrolls the inspector down and up and puts the time each step took in `bench=`.
    /// - `seednotices <chat>`: three notices "not encrypted for this device" in a row and a
    ///   message under a changed identity, newest in the chat (by its name).
    /// - `inspectorshot <suffix>`: `<name>.inspector-<suffix>.png` of the open chat's inspector.
    /// - `membersshot`, `devicesshot`, `requestsshot`, `bannershot`: those parts on their own.
    /// - `sheetshot <join|create|invite|addcontact|rename|roomsettings>`: that sheet.
    /// - `menutext`: `<name>.menu.txt`, the menu of the newest message of the open chat.
    /// - `moderate`: asks to remove the newest message for everyone (the confirmation).
    /// - `moderatenow`: removes the newest message for everyone as the confirmation would, and
    ///   writes `<name>.moderation.txt` with the composer's error line after it.
    /// - `dialogtext <suffix>`: `<name>.dialog-<suffix>.txt`, the texts and buttons of the
    ///   dialogs on screen, `default` marking the one Return presses.
    extension DebugSnapshot {
        static weak var chatSheets: ChatSheets?
        static weak var chatContext: OpenChatContext?

        static let inspectorSteps: Set<String> = [
            "seedroom", "seedcontact", "seednotices", "inspectorshot", "membersshot",
            "devicesshot", "requestsshot", "bannershot", "sheetshot", "menutext", "moderate",
            "dialogtext", "moderatenow", "seedbigroom", "inspectorscroll",
        ]

        /// `-UITestInspectorSamples 1`: the open chat's inspector shows the sample members
        /// and devices, as a session would, for the UI tests (seeded data has no sessions).
        static var usesInspectorSamples: Bool {
            UITestLaunch.value("UITestInspectorSamples") == "1"
        }

        static func seedSamplesIfAsked(_ context: OpenChatContext, model: AppModel) {
            guard usesInspectorSamples else { return }
            if let room = context.room, room.snapshot == nil {
                room.debugSeed(InspectorSamples.roomSnapshot)
            }
            if let contact = context.contact, contact.identities.isEmpty {
                contact.debugSeed(
                    identities: InspectorSamples.identities(of: contact.jid),
                    own: InspectorSamples.ownIdentities(of: model))
            }
        }

        /// Whether the step was one of these.
        static func performInspector(_ parts: [String]) async -> Bool {
            guard inspectorSteps.contains(parts.first ?? "") else { return false }
            guard let model else { return true }
            let argument = parts.count > 1 ? parts[1] : ""
            let dark = NSApp.effectiveAppearance.isDark
            switch parts.first {
            case "seedroom":
                chatContext?.room?.debugSeed(InspectorSamples.roomSnapshot)
            case "seedbigroom":
                // `seedbigroom <count>`: a room as busy as the big public ones.
                chatContext?.room?.debugSeed(
                    InspectorSamples.bigRoom(Int(argument) ?? 300))
            case "inspectorscroll":
                // Scrolls the inspector down and up in steps, as a trackpad would, drawing each
                // step: `bench=` in the text says how long the steps took.
                benchmarks = await scrollInspector()
            case "seedcontact":
                if let contact = chatContext?.contact {
                    contact.debugSeed(
                        identities: InspectorSamples.identities(of: contact.jid),
                        own: InspectorSamples.ownIdentities(of: model))
                }
            case "seednotices":
                await seedNotices(chatName: argument, model: model)
            case "inspectorshot":
                guard let sheets = chatSheets, let context = chatContext else { return true }
                await renderOffscreen(
                    InspectorView(
                        model: model, info: model.openChat, context: context, sheets: sheets),
                    size: NSSize(width: 320, height: 1800), dark: dark,
                    to: sibling("inspector-\(argument)"))
            case "membersshot":
                await renderOffscreen(
                    MemberList(
                        members: InspectorSamples.roomSnapshot.members,
                        details: InspectorSamples.roomSnapshot.details, onAction: { _, _ in }
                    ).padding(16),
                    size: NSSize(width: 320, height: 420), dark: dark, to: sibling("members"))
            case "devicesshot":
                guard let jid = try? JID("alice@example.com") else { return true }
                let identities = InspectorSamples.identities(of: jid)
                await renderOffscreen(
                    EncryptionDevicesView(
                        name: "Alice Martin",
                        identities: identities,
                        ownIdentities: InspectorSamples.ownIdentities(of: model),
                        isVerified: OMEMOTrustSummary.isVerified(identities),
                        onTrust: { _, _ in }, onReset: {}
                    ).padding(16),
                    size: NSSize(width: 320, height: 1100), dark: dark, to: sibling("devices"))
            case "requestsshot":
                await renderRequests(model: model, dark: dark)
            case "bannershot":
                guard let info = model.openChat, let context = chatContext else { return true }
                await renderOffscreen(
                    ChatBanners(
                        model: model, info: info, context: context,
                        notice: info.isGroup ? .noLongerExists : nil),
                    size: NSSize(width: 640, height: 120), dark: dark, to: sibling("banner"))
            case "sheetshot":
                await renderSheet(argument, model: model, dark: dark)
            case "menutext":
                writeMenu(model: model)
            case "moderate":
                guard let chatID = model.selection,
                    let newest = try? model.database.page(chatID: chatID, before: nil, limit: 1)
                        .last, let id = newest.id
                else { return true }
                chatSheets?.moderation = PendingModeration(
                    messageID: id, chatID: chatID, sender: newest.senderNick ?? "")
            case "dialogtext":
                writeDialogs(suffix: argument)
            case "moderatenow":
                guard let chatID = model.selection, let room = chatContext?.room,
                    let newest = try? model.database.page(chatID: chatID, before: nil, limit: 1)
                        .last, let id = newest.id
                else { return true }
                let show = chatContext?.showError
                room.moderate(messageID: id) { show?($0) }
                try? await Task.sleep(for: .seconds(1.5))
                write(
                    "composerError=\(composer?.error ?? "none")".data(using: .utf8),
                    to: outputURL.deletingPathExtension().appendingPathExtension(
                        "moderation.txt"))
            default:
                break
            }
            return true
        }

        /// Every dialog's texts and buttons, as the window server has them.
        private static func writeDialogs(suffix: String) {
            var lines: [String] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.title.isEmpty {
                    let isDefault = button.keyEquivalent == "\r"
                    lines.append("button \(button.title)\(isDefault ? " default" : "")")
                } else if let field = view as? NSTextField, !field.stringValue.isEmpty {
                    lines.append("text \(field.stringValue)")
                }
                for subview in view.subviews { walk(subview) }
            }
            for window in NSApp.windows where window.isVisible {
                for sheet in [window.attachedSheet].compactMap({ $0 }) + [window]
                where sheet is NSPanel || sheet.className.contains("Alert") {
                    lines.append("dialog \(sheet.className)")
                    if let view = sheet.contentView { walk(view) }
                }
            }
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension(
                    "dialog-\(suffix).txt"))
        }

        private static func renderSheet(_ name: String, model: AppModel, dark: Bool) async {
            let size = NSSize(width: 480, height: 560)
            let url = sibling("sheet-\(name)")
            switch name {
            case "join":
                await renderOffscreen(
                    JoinRoomSheet(model: model, onClose: {}), size: size, dark: dark, to: url)
            case "create":
                await renderOffscreen(
                    CreateRoomSheet(model: model, onClose: {}), size: size, dark: dark, to: url)
            case "invite":
                guard let chatID = model.selection else { return }
                await renderOffscreen(
                    InviteSheet(model: model, chatID: chatID, onClose: {}), size: size,
                    dark: dark, to: url)
            case "addcontact":
                await renderOffscreen(
                    AddContactSheet(model: model, onClose: {}), size: size, dark: dark, to: url)
            case "rename":
                guard let contact = chatContext?.contact else { return }
                await renderOffscreen(
                    RenameContactSheet(model: model, contact: contact, onClose: {}),
                    size: NSSize(width: 480, height: 300), dark: dark, to: url)
            case "roomsettings":
                await renderOffscreen(
                    DataFormView(
                        form: InspectorSamples.roomConfiguration, submitTitle: Copy.saveChanges,
                        actions: [FormAction(id: "cancel", title: Copy.cancel) {}],
                        onSubmit: { _ in }),
                    size: NSSize(width: 520, height: 640), dark: dark, to: url)
            default:
                break
            }
        }

        private static func renderRequests(model: AppModel, dark: Bool) async {
            guard let accountID = model.accounts.first?.id,
                let room = try? JID("release@conference.example.org"),
                let other = try? JID("party@muc.example.net"),
                let bob = try? JID("bob@example.com"),
                let mallory = try? JID("mallory@example.net")
            else { return }
            let rows = VStack(alignment: .leading, spacing: 12) {
                SectionTitle(Copy.requests)
                InvitationRow(
                    model: model,
                    entry: RoomInvitationsModel.Entry(
                        accountID: accountID,
                        invitation: RoomInvitation(
                            room: room, inviter: bob, inviterConfirmed: true,
                            reason: "Release review at 3", isDirect: true, receivedAt: Date())))
                InvitationRow(
                    model: model,
                    entry: RoomInvitationsModel.Entry(
                        accountID: accountID,
                        invitation: RoomInvitation(
                            room: other, inviter: mallory, inviterConfirmed: false,
                            isDirect: false, receivedAt: Date())))
                SubscriptionRequestRow(
                    model: model,
                    request: SubscriptionRequest(accountID: accountID, jid: "carol@example.org"))
            }
            .padding(16)
            await renderOffscreen(
                rows, size: NSSize(width: 300, height: 520), dark: dark, to: sibling("requests"))
        }

        /// Three notices in a row and a message read under a changed identity, newest.
        private static func seedNotices(chatName: String, model: AppModel) async {
            guard let item = model.chats.first(where: { $0.displayName == chatName }) else {
                return
            }
            let chat = item.chat
            let now = Date()
            var rows: [IncomingMessage] = (0..<3).map { index in
                IncomingMessage(
                    accountID: chat.accountID, chatID: item.id, senderJID: "\(chat.jid)/phone",
                    body: "Not encrypted for this device", originID: "notice-\(index)",
                    timestamp: now.addingTimeInterval(Double(index)),
                    receivedAt: now.addingTimeInterval(Double(index)), encryption: .omemo,
                    kind: .system)
            }
            rows.append(
                IncomingMessage(
                    accountID: chat.accountID, chatID: item.id, senderJID: "\(chat.jid)/phone",
                    body: "New phone, same me", archiveID: "archived-identity",
                    originID: "identity-changed",
                    timestamp: now.addingTimeInterval(5), receivedAt: now.addingTimeInterval(5),
                    encryption: .omemo, identityChanged: true))
            _ = try? model.database.upsertIncoming(rows)
        }

        private static func writeMenu(model: AppModel) {
            guard let chatID = model.selection, let transcript,
                let newest = try? model.database.page(chatID: chatID, before: nil, limit: 1).last,
                let id = newest.id
            else { return }
            let titles = transcript.menuItems(forMessage: id).map(\.title)
            write(
                titles.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("menu.txt"))
        }
    }

    extension DebugSnapshot {
        /// The inspector's scroll view: the one at the window's right end.
        static func scrollInspector() async -> String {
            guard
                let window = NSApp.windows.filter({ $0.isVisible })
                    .max(by: { $0.frame.width < $1.frame.width }),
                let content = window.contentView
            else { return "no window" }
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            guard
                let scroll = scrollViews(content)
                    .filter({ $0.convert($0.bounds, to: nil).minX > window.frame.width * 0.6 })
                    .max(by: {
                        ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
                    })
            else { return "no inspector" }
            var steps: [Double] = []
            let height = scroll.documentView?.frame.height ?? 0
            let clip = scroll.contentView
            for direction in [1.0, -1.0] {
                for _ in 0..<120 {
                    let start = ContinuousClock.now
                    var origin = clip.bounds.origin
                    origin.y = min(
                        max(origin.y + 40 * direction, 0), max(height - clip.bounds.height, 0))
                    clip.scroll(to: origin)
                    scroll.reflectScrolledClipView(clip)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    steps.append((ContinuousClock.now - start) / .milliseconds(1))
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            let sorted = steps.sorted()
            let total = steps.reduce(0, +)
            return String(
                format:
                    "inspectorScroll height=%.0f steps=%d total=%.0fms mean=%.1fms p90=%.1fms max=%.1fms",
                height, steps.count, total, total / Double(steps.count),
                sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0)
        }
    }

    /// What the inspector's views show in the snapshots.
    enum InspectorSamples {
        /// `count` members, mostly participants, as a big public room has them.
        static func bigRoom(_ count: Int) -> RoomSnapshot {
            let shows: [Presence.Show?] = [nil, nil, .away, .xa, .dnd, nil]
            return RoomSnapshot(
                details: roomSnapshot.details,
                members: (0..<count).map { index in
                    member(
                        "user\(index)",
                        role: index < 5 ? .moderator : (index % 9 == 0 ? .visitor : .participant),
                        affiliation: index < 3
                            ? .owner : (index % 4 == 0 ? .member : MUCPresence.Affiliation.none),
                        jid: index % 2 == 0 ? "user\(index)@example\(index % 7).org" : nil,
                        show: shows[index % shows.count],
                        status: index % 5 == 0 ? "Status line of user \(index)" : nil,
                        self: index == 0)
                })
        }

        static let roomSnapshot = RoomSnapshot(
            details: RoomDetails(
                ownRole: .moderator, ownAffiliation: .owner, ownNick: "me",
                supportsModeration: true, isMembersOnly: true, isNonAnonymous: true),
            members: [
                member(
                    "me", role: .moderator, affiliation: .owner, jid: "me@xippi.eu", self: true),
                member("bob", role: .moderator, affiliation: .admin, jid: "bob@example.com"),
                member(
                    "carol", role: .participant, affiliation: .member, jid: "carol@example.org",
                    show: .away, status: "Back at 3"),
                member(
                    "dave", role: .participant, affiliation: MUCPresence.Affiliation.none,
                    jid: "dave@example.net"),
                // Known only by nickname: no address and no occupant id (R72).
                member(
                    "erin", role: .visitor, affiliation: MUCPresence.Affiliation.none, jid: nil,
                    show: .dnd, occupantID: false),
            ])

        private static func member(
            _ nick: String, role: MUCPresence.Role, affiliation: MUCPresence.Affiliation,
            jid: String?, show: Presence.Show? = nil, status: String? = nil,
            self isSelf: Bool = false, occupantID: Bool = true
        ) -> RoomMember {
            RoomMember(
                nick: nick, occupantID: occupantID ? "occ-\(nick)" : nil,
                realJID: jid.flatMap { try? JID($0) },
                role: role, affiliation: affiliation, show: show, status: status, isSelf: isSelf)
        }

        private static let fingerprints = [
            "05a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f",
            "7c1d9e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d",
            "e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4",
            "9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b",
            "1234abcd5678ef901234abcd5678ef901234abcd5678ef901234abcd5678ef90",
        ]

        /// One identity per key, as the engine keeps trust for them: a verified device in
        /// both versions, a new one, a stale legacy one, a distrusted one, and a device whose
        /// key nobody has shown yet.
        static func identities(of jid: JID) -> [OMEMOIdentityInfo] {
            let now = Date()
            func identity(
                _ index: Int?, _ trust: DeviceTrust, _ devices: [OMEMO.OMEMOVersion: [UInt32]],
                active: Bool = true, stale: Bool = false, seen: Date? = nil
            ) -> OMEMOIdentityInfo {
                OMEMOIdentityInfo(
                    jid: jid, identityKey: index.map { Data(repeating: UInt8($0 + 1), count: 32) },
                    fingerprint: index.map { fingerprints[$0] }, trust: trust,
                    deviceIDs: devices, isActive: active, isStale: stale, isThisDevice: false,
                    lastSeen: seen)
            }
            return [
                identity(
                    0, .verified, [.v2: [1_001], .v03: [1_001]],
                    seen: now.addingTimeInterval(-7200)),
                identity(1, .undecided, [.v2: [2_002]]),
                identity(
                    2, .trusted, [.v03: [3_003]], stale: true,
                    seen: now.addingTimeInterval(-100 * 86400)),
                identity(3, .distrusted, [.v03: [4_004]], active: false),
                identity(nil, .undecided, [.v2: [6_006]]),
            ]
        }

        @MainActor static func ownIdentities(of model: AppModel) -> [OMEMOIdentityInfo] {
            guard let jid = model.accounts.first.flatMap({ try? JID($0.jid) }) else { return [] }
            return [
                OMEMOIdentityInfo(
                    jid: jid, identityKey: nil, fingerprint: fingerprints[4], trust: .verified,
                    deviceIDs: [.v2: [5_005], .v03: [5_005]], isActive: true, isStale: false,
                    isThisDevice: true, lastSeen: nil)
            ]
        }

        /// A room configuration form as Prosody sends it, shortened.
        static let roomConfiguration = DataForm(
            type: .form, title: "Configuration for release@conference.example.org",
            fields: [
                DataForm.Field(
                    variable: "FORM_TYPE", type: .hidden,
                    values: ["http://jabber.org/protocol/muc#roomconfig"]),
                DataForm.Field(
                    variable: "muc#roomconfig_roomname", type: .textSingle, label: "Title",
                    values: ["Release"]),
                DataForm.Field(
                    variable: "muc#roomconfig_roomdesc", type: .textSingle,
                    label: "Description"),
                DataForm.Field(
                    variable: "muc#roomconfig_persistentroom", type: .boolean,
                    label: "Persistent (room should remain even when it is empty)",
                    values: ["1"]),
                DataForm.Field(
                    variable: "muc#roomconfig_membersonly", type: .boolean,
                    label: "Only allow members to join", values: ["1"]),
                DataForm.Field(
                    variable: "muc#roomconfig_whois", type: .listSingle,
                    label: "Addresses (JIDs) of room occupants may be viewed by:",
                    values: ["anyone"],
                    options: [
                        DataForm.Option(label: "Moderators only", value: "moderators"),
                        DataForm.Option(label: "Anyone", value: "anyone"),
                    ]),
            ])
    }
#endif
