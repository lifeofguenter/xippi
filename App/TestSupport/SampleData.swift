#if DEBUG || UITEST_HOOKS
    import Foundation
    import XippiStore
    import os

    /// Test data for UI tests and screenshots, only when `UITestLaunch` says the UI tests launched
    /// the app. Passwords stay in memory, never in the keychain.
    /// - `-UITestDatabase memory`: an empty in-memory database, with real sessions: accounts
    ///   added in the test connect (to the test servers, with `-UITestCA`).
    /// - `-UITestSeed <count>`: an in-memory database with 3 accounts, 40 chats (people and
    ///   rooms, some pinned, some unread) and `<count>` messages in the room "prosody". "Alice
    ///   Martin" also has a downloaded and a remote attachment, a removed message and a call;
    ///   "xsf" has a system message. The accounts do not exist, so nothing connects and the
    ///   commands only write to the database. `-UITestChats <n>` seeds n chats instead.
    /// - `-UITestDatabaseFile <name>`: the database is a file in the container's temporary
    ///   folder instead. With `-UITestSeed` it is seeded afresh; without, it opens as left;
    ///   with `-UITestDatabaseRemove YES` it is deleted. Nothing connects either way.
    enum SampleData {
        static let bigChatName = "prosody"

        @MainActor static func modelFromLaunchArguments(
            settings: AppSettings, calls: CallCoordinator, idle: IdleMonitor
        ) throws -> AppModel? {
            guard UITestLaunch.isActive else { return nil }
            let seeding = UITestLaunch.seedCount != nil
            let file = UITestLaunch.databaseFile
            let database: AppDatabase
            if let file, UITestLaunch.value("UITestDatabaseRemove") == "YES" {
                // The launch test's last launch: the file goes, the app starts empty.
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: file.path + suffix))
                }
                database = try AppDatabase.inMemory()
            } else if let file {
                // A seed run starts the file afresh; a measured launch opens what it left.
                if seeding {
                    for suffix in ["", "-wal", "-shm"] {
                        try? FileManager.default.removeItem(
                            at: URL(fileURLWithPath: file.path + suffix))
                    }
                }
                database = try AppDatabase.open(at: file)
            } else {
                database = try AppDatabase.inMemory()
            }
            // The seeded accounts do not exist: nothing connects, commands only store.
            let storeOnly = seeding || file != nil
            let services = AccountServices(
                credentials: MemoryCredentials(), systemEvents: AppSystemEvents(),
                notifications: AppNotifications(), extraAnchors: UITestLaunch.extraAnchors,
                connects: !storeOnly,
                mediaDirectory: FileManager.default.temporaryDirectory.appending(
                    path: "Media-\(UUID().uuidString)", directoryHint: .isDirectory))
            let model = AppModel(
                database: database, services: services, settings: settings, calls: calls,
                idle: idle, commands: storeOnly ? StoreOnlyCommands(database: database) : nil)
            if let count = UITestLaunch.seedCount {
                try seedChats(in: database)
                try seedExtras(in: database)
                model.isSeeding = true
                // Seeds the big chat off the main thread; the list updates as it lands.
                Task.detached(priority: .userInitiated) { [weak model] in
                    do {
                        try seedMessages(count, in: database)
                    } catch {
                        appLog.error(
                            "Seeding failed: \(String(describing: error), privacy: .public)")
                    }
                    await MainActor.run { model?.isSeeding = false }
                }
            }
            DebugSnapshot.scheduleIfRequested(model: model)
            return model
        }

        /// Attachments, a removed message and a call in "Alice Martin", a system message in "xsf",
        /// all older than the chats' newest messages.
        private static func seedExtras(in database: AppDatabase) throws {
            guard let account = try database.account(jid: accountJIDs[0]),
                let accountID = account.id,
                let alice = try database.chat(accountID: accountID, jid: "alice@example.com"),
                let aliceID = alice.id,
                let xsf = try database.chat(
                    accountID: accountID, jid: "xsf@conference.example.org"),
                let xsfID = xsf.id
            else { return }
            let notes = FileManager.default.temporaryDirectory.appending(path: "release-notes.txt")
            let text = Data("Release notes\n\nMAM fixes and faster joins.\n".utf8)
            try text.write(to: notes)
            let base = Date().addingTimeInterval(-3 * 3600)
            func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
            let contact = "alice@example.com/phone"
            _ = try database.upsertIncoming([
                IncomingMessage(
                    accountID: accountID, chatID: aliceID, senderJID: contact, body: nil,
                    originID: "x-file", timestamp: at(0), receivedAt: at(0), kind: .file,
                    attachments: [
                        AttachmentDraft(
                            localPath: notes.path, mimeType: "text/plain",
                            byteSize: Int64(text.count), fileName: "release-notes.txt",
                            state: .local)
                    ]),
                IncomingMessage(
                    accountID: accountID, chatID: aliceID, senderJID: contact, body: nil,
                    originID: "x-photo", timestamp: at(1), receivedAt: at(1), kind: .file,
                    attachments: [
                        AttachmentDraft(
                            remoteURL: "https://upload.example.com/x/photo.jpg",
                            mimeType: "image/jpeg",
                            byteSize: 2_400_000, fileName: "photo.jpg")
                    ]),
                IncomingMessage(
                    accountID: accountID, chatID: aliceID, senderJID: contact, body: nil,
                    originID: "x-gone", timestamp: at(2), receivedAt: at(2), retracted: true),
                IncomingMessage(
                    accountID: accountID, chatID: aliceID, senderJID: contact, body: "Audio, 4 min",
                    originID: "x-call", timestamp: at(3), receivedAt: at(3), kind: .callLog),
                IncomingMessage(
                    accountID: accountID, chatID: xsfID, senderJID: nil, body: "carol joined",
                    originID: "x-join", timestamp: at(4), receivedAt: at(4), kind: .system),
            ])
            if let newest = try database.page(chatID: aliceID, before: nil, limit: 1).last?.id {
                try database.markRead(chatID: aliceID, upTo: newest)
            }
        }

        // MARK: Chats

        private struct ChatSpec {
            var name: String
            var local: String
            var kind: ChatKind
            var account: Int
            var pinned = false
            var unread = 0
            var mention = false
            var encrypted = false
            var minutesAgo: Int
        }

        private static let accountJIDs = ["me@xippi.eu", "work@example.org", "test@example.net"]

        private static let people: [(String, String)] = [
            ("Alice Martin", "alice"), ("Bob Chen", "bob"), ("Carol Diaz", "carol"),
            ("Dave Okafor", "dave"), ("Erin Novak", "erin"), ("Frank Weber", "frank"),
            ("Grace Kim", "grace"), ("Henrik Lund", "henrik"), ("Ines Duarte", "ines"),
            ("Jonas Berg", "jonas"), ("Keiko Sato", "keiko"), ("Liam Walsh", "liam"),
            ("Maya Patel", "maya"), ("Nora Haddad", "nora"), ("Omar Farouk", "omar"),
            ("Priya Nair", "priya"), ("Quinn Doyle", "quinn"), ("Rosa Ortega", "rosa"),
            ("Sven Olsen", "sven"), ("Tara Byrne", "tara"), ("Uma Reddy", "uma"),
            ("Victor Hugo", "victor"), ("Wen Li", "wen"), ("Yara Costa", "yara"),
        ]

        private static let rooms = [
            "xsf", "ejabberd", "swift", "jdev", "operators", "conversations", "dino", "gajim",
            "monal", "movim", "snikket", "berlin", "linux", "xmpp-ui", "release",
        ]

        /// `UITestLaunch.chatCount` chats: the big room, the people and rooms above, then
        /// numbered people for any more.
        private static func specs() -> [ChatSpec] {
            let all = baseSpecs()
            let count = UITestLaunch.chatCount
            guard count > all.count else { return Array(all.prefix(count)) }
            return all
                + (all.count..<count).map { index in
                    ChatSpec(
                        name: "Person \(index + 1)", local: "person\(index + 1)", kind: .direct,
                        account: index % 3, minutesAgo: 2_000 + index * 61)
                }
        }

        private static func baseSpecs() -> [ChatSpec] {
            var specs: [ChatSpec] = [
                ChatSpec(
                    name: bigChatName, local: bigChatName, kind: .room, account: 0, pinned: true,
                    unread: 0, minutesAgo: 0)
            ]
            for (index, person) in people.enumerated() {
                specs.append(
                    ChatSpec(
                        name: person.0, local: person.1, kind: .direct, account: index % 3,
                        pinned: index == 1, unread: [2, 5, 9].contains(index) ? index % 4 + 1 : 0,
                        encrypted: index % 2 == 0, minutesAgo: 7 + index * 53))
            }
            for (index, room) in rooms.enumerated() {
                specs.append(
                    ChatSpec(
                        name: room, local: room, kind: .room, account: index % 3,
                        pinned: index == 0, unread: [1, 4, 6].contains(index) ? 3 + index : 0,
                        mention: index == 4, minutesAgo: 30 + index * 97))
            }
            return specs
        }

        private static let directTexts = [
            "Are you around later?", "Sounds good, see you then", "Did the *release* go out?",
            "Sent you the notes: https://example.org/notes", "Thanks!", "I'll check `prosodyctl`",
            "_Maybe_ tomorrow?", "Running a bit late", "~Friday~ Monday works better",
        ]

        private static let roomTexts = [
            "Is 13.1 out yet?", "Yes, since Monday", "The *new* build fixes the MAM bug",
            "Anyone tried `mod_cloud_notify` with this?", "See https://xmpp.org/extensions/",
            "Works for me", "> quoting the spec\nand replying below", "_ping_", "LGTM",
        ]

        private static func seedChats(in database: AppDatabase) throws {
            var accountIDs: [Int64] = []
            for jid in accountJIDs {
                let account = try database.addAccount(
                    AccountRecord(
                        jid: jid, enabled: true, resource: "Xippi", clientID: UUID().uuidString,
                        hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                        pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
                        createdAt: Date()))
                if let id = account.id { accountIDs.append(id) }
            }
            let now = Date()
            for (index, spec) in specs().enumerated() {
                let accountID = accountIDs[spec.account]
                let domain = spec.kind == .direct ? "example.com" : "conference.example.org"
                var chat = try database.ensureChat(
                    accountID: accountID, jid: "\(spec.local)@\(domain)", kind: spec.kind)
                guard let chatID = chat.id else { continue }
                chat.name = spec.kind == .direct ? spec.name : nil
                chat.pinned = spec.pinned
                chat.encryption = spec.encrypted ? .omemo : .none
                chat.nick = spec.kind == .direct ? nil : "me"
                try database.updateChat(chat)
                guard spec.name != bigChatName else { continue }
                let texts = spec.kind == .direct ? directTexts : roomTexts
                let base = now.addingTimeInterval(TimeInterval(-spec.minutesAgo * 60))
                var messages: [IncomingMessage] = []
                let count = max(spec.unread, 2) + 2
                for step in 0..<count {
                    let at = base.addingTimeInterval(TimeInterval((step - count) * 45))
                    let text = texts[(index + step) % texts.count]
                    let incoming = step % 3 != 1
                    messages.append(
                        message(
                            text, at: at, accountID: accountID, chatID: chatID,
                            room: spec.kind == .direct ? nil : "\(spec.local)@\(domain)",
                            from: spec.kind == .direct ? "\(spec.local)@\(domain)" : nil,
                            nick: people[(index + step) % people.count].1, outgoing: !incoming,
                            mention: spec.mention && step == count - 1, id: "\(index)-\(step)"))
                }
                _ = try database.upsertIncoming(messages)
                // Chats without unread messages are read up to their newest message.
                let page = try database.page(chatID: chatID, before: nil, limit: 50)
                if spec.unread == 0, let newest = page.last?.id {
                    try database.markRead(chatID: chatID, upTo: newest)
                } else if page.count > spec.unread {
                    let incoming = page.filter { $0.direction == .incoming }
                    if incoming.count > spec.unread,
                        let lastRead = incoming[incoming.count - spec.unread - 1].id
                    {
                        try database.markRead(chatID: chatID, upTo: lastRead)
                    }
                }
            }
        }

        // MARK: The big chat

        private static let nicks = ["alice", "bob", "carol", "dave", "erin", "lena", "omar"]

        /// `count` messages in "prosody", newest now, with runs from one sender, styling,
        /// replies and reactions. Its own last message is read; the newest few are unread.
        nonisolated static func seedMessages(_ count: Int, in database: AppDatabase) throws {
            guard count > 0,
                let account = try database.account(jid: accountJIDs[0]), let accountID = account.id,
                let chat = try database.chat(
                    accountID: accountID, jid: "\(bigChatName)@conference.example.org"),
                let chatID = chat.id
            else { return }
            let room = chat.jid
            var generator = SplitMix(seed: 0x4A61_6262)
            let now = Date()
            var at = now.addingTimeInterval(-Double(count) * 200)
            var nick = nicks[0]
            var batch: [IncomingMessage] = []
            batch.reserveCapacity(5_000)
            for index in 0..<count {
                let roll = generator.next() % 100
                if roll < 35 { nick = nicks[Int(generator.next() % UInt64(nicks.count))] }
                at = at.addingTimeInterval(roll < 70 ? 40 : Double(120 + generator.next() % 900))
                let outgoing = nick == "omar" && index % 5 == 0
                var text = roomTexts[Int(generator.next() % UInt64(roomTexts.count))]
                if index == count - 2 { text = "Is 13.1 out yet?" }
                if index == count - 1 { text = "Yes, since Monday" }
                var item = message(
                    text, at: min(at, now), accountID: accountID, chatID: chatID, room: room,
                    from: nil, nick: outgoing ? "me" : nick, outgoing: outgoing, mention: false,
                    id: "big-\(index)")
                if index % 17 == 5 {
                    item.replyToSenderLabel = nicks[index % nicks.count]
                    item.replyQuote = "Is 13.1 out yet?"
                }
                if index % 41 == 3 { item.editedAt = item.timestamp.addingTimeInterval(30) }
                batch.append(item)
                if index % 9 == 2 || index == count - 2 {
                    var reaction = message(
                        nil, at: min(at, now), accountID: accountID, chatID: chatID, room: room,
                        from: nil, nick: nicks[(index + 1) % nicks.count], outgoing: false,
                        mention: false, id: "r-\(index)")
                    reaction.reactions = ReactionUpdate(targetID: "big-\(index)", emojis: ["👍"])
                    batch.append(reaction)
                }
                if index == count - 2 {
                    // You and others with more than one emoji: the list of who reacted has tabs.
                    // Not the one who gave 👍: a second reaction would replace theirs.
                    let others = nicks.filter { $0 != nicks[(index + 1) % nicks.count] }
                    let more = [("me", "😂"), (others[0], "😂"), (others[1], "❤️"), (others[2], "😂")]
                    for (who, emoji) in more {
                        var reaction = message(
                            nil, at: min(at, now), accountID: accountID, chatID: chatID,
                            room: room, from: nil, nick: who, outgoing: who == "me",
                            mention: false, id: "r-\(index)-\(who)")
                        reaction.reactions = ReactionUpdate(
                            targetID: "big-\(index)", emojis: [emoji])
                        batch.append(reaction)
                    }
                }
                if batch.count >= 5_000 {
                    _ = try database.upsertIncoming(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { _ = try database.upsertIncoming(batch) }
            // The newest few are unread; `-UITestUnread <n>` leaves n unread instead.
            let unread =
                UITestLaunch.value("UITestUnread").flatMap(Int.init).map { max($0, 1) } ?? 3
            let newest = try database.page(
                chatID: chatID, before: nil, limit: min(unread + 1, 1000))
            if let lastRead = newest.first?.id {
                try database.markRead(chatID: chatID, upTo: lastRead)
            }
        }

        private nonisolated static func message(
            _ text: String?, at date: Date, accountID: Int64, chatID: Int64, room: String?,
            from contact: String?, nick: String, outgoing: Bool, mention: Bool, id: String
        ) -> IncomingMessage {
            let sender: String? =
                if let room { "\(room)/\(nick)" } else if outgoing { accountJIDs[0] } else {
                    contact.map { "\($0)/phone" }
                }
            return IncomingMessage(
                accountID: accountID, chatID: chatID, direction: outgoing ? .outgoing : .incoming,
                senderJID: sender, senderNick: room == nil ? nil : nick,
                occupantID: room == nil ? nil : "occ-\(nick)", body: text, originID: id,
                stanzaMessageID: id, timestamp: date, receivedAt: date, state: .sent,
                mentionsMe: mention)
        }
    }

    /// A small deterministic generator, so every seeded run has the same data.
    private struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
#endif
