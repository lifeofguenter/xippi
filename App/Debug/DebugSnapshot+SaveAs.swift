#if DEBUG || UITEST_HOOKS
    import AppKit
    import QuickLookUI
    import XippiSession
    import XippiStore

    /// `-UITestAction "media saveas"`, after `media seed` in an open chat: adds a received file
    /// that is here, then writes `<name>.saveas.txt` with the Save As item of every file
    /// message's context menu (on or off, and the tooltip) and the File menu's Save As with
    /// nothing focused and with Quick Look showing the file, and saves the context menus of
    /// the received file and of one not downloaded as `<name>.saveas-menu-<kind>.png`.
    extension DebugSnapshot {
        /// The menu the hook opened, closed again by its timer.
        private static var trackingMenu: NSMenu?

        static func performSaveAs(_ model: AppModel) async {
            guard let chatID = model.selection, let transcript else { return }
            let picture = FileManager.default.temporaryDirectory.appending(
                path: "debug-media/Whiteboard.png")
            await addReceivedFile(chatID: chatID, file: picture, database: model.database)
            try? await Task.sleep(for: .seconds(1.5))
            var lines: [String] = []
            let page = (try? model.database.page(chatID: chatID, before: nil, limit: 30)) ?? []
            var received: Int64?
            var notDownloaded: Int64?
            for message in page where message.kind == .file {
                guard let id = message.id,
                    let file = try? model.database.attachments(messageID: id).first,
                    let item = transcript.menuItems(forMessage: id).first(where: {
                        $0.title == Copy.saveAs
                    })
                else { continue }
                lines.append(
                    "menu \(message.direction) \(file.fileName ?? "-") state=\(file.state) "
                        + "saveAs=\(item.action == nil ? "off" : "on") "
                        + "tooltip=\(item.toolTip ?? "-")")
                if message.direction == .incoming, file.state == .local,
                    file.fileName == "Site plan.png"
                {
                    received = id
                }
                if file.state == .remote { notDownloaded = id }
            }
            lines.append("file menu, nothing focused: " + fileMenuSaveAs(model))
            if let received {
                await captureMenu(forMessage: received, suffix: "received")
                if let file = try? model.database.attachments(messageID: received).first {
                    transcript.openAttachment(file)
                    try? await Task.sleep(for: .seconds(1))
                    let shown =
                        QLPreviewPanel.sharedPreviewPanelExists()
                        && QLPreviewPanel.shared()?.isVisible == true
                    lines.append(
                        "file menu, Quick Look \(shown ? "showing" : "not showing") "
                            + "\(file.fileName ?? "-"): " + fileMenuSaveAs(model))
                    let chosen = await chooseFileMenuSaveAs()
                    lines.append("file menu Save As chosen: " + chosen)
                    transcript.openAttachment(file)
                    try? await Task.sleep(for: .seconds(1))
                    QLPreviewPanel.shared()?.close()
                    try? await Task.sleep(for: .seconds(0.5))
                    lines.append("file menu, Quick Look closed: " + fileMenuSaveAs(model))
                }
            }
            for message in page where message.kind == .file {
                guard let id = message.id, let row = attachmentRow(forMessage: id) else { continue }
                lines.append("drag \(message.direction): " + dragLine(row))
            }
            if let received {
                let chosen = await chooseRowSaveAs(forMessage: received)
                lines.append("attachment row's Save As action (VoiceOver): " + chosen)
            }
            if let notDownloaded {
                await captureMenu(forMessage: notDownloaded, suffix: "not-downloaded")
                let names = rowActions(forMessage: notDownloaded)
                lines.append("not downloaded row's actions: \(names)")
            }
            write(
                Data((lines.joined(separator: "\n") + "\n").utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("saveas.txt"))
        }

        /// The File menu's Save As as the menu bar has it: on or off, its shortcut and tooltip.
        private static func fileMenuSaveAs(_ model: AppModel) -> String {
            let target =
                model.fileToSave.map {
                    "target=\($0.attachmentID) unavailable=\($0.unavailable ?? "-")"
                } ?? "target=none"
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                // As when the menu opens: SwiftUI brings its items up to date then.
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                guard let item = menu.items.first(where: { $0.title == Copy.saveAs }) else {
                    continue
                }
                let shift = item.keyEquivalentModifierMask.contains(.shift) ? "shift-" : ""
                let others = menu.items.filter { !$0.isSeparatorItem }.map {
                    "\($0.title)=\($0.isEnabled ? "on" : "off")"
                }
                return "\(target) item=\(item.isEnabled ? "on" : "off") "
                    + "key=\(shift)cmd-\(item.keyEquivalent) in=\(menu.title) "
                    + "active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") "
                    + "menu=\(others)"
            }
            return "\(target) item=missing"
        }

        /// Chooses File > Save As as the menu bar would, and says what came up: the save
        /// panel with its name (then cancelled), or nothing.
        private static func chooseFileMenuSaveAs() async -> String {
            for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
                guard let index = menu.items.firstIndex(where: { $0.title == Copy.saveAs })
                else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                menu.performActionForItem(at: index)
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.attachedSheet != nil }),
                    let sheet = window.attachedSheet
                else { return "no panel" }
                let name = (sheet as? NSSavePanel)?.nameFieldStringValue ?? "-"
                window.endSheet(sheet, returnCode: .cancel)
                try? await Task.sleep(for: .seconds(0.5))
                return "\(String(describing: type(of: sheet))) name=\(name)"
            }
            return "item missing"
        }

        /// The message's attachment row, as VoiceOver reaches it.
        private static func attachmentRow(forMessage id: Int64) -> AttachmentRowView? {
            func find(_ view: NSView) -> AttachmentRowView? {
                if let row = view as? AttachmentRowView, !row.isHidden { return row }
                for subview in view.subviews {
                    if let row = find(subview) { return row }
                }
                return nil
            }
            return transcript?.debugCell(forMessage: id).flatMap(find)
        }

        private static func rowActions(forMessage id: Int64) -> [String] {
            attachmentRow(forMessage: id)?.accessibilityCustomActions()?.map(\.name) ?? []
        }

        /// What a drag out of the row carries: the copy's name and folder, and whether it is
        /// the library's own file.
        private static func dragLine(_ row: AttachmentRowView) -> String {
            guard let source = row.dragSource else { return "none" }
            guard let copy = try? SaveAs.dragCopy(source) else { return "copy failed" }
            let inDrag =
                copy.deletingLastPathComponent().deletingLastPathComponent()
                .standardizedFileURL == SaveAs.dragFolder.standardizedFileURL
            return "name=\(copy.lastPathComponent) inDragFolder=\(inDrag) "
                + "libraryFile=\(copy.standardizedFileURL == source.file.standardizedFileURL)"
        }

        /// Runs the attachment row's Save As action, and says what came up.
        private static func chooseRowSaveAs(forMessage id: Int64) async -> String {
            guard
                let action = attachmentRow(forMessage: id)?.accessibilityCustomActions()?
                    .first(where: { $0.name == Copy.saveAs }),
                let handler = action.handler
            else { return "no action, actions=\(rowActions(forMessage: id))" }
            _ = handler()
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.attachedSheet != nil }),
                let sheet = window.attachedSheet
            else { return "no panel" }
            let name = (sheet as? NSSavePanel)?.nameFieldStringValue ?? "-"
            window.endSheet(sheet, returnCode: .cancel)
            try? await Task.sleep(for: .seconds(0.5))
            return "\(String(describing: type(of: sheet))) name=\(name)"
        }

        /// Opens the message's context menu over its cell and saves a picture of it.
        private static func captureMenu(forMessage id: Int64, suffix: String) async {
            guard let cell = transcript?.debugCell(forMessage: id),
                let items = transcript?.menuItems(forMessage: id)
            else { return }
            try? await Task.sleep(for: .seconds(0.5))
            let menu = NSMenu()
            for item in items { menu.addItem(item) }
            trackingMenu = menu
            let url = sibling("saveas-menu-\(suffix)")
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let windows = NSApp.windows.filter {
                        $0.isVisible && String(describing: type(of: $0)).contains("Menu")
                    }
                    if let view = windows.last?.contentView?.superview ?? windows.last?.contentView,
                        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        write(rep.representation(using: .png, properties: [:]), to: url)
                    }
                    trackingMenu?.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: NSPoint(x: 80, y: 20), in: cell)
            trackingMenu = nil
        }

        /// A file from the chat's contact, downloaded: the case Save As is for.
        @concurrent private static func addReceivedFile(
            chatID: Int64, file: URL, database: AppDatabase
        ) async {
            guard let chat = try? database.chat(id: chatID) else { return }
            let isDirect = chat.kind == .direct
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            _ = try? database.upsertIncoming(
                IncomingMessage(
                    accountID: chat.accountID, chatID: chatID,
                    senderJID: isDirect ? chat.jid : "\(chat.jid)/Alice",
                    senderNick: isDirect ? nil : "Alice", body: nil,
                    originID: UUID().uuidString, stanzaMessageID: UUID().uuidString,
                    timestamp: Date(), receivedAt: Date(), kind: .file,
                    attachments: [
                        AttachmentDraft(
                            remoteURL: "https://upload.example.org/e5f6/Site%20plan.png",
                            localPath: file.path, mimeType: "image/png", byteSize: size,
                            fileName: "Site plan.png", state: .local)
                    ]))
        }
    }
#endif
