import AppKit
import SwiftUI

/// About Xippi: the version and copyright, the licence and the source, the site with its
/// privacy and terms pages, and the notices of the libraries the app ships. A window of its own: the standard About panel is too narrow for the notices.
@MainActor enum AboutPanel {
    static let site = URL(string: "https://xippi.eu")!
    static let privacy = URL(string: "https://xippi.eu/privacy")!
    static let terms = URL(string: "https://xippi.eu/terms")!
    static let source = URL(string: "https://github.com/lifeofguenter/xippi")!
    static let license = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    /// The links under the licence, in their order.
    static let links: [(title: String, url: URL)] = [
        (Copy.sourceCode, source), (Copy.license, license), ("xippi.eu", site),
        (Copy.privacy, privacy), (Copy.terms, terms),
    ]
    static let width: CGFloat = 520
    static let identifier = NSUserInterfaceItemIdentifier("about")
    private static var window: NSWindow?

    static func show() {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Copy.aboutApp
        window.identifier = identifier
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// The copyright line, as Finder shows it from Info.plist.
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return Copy.aboutVersion(
            info?["CFBundleShortVersionString"] as? String ?? "",
            build: info?["CFBundleVersion"] as? String ?? "")
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(Copy.appName)
                    .font(.appTitle)
                Group {
                    Text(AboutPanel.version)
                        .textSelection(.enabled)
                    Text(AboutPanel.copyright)
                }
                .foregroundStyle(.secondary)
            }
            Text(Copy.aboutLicence)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                ForEach(AboutPanel.links, id: \.url) { link in
                    Link(link.title, destination: link.url)
                }
            }
            .pointerStyle(.link)
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.acknowledgements)
                    .font(.appEmphasized)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Acknowledgements.libraries, id: \.name) { library in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(library.name), \(library.license)")
                                    .font(.appEmphasized)
                                Text(library.notice)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .frame(height: 200)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
            }
        }
        .font(.appBody)
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: AboutPanel.width)
    }
}
