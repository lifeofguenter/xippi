#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import XMPPCore
    import XippiSession

    /// `-UITestAction` steps for calls and data forms, driving `CallFixtures` (UI test launches
    /// only):
    /// - `call <scenario>`: starts a fake call (`incoming-video`, `outgoing-audio`,
    ///   `outgoing-denied`, ...).
    /// - `endsource`: the fake account's events end, and a fresh fake account takes its place.
    /// - `peer <event>`: the peer or the system acts (`peer-hangup`, `camera-denied`, ...).
    /// - `accept`, `acceptvideo`, `decline`, `hangup`, `mute`, `video`: the user's requests.
    /// - `callshot <suffix>`: saves `<name>.call-<suffix>.png` of the call window, and
    ///   `<name>.panel-<suffix>.png` of the incoming call panel while it shows.
    /// - `devices`: saves `<name>.devices.png`, the device picker.
    /// - `form <sample>`, `formproblems <sample>`: saves `<name>.form-<sample>.png` of
    ///   `bot` (XEP-0004 example), `captcha` (XEP-0158 example) or `result` (read-only), the
    ///   second after a submit with a missing value and a bad address.
    extension DebugSnapshot {
        static weak var calls: CallCoordinator?

        static func performCallOrForm(_ parts: [String]) async {
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "call": await CallFixtures.start(argument)
            case "endsource": await CallFixtures.endSource()
            case "peer": await CallFixtures.manager?.perform(argument)
            case "accept": calls?.accept(video: false)
            case "acceptvideo": calls?.accept(video: true)
            case "decline": calls?.decline()
            case "hangup": calls?.hangUp()
            case "mute": calls?.toggleMute()
            case "video": calls?.toggleVideo()
            case "callshot": await captureCallWindows(suffix: argument)
            case "devices": await renderDevices()
            case "form": await renderForm(argument, showingProblems: false)
            case "formproblems": await renderForm(argument, showingProblems: true)
            default:
                // The App Store screenshots: see `DebugSnapshot+Store.swift`.
                if await performStore(parts) { return }
                // The final fix wave's views: see `DebugSnapshot+FinalFix.swift`.
                if await performFinalFix(parts) { return }
                // The power tools and channels: see `DebugSnapshot+Tools.swift`.
                if await performTools(parts) { return }
                // The inspector, rooms and contacts: see `DebugSnapshot+Inspector.swift`.
                if await performInspector(parts) { return }
                await performAccount(parts)
            }
        }

        static func sibling(_ suffix: String) -> URL {
            outputURL.deletingPathExtension().appendingPathExtension("\(suffix).png")
        }

        /// The call window's content at the window's size, and the panel. SwiftUI does not draw
        /// a scene window's content through `cacheDisplay`, so the content is drawn again in a
        /// window of its own; glass comes out flat either way.
        private static func captureCallWindows(suffix: String) async {
            var lines = NSApp.windows.map {
                "window id=\($0.identifier?.rawValue ?? "-") title=\($0.title) visible=\($0.isVisible) frame=\($0.frame)"
            }
            if let board = calls?.board {
                lines.append("board=\(String(describing: board.call))")
            }
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("call-\(suffix).txt"))
            let callWindow = NSApp.windows.first { window in
                let id = window.identifier?.rawValue ?? ""
                return window.isVisible && (id == CallCoordinator.windowID || id.hasPrefix("call-"))
            }
            if let callWindow, let calls {
                await renderOffscreen(
                    CallWindowContent(coordinator: calls),
                    size: callWindow.contentRect(forFrameRect: callWindow.frame).size, dark: true,
                    to: sibling("call-\(suffix)"))
            }
            let panel = NSApp.windows.first {
                $0.isVisible && $0.identifier?.rawValue == "incoming-call-panel"
            }
            if let panel { capture(panel, to: sibling("panel-\(suffix)")) }
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            write(rep.representation(using: .png, properties: [:]), to: url)
        }

        private static func renderDevices() async {
            guard let calls else { return }
            await renderOffscreen(
                DevicePicker(coordinator: calls).environment(\.colorScheme, .dark),
                size: NSSize(width: 340, height: 300), dark: true, to: sibling("devices"))
        }

        private static func renderForm(_ name: String, showingProblems: Bool) async {
            let suffix = "form-\(name)" + (showingProblems ? "-problems" : "")
            switch name {
            case "bot":
                var form = FormSamples.botConfiguration
                if showingProblems,
                    let index = form.fields.firstIndex(where: { $0.variable == "invitelist" })
                {
                    form.fields[index].values = ["juliet@example.com", "romeo@@example.com"]
                }
                await renderOffscreen(
                    DataFormView(form: form, showingProblems: showingProblems),
                    size: NSSize(width: 560, height: 1080),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling(suffix))
            case "result":
                await renderOffscreen(
                    DataFormView(form: FormSamples.result, showingProblems: false),
                    size: NSSize(width: 520, height: 360),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling(suffix))
            case "captcha":
                let image = FormSamples.captchaImage()
                let contentID = "cid:\(FormSamples.captchaContentID)"
                var form = FormSamples.captcha
                if showingProblems,
                    let index = form.fields.firstIndex(where: { $0.variable == "ocr" })
                {
                    // A server that requires the answer: Submit with it empty shows why.
                    form.fields[index].required = true
                }
                await renderOffscreen(
                    DataFormView(
                        form: form, showingProblems: showingProblems,
                        media: { $0.uri == contentID ? image : nil }),
                    size: NSSize(width: 520, height: 420),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling(suffix))
            default:
                break
            }
        }

        /// Draws `content` in a window of its own, off to the back, and saves it.
        static func renderOffscreen(
            _ content: some View, size: NSSize, dark: Bool, to url: URL
        ) async {
            let frame = NSRect(origin: .zero, size: size)
            let host = NSHostingView(
                rootView:
                    content
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window.orderBack(nil)
            try? await Task.sleep(for: .seconds(0.7))
            host.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                write(rep.representation(using: .png, properties: [:]), to: url)
            }
            window.isReleasedWhenClosed = false
            window.contentView = nil
            window.close()
        }
    }
#endif
