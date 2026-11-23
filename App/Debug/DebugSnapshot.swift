#if DEBUG || UITEST_HOOKS
    import AppKit
    import QuickLookUI
    import ScreenCaptureKit
    import SwiftUI
    import XippiStore
    import os

    /// Renders the main window to a PNG and quits, for checking screens on a Mac where UI
    /// automation and screen recording are not available. Launch arguments:
    /// - `-UITestSnapshot <name>`: the PNG's file name, written to the sandbox's temporary folder.
    /// - `-UITestOpenChat <name>`: the chat to open first.
    /// - `-UITestAction <actions>`, separated by ";": `quickswitcher`, `inspector`, `reply`, `edit`, `search <text>`,
    ///   `scrollup`, `type <text>`, `settings <tab>` (also saves `<name>.settings-<tab>.png` of the Settings
    ///   window), `menubar` (saves `<name>.menubar.png`, the menu bar item),
    ///   `appearance <system|light|dark>` (the setting, as the Settings picker sets it),
    ///   `appearanceclick <segment>` (a click on that picker with the Settings window in front,
    ///   saving frames of both windows just after), `settingsshot <suffix>` (saves the Settings
    ///   and main windows as they show), `titlebar <on|off>` (as the pointer over the chat's
    ///   title bar or off it), `titlebarstate` (notes whether it is taken to be there),
    ///   `titledump` (the title bar's views and their frames), `about` (`<name>.about.png`).
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
        static var benchmarks = ""

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
        /// The app's settings, for steps that change them as the Settings window does.
        static weak var settings: AppSettings?

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
                await placeWindowIfAsked()
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
                await captureWindow(
                    to: url.deletingPathExtension().appendingPathExtension("window.png"))
                // A popover is a window of its own, captured as it shows, frame and all.
                if let popover = NSApp.windows.first(where: {
                    $0.isVisible && String(describing: type(of: $0)).contains("Popover")
                }) {
                    await captureRegion(
                        around: popover,
                        to: url.deletingPathExtension().appendingPathExtension("popover.png"))
                }
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
            case "inspector-off": model.inspectorVisible = false
            case "inspector-tab":
                model.inspectorTab = InspectorTab(rawValue: parts.last ?? "") ?? .info
            case "deselect": model.selection = nil
            case "inspector-toggle": withAnimation { model.inspectorVisible.toggle() }
            case "search": model.searchText = parts.count > 1 ? parts[1] : ""
            case "find": model.findInChatVisible = true
            case "filter": model.sidebarFilter = SidebarFilter(rawValue: parts.last ?? "") ?? .all
            case "pin", "unpin":
                // Pins or unpins the named chat the way its menu does.
                if let chat = model.chats.first(where: { $0.displayName == parts.last }) {
                    model.setPinned(parts.first == "pin", chatID: chat.id)
                }
            case "sidebar-end":
                sidebarController()?.debugScrollToEnd()
                sidebarStates.append("end " + (sidebarController()?.debugState ?? ""))
            case "sidebar-scroll":
                // Scrolls the chat list down by this many points, and notes where it is.
                sidebarController()?.debugScroll(to: CGFloat(Double(parts.last ?? "") ?? 0))
                sidebarStates.append("scrolled " + (sidebarController()?.debugState ?? ""))
            case "touch":
                // A message arrives in this chat now, so it moves to the top of its section.
                touch(parts.last ?? "", model: model)
            case "wheel":
                // A trackpad scroll gesture over the transcript, as real events: `wheel <dy> <dx>`
                // in points per step, five steps with began, changed and ended phases.
                let values = (parts.count > 1 ? parts[1] : "").split(separator: " ").compactMap {
                    Int32($0)
                }
                wheel(dy: values.first ?? 40, dx: values.count > 1 ? values[1] : 0)
            case "state":
                // What the window shows now, for checking what an action changed.
                sidebarStates.append(
                    "inspector=\(model.inspectorVisible)")
            case "sidebar-state":
                sidebarStates.append(sidebarController()?.debugState ?? "")
            case "select-next":
                // Selects the chat the next new one will be, before it exists: a selection whose
                // row comes later, as at launch.
                let next = (model.chats.map(\.id).max() ?? 0) + 1
                model.selection = next
                sidebarStates.append("pending \(next)")
            case "openprivate":
                // A private chat with a room's occupant (`room@service/nick`), selected at once.
                if let account = model.chats.first?.chat.accountID,
                    let chat = try? model.database.ensureChat(
                        accountID: account, jid: parts.last ?? "", kind: .roomPrivate)
                {
                    model.selection = chat.id
                }
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
            case "reactors": transcript?.debugShowReactors()
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
            case "settingsshot":
                // The Settings window as it shows now, title bar and all, and the main window.
                let title = SettingsNavigation.shared.tab.title
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }) {
                    await captureWindow(
                        to: outputURL.deletingPathExtension().appendingPathExtension(
                            "settings-\(parts.last ?? "").png"), window: window)
                }
                await captureWindow(
                    to: outputURL.deletingPathExtension().appendingPathExtension(
                        "main-\(parts.last ?? "").png"))
            case "titlebar":
                // As the pointer over the open chat's title bar (`on`) or off it, in the front
                // window: `<name>.main-titlebar-<on|off>.png` shows it.
                NSApp.activate()
                NSApp.windows.first { $0.isVisible && $0.isMainWindow }?.makeKeyAndOrderFront(nil)
                model.titleBarHovered = parts.last == "on"
                try? await Task.sleep(for: .milliseconds(300))
                await captureWindow(
                    to: outputURL.deletingPathExtension().appendingPathExtension(
                        "main-titlebar-\(parts.last ?? "").png"))
            case "about":
                // The About window, as the app menu opens it: `<name>.about.png`.
                AboutPanel.show()
                try? await Task.sleep(for: .milliseconds(500))
                if let window = NSApp.windows.first(where: {
                    $0.identifier == AboutPanel.identifier
                }) {
                    await captureWindow(
                        to: outputURL.deletingPathExtension().appendingPathExtension("about.png"),
                        window: window)
                }
            case "titledump":
                // The views in the middle of the title bar, with their frames in the window.
                if let window = NSApp.windows.filter({ $0.isVisible })
                    .max(by: { $0.frame.width < $1.frame.width }),
                    let root = window.contentView?.superview
                {
                    func dump(_ view: NSView, _ depth: Int) {
                        let frame = view.convert(view.bounds, to: nil)
                        let top = window.frame.height - frame.maxY
                        if top < 70, frame.height < 80, frame.width < 700 {
                            sidebarStates.append(
                                "\(String(repeating: " ", count: depth))\(type(of: view)) top=\(Int(top)) h=\(Int(frame.height)) x=\(Int(frame.minX)) w=\(Int(frame.width))"
                            )
                        }
                        for child in view.subviews { dump(child, depth + 1) }
                    }
                    dump(root, 0)
                }
            case "titlebarstate":
                // Whether the pointer is taken to be over the chat's title bar.
                sidebarStates.append("titleBarHovered=\(model.titleBarHovered)")
            case "appearanceclick":
                // As a click on the Settings window's picker: the window in front and focused.
                let title = SettingsNavigation.shared.tab.title
                guard
                    let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }),
                    let index = Int(parts.last ?? ""),
                    let picker = segmented(in: window.contentView?.superview)
                else { return }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                picker.selectedSegment = index
                if let action = picker.action {
                    NSApp.sendAction(action, to: picker.target, from: picker)
                }
                // Frames while the windows change over, and which window has the focus.
                for (frame, wait) in [0.03, 0.1, 0.25, 0.5].enumerated() {
                    try? await Task.sleep(for: .seconds(wait))
                    let name = "flip\(index)-\(frame)"
                    await captureWindow(
                        to: outputURL.deletingPathExtension().appendingPathExtension(
                            "settings-\(name).png"), window: window)
                    await captureWindow(
                        to: outputURL.deletingPathExtension().appendingPathExtension(
                            "main-\(name).png"))
                    appLog.notice(
                        "flip \(name, privacy: .public) active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none", privacy: .public) settingsLook=\(window.effectiveAppearance.name.rawValue, privacy: .public) windowLook=\(window.appearance?.name.rawValue ?? "nil", privacy: .public)"
                    )
                }
            case "appearance":
                // As the Settings window's picker sets it.
                if let look = AppSettings.Appearance(rawValue: parts.last ?? "") {
                    settings?.appearance = look
                }
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

        /// The first segmented control in a view's tree.
        private static func segmented(in view: NSView?) -> NSSegmentedControl? {
            guard let view else { return nil }
            if let control = view as? NSSegmentedControl { return control }
            for child in view.subviews {
                if let found = segmented(in: child) { return found }
            }
            return nil
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

        /// The window as it shows, glass and materials included. An app may capture its own
        /// windows without the screen recording permission.
        /// The screen around a popover, with the app's windows under it, as it shows.
        private static func captureRegion(around popover: NSWindow, to url: URL) async {
            do {
                let content = try await SCShareableContent.currentProcess
                let ours = content.windows.filter { $0.isOnScreen }
                guard let screen = popover.screen ?? NSScreen.main,
                    let display = content.displays.first(where: {
                        $0.displayID
                            == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                    })
                else { return }
                let filter = SCContentFilter(display: display, including: ours)
                let configuration = SCStreamConfiguration()
                let around = popover.frame.insetBy(dx: -160, dy: -100)
                configuration.sourceRect = CGRect(
                    x: around.minX - screen.frame.minX, y: screen.frame.maxY - around.maxY,
                    width: around.width, height: around.height)
                let scale = screen.backingScaleFactor
                configuration.width = Int(around.width * scale)
                configuration.height = Int(around.height * scale)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                write(
                    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                    to: url)
            } catch {
                appLog.error(
                    "Popover capture failed: \(String(describing: error), privacy: .public)")
            }
        }

        /// The window as it shows on screen; the largest visible one (the main window, not a
        /// popover over it) when none is named.
        static func captureWindow(to url: URL, window named: NSWindow? = nil) async {
            guard
                let window = named
                    ?? NSApp.windows.filter({ $0.isVisible && $0.contentView != nil })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                    )
            else { return }
            do {
                let content = try await SCShareableContent.currentProcess
                guard
                    let shown = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                    })
                else { return }
                let filter = SCContentFilter(desktopIndependentWindow: shown)
                let configuration = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                configuration.width = Int(filter.contentRect.width * scale)
                configuration.height = Int(filter.contentRect.height * scale)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                write(
                    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                    to: url)
            } catch {
                appLog.error(
                    "Window capture failed: \(String(describing: error), privacy: .public)")
            }
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

        /// Sends a trackpad scroll gesture to the main window, over its transcript.
        private static func wheel(dy: Int32, dx: Int32) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" }),
                let content = window.contentView
            else { return }
            let point = NSPoint(x: content.bounds.midX + 120, y: content.bounds.midY)
            let screen = window.convertPoint(toScreen: point)
            let flipped = CGPoint(
                x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            let phases: [Int64] = [1, 2, 2, 2, 4]  // began, changed x3, ended
            for phase in phases {
                guard
                    let event = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                        wheel1: phase == 4 ? 0 : dy, wheel2: phase == 4 ? 0 : dx, wheel3: 0)
                else { continue }
                event.location = flipped
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                if let ns = NSEvent(cgEvent: event) { window.sendEvent(ns) }
            }
        }

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
