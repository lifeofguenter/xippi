#if DEBUG || UITEST_HOOKS
    import AppKit
    import QuickLookUI
    import SwiftUI
    import XippiStore
    import os

    /// Renders the main window to a PNG and quits, for checking screens on a Mac where UI
    /// automation and screen recording are not available. Launch arguments:
    /// - `-UITestSnapshot <name>`: the PNG's file name, written to the sandbox's temporary folder.
    /// - `-UITestOpenChat <name>`: the chat to open first.
    /// - `-UITestAction <actions>`, separated by ";": `quickswitcher`, `inspector`, `reply`, `edit`, `search <text>`,
    ///   `scrollup`, `type <text>`, `settings <tab>` (also saves `<name>.settings-<tab>.png` of the Settings
    ///   window), `menubar` (saves `<name>.menubar.png`, the menu bar item).
    /// - `-UITestSnapshotDelay <seconds>`: how long to wait for seeding (default 3).
    /// - `-UITestAppearance light|dark`: the appearance, instead of the system's.
    /// - Calls and data forms: see `DebugSnapshot+Calls.swift`; accounts and onboarding:
    ///   `DebugSnapshot+Accounts.swift`.
    /// Counts for the snapshot hook: how often views ran their body.
    @MainActor enum DebugCounters {
        private(set) static var conversationBodies = 0

        /// Called from the conversation's body.
        static func countConversationBody() {
            conversationBodies += 1
        }
    }

    @MainActor enum DebugSnapshot {
        static weak var transcript: TranscriptController?
        static weak var composer: ComposerModel?
        private static var benchmarks = ""

        /// Times the steps of opening a chat on their own, off the main thread.
        @concurrent private static func benchmark(chatID: Int64, database: AppDatabase) async
            -> String
        {
            let clock = ContinuousClock()
            var results: [String] = []
            for _ in 0..<3 {
                var items: [TranscriptItem] = []
                let fetch = clock.measure {
                    let page = (try? database.page(chatID: chatID, before: nil, limit: 80)) ?? []
                    items = (try? database.transcriptItems(for: page)) ?? []
                }
                let chat = TranscriptChat(id: chatID, jid: "x", name: "x", isRoom: true)
                let prepare = clock.measure {
                    _ = TranscriptPreparation.prepare(
                        TranscriptPreparation.Input(
                            items: items, styled: [:], chat: chat, unreadBefore: nil,
                            highlighted: nil, width: 800, fontSize: 14, calendar: .current,
                            layouts: [:],
                            eventHeights: [:]))
                }
                results.append("fetch=\(fetch) prepare=\(prepare)")
            }
            return results.joined(separator: " | ")
        }

        static weak var model: AppModel?

        static func scheduleIfRequested(model: AppModel) {
            self.model = model
            guard let path = UITestLaunch.value("UITestSnapshot") else { return }
            let delay = UITestLaunch.value("UITestSnapshotDelay").flatMap(Double.init) ?? 3
            let chatName = UITestLaunch.value("UITestOpenChat")
            let action = UITestLaunch.value("UITestAction")
            // In a task: the model can be made before the application object exists.
            Task {
                switch UITestLaunch.value("UITestAppearance") {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                default: break
                }
                try? await Task.sleep(for: .seconds(delay))
                if let chatName, let chat = model.chats.first(where: { $0.displayName == chatName })
                {
                    model.selection = chat.id
                    try? await Task.sleep(for: .seconds(1))
                }
                for step in (action ?? "").split(separator: ";") {
                    await perform(String(step), model: model)
                    try? await Task.sleep(for: .seconds(0.8))
                }
                try? await Task.sleep(for: .seconds(1.2))
                let url = FileManager.default.temporaryDirectory.appending(
                    path: (path as NSString).lastPathComponent)
                capture(to: url, model: model)
                renderRows(
                    model: model, to: url.deletingPathExtension().appendingPathExtension("rows.png")
                )
                NSApp.terminate(nil)
                // A sheet left open can hold the quit back.
                try? await Task.sleep(for: .seconds(3))
                exit(0)
            }
        }

        private static func perform(_ action: String, model: AppModel) async {
            let parts = action.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first {
            case "open":
                if let chat = model.chats.first(where: { $0.displayName == parts.last }) {
                    model.selection = chat.id
                }
            case "activate":
                NSApp.activate()
                NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
            case "quickswitcher": model.quickSwitcherVisible = true
            case "inspector": model.inspectorVisible = true
            case "search": model.searchText = parts.count > 1 ? parts[1] : ""
            case "find": model.findInChatVisible = true
            case "filter": model.sidebarFilter = SidebarFilter(rawValue: parts.last ?? "") ?? .all
            case "sidebar-scroll":
                // Scrolls the chat list down by this many points, and notes where it is.
                sidebarController()?.debugScroll(to: CGFloat(Double(parts.last ?? "") ?? 0))
                sidebarStates.append("scrolled " + (sidebarController()?.debugState ?? ""))
            case "touch":
                // A message arrives in this chat now, so it moves to the top of its section.
                touch(parts.last ?? "", model: model)
            case "sidebar-state":
                sidebarStates.append(sidebarController()?.debugState ?? "")
            case "select-next":
                // Selects the chat the next new one will be, before it exists: a selection whose
                // row comes later, as at launch.
                let next = (model.chats.map(\.id).max() ?? 0) + 1
                model.selection = next
                sidebarStates.append("pending \(next)")
            case "addchat":
                // Makes a chat without selecting it; its row comes with the next chat list.
                if let account = model.chats.first?.chat.accountID,
                    let chat = try? model.database.ensureChat(
                        accountID: account, jid: parts.last ?? "", kind: .direct)
                {
                    sidebarStates.append("added \(chat.id.map(String.init) ?? "none")")
                }
            case "newchat":
                // A new chat, selected at once, as Add contact does: it sorts last, and its
                // row arrives with the next chat list.
                if let account = model.chats.first?.chat.accountID,
                    let chat = try? model.database.ensureChat(
                        accountID: account, jid: parts.last ?? "", kind: .direct),
                    let id = chat.id
                {
                    model.selection = id
                    sidebarStates.append("new \(id)")
                }
            case "reply": transcript?.debugReplyToNewestIncoming()
            case "edit": _ = transcript?.editLastOwnMessage()
            case "type": composer?.text = parts.count > 1 ? parts[1] : ""
            case "send":
                if parts.count > 1 { composer?.text = parts[1] }
                composer?.send()
            case "scrollup": transcript?.debugScroll(by: -2400)
            case "scrolldown": transcript?.debugScroll(by: 2400)
            case "quicklook": transcript?.debugOpenAttachment()
            case "reveal":
                if let text = parts.last, let chatID = model.selection,
                    let hit = try? model.database.search(text, chatID: chatID, limit: 1000).last
                {
                    model.open(chatID: chatID, revealing: hit.messageID)
                }
            case "settings":
                await showSettings(tab: parts.last ?? "", model: model)
            case "menubar":
                renderMenuBar(
                    to: outputURL.deletingPathExtension().appendingPathExtension("menubar.png"))
            case "bench":
                if let chatID = model.selection {
                    benchmarks = await benchmark(chatID: chatID, database: model.database)
                }
            case "media":
                // Composer and transcript media: see `DebugSnapshot+Media.swift`.
                await performMedia(parts.count > 1 ? parts[1] : "", model: model)
            default:
                await performCallOrForm(parts)
            }
        }

        /// Where the main snapshot goes; other captures sit beside it.
        static var outputURL: URL {
            FileManager.default.temporaryDirectory.appending(
                path: ((UITestLaunch.value("UITestSnapshot") ?? "snapshot.png") as NSString)
                    .lastPathComponent)
        }

        /// Opens the Settings window on a tab and saves a picture of it.
        private static func showSettings(tab name: String, model: AppModel) async {
            guard let tab = SettingsTab(rawValue: name) else { return }
            SettingsNavigation.shared.tab = tab
            NSApp.activate()
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
                $0.keyEquivalent == ","
            }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            try? await Task.sleep(for: .seconds(1))
            // The window's own tabs and title come from a window capture; its SwiftUI content
            // does not draw there, so the tab's form is rendered by SwiftUI itself beside it.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == tab.title }),
                let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(
                    rep.representation(using: .png, properties: [:]),
                    to: outputURL.deletingPathExtension().appendingPathExtension(
                        "settings-\(name)-window.png"))
            }
            let dark = NSApp.effectiveAppearance.isDark
            let content = SettingsView(settings: AppSettings(), model: model)
                .tabContent(tab)
                .frame(width: tab.size.width, height: tab.size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            let frame = NSRect(origin: .zero, size: tab.size)
            let offscreen = NSWindow(
                contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            offscreen.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            offscreen.orderBack(nil)
            try? await Task.sleep(for: .seconds(0.7))
            host.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                write(
                    rep.representation(using: .png, properties: [:]),
                    to: outputURL.deletingPathExtension().appendingPathExtension(
                        "settings-\(name).png"))
            }
            offscreen.isReleasedWhenClosed = false
            offscreen.contentView = nil
            offscreen.close()
        }

        /// The menu bar item's label, online and dimmed, enlarged on a menu bar coloured strip.
        private static func renderMenuBar(to url: URL) {
            let dark = NSApp.effectiveAppearance.isDark
            let strip = HStack(spacing: 24) {
                MenuBarLabel(unread: 0, online: true)
                MenuBarLabel(unread: 3, online: true)
                MenuBarLabel(unread: 0, online: false)
            }
            .scaleEffect(4)
            .frame(width: 560, height: 120)
            .foregroundStyle(dark ? Color.white : Color.black)
            .background(dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: strip)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            write(
                NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                to: url)
        }

        private static func capture(to url: URL, model: AppModel) {
            guard
                let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                let view = window.contentView?.superview ?? window.contentView
            else { return }
            // Draws the view tree; materials and glass come out flat.
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep.representation(using: .png, properties: [:]), to: url)
            }
            // Lists the tables and their rows, since materials and glass do not draw here.
            var lines: [String] = [
                "openMilliseconds=\(model.openTiming.lastMilliseconds.map { String($0) } ?? "none")",
                "marks=\(model.openTiming.marks.joined(separator: " "))",
                "history=\(model.openTiming.history.map { String(format: "%.1f", $0) })",
                "sidebar=\(sidebarStates.joined(separator: " | "))",
                "cellsCreated=\(MessageCellView.created)",
                "quickLook=\(QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false))",
                "seeding=\(model.isSeeding)",
                "bench=\(benchmarks)",
                "transcript=\(transcript?.debugState ?? "")",
                "atBottom=\(transcript?.isAtBottom == true)",
                "composer=\(composer?.text ?? "")",
                "editing=\(composer?.editing?.body ?? "none") reply=\(composer?.reply?.quote ?? "none")",
            ]
            func walk(_ view: NSView, depth: Int) {
                if let table = view as? NSTableView {
                    lines.append(
                        "\(type(of: table)) rows=\(table.numberOfRows) frame=\(table.frame)")
                    for row in 0..<min(table.numberOfRows, 12) {
                        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                        let label =
                            cell?.accessibilityLabel() ?? cell?.accessibilityChildren()?
                            .compactMap { ($0 as? NSAccessibilityElementProtocol).map { _ in "" } }
                            .joined() ?? ""
                        lines.append("  row \(row): \(label)")
                    }
                }
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
            walk(view, depth: 0)
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: url.deletingPathExtension().appendingPathExtension("txt"))
        }

        /// What the sidebar steps noted, in order.
        static var sidebarStates: [String] = []

        /// The sidebar table's controller, from the window.
        static func sidebarController() -> SidebarTableController? {
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.accessibilityIdentifier() == "sidebar" {
                    return table
                }
                return view.subviews.lazy.compactMap(find).first
            }
            let root = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview
            return root.flatMap(find)?.delegate as? SidebarTableController
        }

        /// Stores an incoming message in the chat named `name`, timed now.
        private static func touch(_ name: String, model: AppModel) {
            guard let item = model.chats.first(where: { $0.displayName == name }) else { return }
            let now = Date()
            let sender = item.isGroup ? "\(item.chat.jid)/someone" : item.chat.jid
            _ = try? model.database.upsertIncoming(
                IncomingMessage(
                    accountID: item.chat.accountID, chatID: item.id, direction: .incoming,
                    senderJID: sender, senderNick: item.isGroup ? "someone" : nil,
                    body: "touch", timestamp: now, receivedAt: now))
        }

        /// The sidebar's rows, drawn by the sidebar table itself on the window's background:
        /// window captures leave the sidebar's material blank.
        private static func renderRows(model: AppModel, to url: URL) {
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.accessibilityIdentifier() == "sidebar" {
                    return table
                }
                return view.subviews.lazy.compactMap(find).first
            }
            guard
                let root = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                let table = find(root)
            else { return }
            let height = min(table.bounds.height, 900)
            let bounds = NSRect(x: 0, y: 0, width: table.bounds.width, height: height)
            guard let rep = table.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            table.cacheDisplay(in: bounds, to: rep)
            write(rep.representation(using: .png, properties: [:]), to: url)
        }

        static func write(_ data: Data?, to url: URL) {
            do {
                try data?.write(to: url)
            } catch {
                appLog.error("Snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
#endif
