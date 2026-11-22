#if DEBUG || UITEST_HOOKS
    import AVFoundation
    import AppKit
    import XippiStore

    /// The chats the App Store screenshots show (`-UITestSeed store`, `make screenshots`): three
    /// accounts with friends, family and a team. The photos are the ones
    /// `scripts/screenshots/shoot.py` copies into the container's `StorePhotos` folder; a
    /// missing one leaves its message out. Times are today's, fixed, so every run looks the same.
    enum StoreSample {
        static let accounts = ["sam@xippi.eu", "sam@studio.example", "sam@home.arpa"]
        static let nick = "Sam"

        static var photos: URL {
            FileManager.default.temporaryDirectory.appending(
                path: "StorePhotos", directoryHint: .isDirectory)
        }

        static func photo(_ name: String) -> URL? {
            let url = photos.appending(path: "\(name).jpg")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        /// A message: `from` is a room nick or, in a direct chat, any name for the contact; nil
        /// is the user.
        struct Line {
            var at: String
            var day = 0
            var from: String?
            var text: String?
            var photo: String?
            var file: String?
            var voice = false
            var reply: (to: String, quote: String)?
            var reactions: [(from: String?, emojis: [String])] = []
            var edited = false
            var mention = false
        }

        struct Chat {
            var name: String
            var jid: String
            var kind: ChatKind
            var account: Int
            var pinned = false
            var encrypted = false
            var unread = 0
            var lines: [Line]
        }

        static func seed(in database: AppDatabase) throws {
            var accountIDs: [Int64] = []
            for jid in accounts {
                let account = try database.addAccount(
                    AccountRecord(
                        jid: jid, enabled: true, resource: "Xippi", clientID: UUID().uuidString,
                        hostOverride: nil, portOverride: nil, directTLSOverride: nil,
                        pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
                        createdAt: Date()))
                if let id = account.id { accountIDs.append(id) }
            }
            for (index, spec) in chats.enumerated() {
                try seed(spec, index: index, accountID: accountIDs[spec.account], in: database)
            }
        }

        private static func seed(
            _ spec: Chat, index: Int, accountID: Int64, in database: AppDatabase
        )
            throws
        {
            var chat = try database.ensureChat(accountID: accountID, jid: spec.jid, kind: spec.kind)
            guard let chatID = chat.id else { return }
            chat.name = spec.name
            chat.pinned = spec.pinned
            chat.encryption = spec.encrypted ? .omemo : .none
            chat.nick = spec.kind == .room ? nick : nil
            try database.updateChat(chat)
            let room = spec.kind == .room
            let me = accounts[spec.account]
            func sender(_ from: String?) -> String {
                if room { return "\(spec.jid)/\(from ?? nick)" }
                return from == nil ? me : "\(spec.jid)/phone"
            }
            var messages: [IncomingMessage] = []
            for (number, line) in spec.lines.enumerated() {
                let id = "store-\(index)-\(number)"
                let at = time(line.at, daysAgo: line.day)
                var attachments: [AttachmentDraft] = []
                if let name = line.photo {
                    guard let url = photo(name) else { continue }
                    attachments.append(draft(url, mime: "image/jpeg", name: "IMG_\(name).jpg"))
                }
                if let name = line.file, let url = document(name) {
                    attachments.append(draft(url, mime: "application/pdf", name: name))
                }
                if line.voice, let url = voice() {
                    attachments.append(draft(url, mime: "audio/mp4", name: "Voice message.m4a"))
                }
                messages.append(
                    IncomingMessage(
                        accountID: accountID, chatID: chatID,
                        direction: line.from == nil ? .outgoing : .incoming,
                        senderJID: sender(line.from), senderNick: room ? line.from ?? nick : nil,
                        occupantID: room ? "occ-\(line.from ?? nick)" : nil,
                        body: attachments.isEmpty ? line.text : nil, originID: id,
                        stanzaMessageID: id, timestamp: at, receivedAt: at, state: .sent,
                        encryption: spec.encrypted ? .omemo : .none,
                        replyToSenderLabel: line.reply?.to, replyQuote: line.reply?.quote,
                        editedAt: line.edited ? at.addingTimeInterval(40) : nil,
                        kind: attachments.isEmpty ? .text : .file, mentionsMe: line.mention,
                        attachments: attachments))
                for (who, reaction) in line.reactions.enumerated() {
                    var update = IncomingMessage(
                        accountID: accountID, chatID: chatID,
                        direction: reaction.from == nil ? .outgoing : .incoming,
                        senderJID: sender(reaction.from),
                        senderNick: room ? reaction.from ?? nick : nil,
                        occupantID: room ? "occ-\(reaction.from ?? nick)" : nil, body: nil,
                        originID: "\(id)-r\(who)", stanzaMessageID: "\(id)-r\(who)",
                        timestamp: at.addingTimeInterval(30), receivedAt: at.addingTimeInterval(30))
                    update.reactions = ReactionUpdate(targetID: id, emojis: reaction.emojis)
                    messages.append(update)
                }
            }
            _ = try database.upsertIncoming(messages)
            // Read up to the newest message, or up to the one before the unread ones.
            let page = try database.page(chatID: chatID, before: nil, limit: 100)
            let incoming = page.filter { $0.direction == .incoming }
            if spec.unread == 0, let newest = page.last?.id {
                try database.markRead(chatID: chatID, upTo: newest)
            } else if incoming.count > spec.unread,
                let lastRead = incoming[incoming.count - spec.unread - 1].id
            {
                try database.markRead(chatID: chatID, upTo: lastRead)
            }
        }

        /// Today (or that many days before) at `hh:mm`.
        static func time(_ text: String, daysAgo: Int) -> Date {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return calendar.date(
                bySettingHour: parts.first ?? 9, minute: parts.last ?? 41, second: 0, of: day)
                ?? day
        }

        private static func draft(_ url: URL, mime: String, name: String) -> AttachmentDraft {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return AttachmentDraft(
                localPath: url.path, mimeType: mime, byteSize: size, fileName: name,
                state: .local)
        }

        // MARK: Files

        private static var files: URL {
            let folder = FileManager.default.temporaryDirectory.appending(
                path: "StoreFiles", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        /// A one-page PDF with its name as the title.
        private static func document(_ name: String) -> URL? {
            let url = files.appending(path: name)
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let title = (name as NSString).deletingPathExtension
            NSAttributedString(
                string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]
            ).draw(at: NSPoint(x: 60, y: 760))
            for row in 0..<24 {
                NSColor(white: 0.85, alpha: 1).setFill()
                NSRect(x: 60, y: 700 - row * 24, width: row % 5 == 4 ? 300 : 475, height: 8).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            return url
        }

        /// Twelve seconds that rise and fall like speech, as the recorder writes it.
        private static func voice() -> URL? {
            let url = files.appending(path: "voice.m4a")
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let rate = 22_050.0
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
            ]
            let frames = AVAudioFrameCount(rate * 12)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                let channel = buffer.floatChannelData?[0]
            else { return nil }
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                let t = Double(index) / rate
                let syllables =
                    abs(sin(2 * .pi * 2.3 * t)) * (0.55 + 0.45 * sin(2 * .pi * 0.31 * t))
                let tone = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 360 * t)
                channel[index] = Float(0.25 * syllables * tone)
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings)
                try file.write(from: buffer)
            } catch {
                return nil
            }
            return url
        }

        // MARK: Chats

        static let chats: [Chat] = [
            Chat(
                name: "Weekend in the Alps", jid: "alps@conference.xippi.eu", kind: .room,
                account: 0, pinned: true,
                lines: [
                    Line(at: "07:58", from: "Bob", text: "Who's up already?"),
                    Line(
                        at: "08:12", from: "Lena",
                        text: "Made it to the hut. The view this morning:"),
                    Line(
                        at: "08:12", from: "Lena", photo: "matterhorn",
                        reactions: [
                            ("Omar", ["😍"]), ("Alice", ["😍", "🙌"]), ("Bob", ["😍"]), (nil, ["😍"]),
                        ]),
                    Line(at: "08:20", from: "Omar", text: "Meanwhile, my office today"),
                    Line(
                        at: "08:20", from: "Omar", photo: "canoe",
                        reactions: [
                            ("Lena", ["😂"]), ("Alice", ["😂", "❤️"]), (nil, ["😂"]), ("Bob", ["❤️"]),
                        ]),
                    Line(at: "08:33", text: "On the 4 o'clock train 🚆 bringing the good coffee"),
                    Line(
                        at: "09:41", from: "Lena", text: "Sam, don't forget the crampons!",
                        mention: true),
                ]),
            Chat(
                name: "Alice Martin", jid: "alice@example.com", kind: .direct, account: 0,
                pinned: true, encrypted: true,
                lines: [
                    Line(at: "18:30", day: 1, from: "Alice", text: "Are we still on for Saturday?"),
                    Line(at: "18:34", day: 1, text: "Yes! 10 at the station"),
                    Line(at: "08:58", from: "Alice", text: "Could you send me the signed lease?"),
                    Line(at: "09:02", file: "Lease agreement.pdf"),
                    Line(at: "09:03", text: "Signed on my side. The deposit goes out Monday."),
                    Line(
                        at: "09:10", from: "Alice",
                        text: "Perfect, thank you! Keys are with the neighbour 🔑"),
                    Line(at: "09:11", from: "Alice", photo: "croissant", reactions: [(nil, ["😍"])]),
                    Line(at: "09:12", from: "Alice", text: "Celebrating with breakfast"),
                ]),
            Chat(
                name: "Design team", jid: "design@conference.studio.example", kind: .room,
                account: 1, unread: 2,
                lines: [
                    Line(
                        at: "09:05", from: "Grace",
                        text: "New onboarding flow is up for review. Comments welcome!"),
                    Line(
                        at: "09:12", from: "Henrik",
                        text: "Love it. Can we try the button in pink?",
                        reply: ("Grace", "New onboarding flow is up for review. Comments welcome!"),
                        reactions: [("Grace", ["👍"]), ("Priya", ["👍"]), (nil, ["💯"])],
                        edited: true),
                    Line(at: "09:14", from: "Priya", text: "QA is in progress"),
                    Line(
                        at: "09:14", from: "Priya", photo: "cat",
                        reactions: [("Grace", ["😂"]), ("Henrik", ["😂"]), (nil, ["😂", "❤️"])]),
                    Line(
                        at: "09:30", from: "Grace", text: "Sam, can you check the copy on step 2?",
                        mention: true),
                ]),
            Chat(
                name: "Carol Diaz", jid: "carol@xippi.eu", kind: .direct, account: 0,
                encrypted: true,
                lines: [
                    Line(at: "21:10", day: 1, text: "Have the best trip!"),
                    Line(at: "21:12", day: 1, from: "Carol", text: "Thank you!! ✈️"),
                    Line(at: "09:02", from: "Carol", text: "Lisbon says hi! 🚋"),
                    Line(at: "09:02", from: "Carol", photo: "tram"),
                    Line(at: "09:03", from: "Carol", photo: "beach", reactions: [(nil, ["😍"])]),
                    Line(at: "09:10", voice: true),
                    Line(at: "09:19", from: "Carol", file: "Lisbon tips.pdf"),
                    Line(at: "09:20", from: "Carol", text: "The café is the one by the river"),
                ]),
            Chat(
                name: "Family", jid: "family@conference.xippi.eu", kind: .room, account: 0,
                unread: 3,
                lines: [
                    Line(at: "07:30", from: "Dad", text: "Morning all"),
                    Line(at: "07:36", from: "Maya", text: "Thanks for the cake recipe!"),
                    Line(at: "07:38", from: "Dad", text: "Who's bringing dessert?"),
                    Line(at: "07:40", from: "Mum", text: "Sunday lunch at 1?"),
                ]),
            Chat(
                name: "Bob Chen", jid: "bob@xippi.eu", kind: .direct, account: 0,
                lines: [
                    Line(at: "08:25", from: "Bob", text: "Got the tickets"),
                    Line(at: "08:30", text: "See you at the station"),
                ]),
            Chat(
                name: "Omar Farouk", jid: "omar@xippi.eu", kind: .direct, account: 0, unread: 1,
                lines: [
                    Line(at: "08:01", text: "Nice canoe!"),
                    Line(at: "08:02", from: "Omar", text: "Paddling back now 🛶"),
                ]),
            Chat(
                name: "Book club", jid: "books@conference.xippi.eu", kind: .room, account: 0,
                lines: [
                    Line(at: "20:11", day: 1, from: "Ines", text: "Loved the ending"),
                    Line(at: "20:15", day: 1, from: "Keiko", text: "Chapter 7 by Thursday?"),
                ]),
            Chat(
                name: "Self-hosting", jid: "selfhosting@conference.home.arpa", kind: .room,
                account: 2,
                lines: [
                    Line(at: "18:58", day: 1, from: "Nora", text: "How do you back up yours?"),
                    Line(at: "19:02", day: 1, from: "Jonas", text: "Backups run every night now"),
                ]),
            Chat(
                name: "Henrik Lund", jid: "henrik@studio.example", kind: .direct, account: 1,
                lines: [
                    Line(at: "17:40", day: 1, text: "Left a few notes on the flow"),
                    Line(at: "17:45", day: 1, from: "Henrik", text: "Thanks for the review!"),
                ]),
            Chat(
                name: "Keiko Sato", jid: "keiko@xippi.eu", kind: .direct, account: 0,
                lines: [
                    Line(at: "12:05", day: 2, text: "Coffee on Friday?"),
                    Line(at: "12:10", day: 2, from: "Keiko", text: "Sounds good, see you then"),
                ]),
            Chat(
                name: "Priya Nair", jid: "priya@studio.example", kind: .direct, account: 1,
                lines: [Line(at: "09:01", day: 2, from: "Priya", text: "Standup moved to 10")]),
            Chat(
                name: "Maya Patel", jid: "maya@xippi.eu", kind: .direct, account: 0,
                lines: [
                    Line(at: "19:30", day: 3, text: "Happy birthday! 🎂"),
                    Line(at: "19:42", day: 3, from: "Maya", text: "Thank you 🥰"),
                ]),
            Chat(
                name: "Jonas Berg", jid: "jonas@home.arpa", kind: .direct, account: 2,
                lines: [Line(at: "10:20", day: 4, from: "Jonas", text: "The new router is in")]),
            Chat(
                name: "Grace Kim", jid: "grace@studio.example", kind: .direct, account: 1,
                lines: [Line(at: "13:15", day: 5, from: "Grace", text: "Lunch tomorrow?")]),
        ]
    }
#endif
