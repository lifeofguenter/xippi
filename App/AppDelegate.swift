import AppKit
import XippiSession

/// Ends the accounts' sessions properly when the app quits: each says unavailable and closes
/// its stream (Stream Management's last ack, then `</stream:stream>`), all at once, so
/// contacts see the account offline at once and the server keeps no session to resume. The
/// quit waits at most 2 s for it, whatever the network does.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, set at launch; nil when the database could not be opened.
    static weak var model: AppModel?
    /// Opens `xmpp:` links; set at launch.
    static weak var links: XMPPURIHandler?
    private var quitting = false

    static let quitLimit: Duration = .seconds(2)

    /// `xmpp:` links from the browser or another app (the app's URL type).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Self.links?.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessions = Self.model?.sessions, !quitting else { return .terminateNow }
        quitting = true
        // `terminate` may have been called from a main-queue task, which then waits in a
        // nested run loop that runs no other main-queue work until the reply comes: the work
        // runs off the main actor and needs nothing from it (the limit is read here), and the
        // reply goes through the run loop.
        let limit = Self.quitLimit
        Task.detached {
            await sessions.stopAll(within: limit)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}
