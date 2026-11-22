#if DEBUG || UITEST_HOOKS
    import AppKit
    import ScreenCaptureKit
    import OMEMO
    import XMPPCore
    import XippiSession
    import XippiStore
    import os

    /// The App Store screenshots (`make screenshots`, on `-UITestSeed store`):
    /// - `-UITestScreen <name>`: the main window moves onto the screen of that name, the 2x
    ///   display `scripts/screenshots/display.m` adds, so its captures have a Retina Mac's
    ///   pixels.
    /// - `-UITestWindowSize <width>x<height>`: its size there, in points.
    /// - `-UITestSidebarWidth <points>`: the sidebar's width.
    /// The installed app shares these preferences, so neither the window's frame nor the
    /// sidebar's width is saved.
    ///
    /// `-UITestAction` steps:
    /// - `online`: every account online and every contact available, as sessions would say.
    /// - `read <chat>`: the chat (by its name) read up to its newest message.
    /// - `click <x> <y>`: a click into the main window, in points from its top left.
    /// - `verified`: the open contact's devices, two, both verified.
    /// - `roompictures`: pictures from the store photos for some rooms.
    /// - `float <x> <y>`: the call window moves to that point, in points from the main
    ///   window's top left.
    /// - `composite <#rrggbb>`: the app's windows on that screen as macOS draws them, shadows
    ///   and all, on a backdrop of that colour (what the screenshot puts around them), to
    ///   `<name>.composite.png`, and `<name>.composite.json` with the main window's frame in
    ///   it, in points from its top left.
    extension DebugSnapshot {
        static func placeWindowIfAsked() async {
            guard let name = UITestLaunch.value("UITestScreen") else { return }
            guard let window = largestWindow,
                let screen = NSScreen.screens.first(where: { $0.localizedName == name })
            else {
                appLog.error("No window or no screen named \(name, privacy: .public)")
                return
            }
            _ = window.setFrameAutosaveName("")
            let split = splitView(in: window.contentView?.superview)
            split?.autosaveName = nil
            let size =
                UITestLaunch.value("UITestWindowSize").flatMap(windowSize) ?? window.frame.size
            window.setFrame(centered(size, in: screen.visibleFrame), display: true)
            if let width = UITestLaunch.value("UITestSidebarWidth").flatMap(Double.init) {
                split?.setPosition(width, ofDividerAt: 0)
            }
            try? await Task.sleep(for: .milliseconds(600))
        }

        static func performStore(_ parts: [String]) async -> Bool {
            switch parts.first {
            case "online":
                #if DEBUG
                    guard let model else { return true }
                    for account in model.accounts {
                        if let id = account.id {
                            model.status.debugShow(.online(resumed: false), accountID: id)
                        }
                    }
                    for item in model.chats where !item.isGroup {
                        model.status.debugShow(
                            PresenceSummary(availability: .available, resources: 1),
                            for: PresenceKey(accountID: item.chat.accountID, jid: item.chat.jid))
                    }
                #endif
            case "float":
                let values = (parts.count > 1 ? parts[1] : "").split(separator: " ")
                    .compactMap { Double($0) }
                guard values.count == 2, let main = largestWindow,
                    let other = NSApp.windows.first(where: {
                        $0.isVisible && $0 !== main && $0.contentView != nil
                            && $0.identifier?.rawValue == CallCoordinator.windowID
                    })
                else { return true }
                let origin = NSPoint(
                    x: main.frame.minX + values[0],
                    y: main.frame.maxY - values[1] - other.frame.height)
                other.setFrameOrigin(origin)
                other.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(400))
            case "read":
                guard let model, parts.count > 1,
                    let item = model.chats.first(where: { $0.displayName == parts[1] }),
                    let newest = try? model.database.page(chatID: item.id, before: nil, limit: 1)
                        .last?.id
                else { return true }
                _ = try? model.database.markRead(chatID: item.id, upTo: newest)
            case "click":
                let values = (parts.count > 1 ? parts[1] : "").split(separator: " ")
                    .compactMap { Double($0) }
                guard values.count == 2, let window = largestWindow else { return true }
                let point = NSPoint(x: values[0], y: window.frame.height - values[1])
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1)
                    {
                        window.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            case "front":
                // A launch from a shell that is not in front leaves the app inactive, and its
                // windows draw grey controls.
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                largestWindow?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))
            case "verified":
                guard let model, let contact = chatContext?.contact else { return true }
                let now = Date()
                contact.debugSeed(
                    identities: [
                        storeIdentity(
                            contact.jid, 0, devices: [.v2: [4_127], .v03: [4_127]],
                            seen: now.addingTimeInterval(-300)),
                        storeIdentity(
                            contact.jid, 1, devices: [.v2: [8_830]],
                            seen: now.addingTimeInterval(-3 * 3600)),
                    ],
                    own: InspectorSamples.ownIdentities(of: model))
            case "roompictures":
                if let model { roomPictures(model) }
            case "composite":
                await captureComposite(backdrop: parts.count > 1 ? parts[1] : "#ffffff")
            default:
                return false
            }
            return true
        }

        /// `1240x780` as a size; nil for anything else.
        nonisolated static func windowSize(_ text: String) -> CGSize? {
            let parts = text.split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                width > 0, height > 0
            else { return nil }
            return CGSize(width: width, height: height)
        }

        /// A frame of that size in the middle of the screen's visible area, on whole points.
        nonisolated static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
            CGRect(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.midY - size.height / 2).rounded(),
                width: size.width, height: size.height)
        }

        /// A window's frame in points from the main window's top left, y downwards.
        nonisolated static func offset(of frame: CGRect, from main: CGRect) -> CGRect {
            CGRect(
                x: frame.minX - main.minX, y: main.maxY - frame.maxY, width: frame.width,
                height: frame.height)
        }

        /// Margin around the windows, for their shadows.
        private static let shadowMargin: CGFloat = 90

        private static func captureComposite(backdrop hex: String) async {
            guard let main = largestWindow, let screen = main.screen,
                let color = color(hex)
            else { return }
            let windows = NSApp.windows.filter { $0.isVisible && $0.screen == screen }
            let around = windows.map(\.frame).reduce(main.frame) { $0.union($1) }
                .insetBy(dx: -shadowMargin, dy: -shadowMargin)
                .intersection(screen.frame)
            // Behind every window of the app: what glass shows through and shadows fall on.
            let backdrop = NSWindow(
                contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                defer: false, screen: screen)
            backdrop.backgroundColor = color
            backdrop.isReleasedWhenClosed = false
            backdrop.hasShadow = false
            backdrop.setFrame(screen.frame, display: true)
            backdrop.order(.below, relativeTo: main.windowNumber)
            defer { backdrop.orderOut(nil) }
            try? await Task.sleep(for: .milliseconds(800))
            do {
                let content = try await SCShareableContent.currentProcess
                let numbers = Set((windows + [backdrop]).map { CGWindowID($0.windowNumber) })
                guard
                    let display = content.displays.first(where: {
                        $0.displayID
                            == screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                    })
                else { return }
                let filter = SCContentFilter(
                    display: display,
                    including: content.windows.filter { numbers.contains($0.windowID) })
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(
                    x: around.minX - screen.frame.minX, y: screen.frame.maxY - around.maxY,
                    width: around.width, height: around.height)
                configuration.width = Int(around.width * screen.backingScaleFactor)
                configuration.height = Int(around.height * screen.backingScaleFactor)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                write(
                    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                    to: sibling("composite"))
                let frame = offset(of: main.frame, from: around)
                write(
                    try? JSONSerialization.data(
                        withJSONObject: [
                            "main": [
                                "x": frame.minX, "y": frame.minY, "width": frame.width,
                                "height": frame.height,
                            ],
                            "width": around.width, "height": around.height,
                            "scale": screen.backingScaleFactor,
                        ], options: [.prettyPrinted, .sortedKeys]),
                    to: outputURL.deletingPathExtension().appendingPathExtension("composite.json"))
            } catch {
                appLog.error(
                    "Composite capture failed: \(String(describing: error), privacy: .public)")
            }
        }

        /// `#rrggbb` as a colour, in sRGB.
        nonisolated static func color(_ hex: String) -> NSColor? {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
        }

        private static func storeIdentity(
            _ jid: JID, _ index: Int, devices: [OMEMO.OMEMOVersion: [UInt32]], seen: Date
        ) -> OMEMOIdentityInfo {
            let fingerprints = [
                "3f9a1c07 b2e45d81 6c0f93ae 47d218b5 a90e6c32 15fb7d48 c26a09e1 8d4b3f70",
                "e71c4a92 0bd83f65 a4c27e19 59f0b3d8 2e6a91c4 f83d057b 16c9e2a0 7b54d8f3",
            ]
            return OMEMOIdentityInfo(
                jid: jid, identityKey: Data(repeating: UInt8(index + 7), count: 32),
                fingerprint: fingerprints[index], trust: .verified, deviceIDs: devices,
                isActive: true, isStale: false, isThisDevice: false, lastSeen: seen)
        }

        /// Room pictures cut from the store photos, as a room's avatar would show them.
        private static func roomPictures(_ model: AppModel) {
            let directory = model.services.avatarDirectory
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let pictures = [
                ("Weekend in the Alps", "kayak"), ("Book club", "books"), ("Family", "cake"),
            ]
            for (index, (name, photo)) in pictures.enumerated() {
                guard let item = model.chats.first(where: { $0.displayName == name }),
                    let url = StoreSample.photo(photo), let image = NSImage(contentsOf: url)
                else { continue }
                let side = min(image.size.width, image.size.height)
                let square = NSImage(size: NSSize(width: 256, height: 256), flipped: false) {
                    rect in
                    image.draw(
                        in: rect,
                        from: NSRect(
                            x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
                            width: side, height: side),
                        operation: .copy, fraction: 1)
                    return true
                }
                guard let tiff = square.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(
                        using: .png, properties: [:])
                else { continue }
                let hash = "storeroom\(index)" + String(repeating: "0", count: 32)
                try? png.write(to: directory.appending(path: hash + ".png"))
                try? model.database.storeAvatar(
                    AvatarRecord(hash: hash, fileName: hash + ".png", byteSize: Int64(png.count)))
                try? model.database.showAvatar(
                    accountID: item.chat.accountID, jid: item.chat.jid, hash: hash, own: false)
            }
        }

        private static var largestWindow: NSWindow? {
            NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        private static func splitView(in view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap(splitView).first
        }
    }
#endif
