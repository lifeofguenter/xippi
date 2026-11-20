import AppKit
import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// What the XML console shows and does for one account: the account's stream through a
/// `StreamTap` (the last 2,000 elements, credentials hidden), filtered, paused or not, and a
/// send box for raw stanzas.
///
/// The tap is the account's only while the window is open (`start()` to `stop()`): the session
/// manager gives it to the account's session and to every later one before its first byte, so
/// a reconnect's login shows too. Closing the window takes it off and drops what it held.
@MainActor @Observable final class XMLConsoleModel {
    enum DirectionChoice: String, CaseIterable, Identifiable {
        case all, incoming, outgoing
        var id: String { rawValue }

        var direction: StreamTapEntry.Direction? {
            switch self {
            case .all: nil
            case .incoming: .incoming
            case .outgoing: .outgoing
            }
        }
    }

    let accountID: Int64
    let jid: String
    /// The records that pass the filter, oldest first.
    private(set) var shown: [StreamTapRecord] = []
    private(set) var total = 0
    var filterText = "" {
        didSet { if filterText != oldValue { refresh(force: true) } }
    }
    var direction = DirectionChoice.all {
        didSet { if direction != oldValue { refresh(force: true) } }
    }
    /// While paused the list holds still; the ring goes on recording.
    var paused = false {
        didSet { if !paused { refresh(force: true) } }
    }
    var pretty = false
    var selection: Set<UInt64> = []
    var draft = ""
    private(set) var sendProblem: String?
    /// The send waiting for the user's yes, the first time in this app run.
    var confirmingSend = false

    @ObservationIgnored let tap = StreamTap()
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// The text the user confirmed sending, the first time.
    @ObservationIgnored private var pending: String?

    /// Accounts whose raw sends the user confirmed in this app run.
    private static var confirmedAccounts: Set<Int64> = []

    init(model: AppModel, accountID: Int64) {
        self.model = model
        self.accountID = accountID
        jid = model.accounts.first { $0.id == accountID }?.jid ?? ""
    }

    /// Gives the tap to the account's sessions, now and later, and follows what it records.
    /// Can run again after `stop()`: each start reads its own stream of changes.
    func start() {
        guard refreshing == nil else { return }
        let sessions = model.sessions
        let tap = tap
        let accountID = accountID
        Task { await sessions.setStreamTap(tap, accountID: accountID) }
        let updates = tap.updates()
        refreshing = Task { [weak self] in
            for await _ in updates {
                self?.refresh()
                // A burst (a roster, an archive page) is drawn a few times a second.
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// Takes the tap off the account, then forgets everything it held; nothing recorded in
    /// between stays behind. A console opened since keeps its own tap, and this one, started
    /// again meanwhile, keeps what it records.
    func stop() {
        refreshing?.cancel()
        refreshing = nil
        let sessions = model.sessions
        let tap = tap
        let accountID = accountID
        Task { [weak self] in
            await sessions.removeStreamTap(tap, accountID: accountID)
            guard self?.refreshing == nil else { return }
            tap.clear()
            self?.shown = []
            self?.total = 0
        }
    }

    private func refresh(force: Bool = false) {
        guard force || !paused else { return }
        let records = tap.records
        total = records.count
        shown = StreamTapFilter(text: filterText, direction: direction.direction)
            .apply(to: records)
        if !selection.isEmpty {
            selection.formIntersection(shown.map(\.id))
        }
    }

    func clear() {
        tap.clear()
        selection = []
        refresh(force: true)
    }

    /// The selected records, or every one shown, as the list shows them.
    func copy() {
        let records = selection.isEmpty ? shown : shown.filter { selection.contains($0.id) }
        let text = records.map { pretty ? StreamTapFormat.pretty($0.xml) : $0.xml }
            .joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Sending

    /// Checks the send box and sends it, asking first the first time in this app run: it goes
    /// out as the user. The session checks it again before it writes anything.
    func send() {
        sendProblem = nil
        do {
            _ = try StreamTapInput.stanza(from: draft)
        } catch {
            sendProblem = Copy.consoleProblem(error)
            return
        }
        if Self.confirmedAccounts.contains(accountID) {
            transmit(draft)
        } else {
            pending = draft
            confirmingSend = true
        }
    }

    func confirmSend() {
        confirmingSend = false
        Self.confirmedAccounts.insert(accountID)
        if let pending { transmit(pending) }
        pending = nil
    }

    func cancelSend() {
        confirmingSend = false
        pending = nil
    }

    private func transmit(_ text: String) {
        let accountID = accountID
        Task { [weak self, model] in
            guard let session = await model.sessions.session(for: accountID) else {
                self?.sendProblem = Copy.notConnectedReason.capitalizedSentence
                return
            }
            do throws(ConsoleSendError) {
                try await session.sendConsoleStanza(text)
                if self?.draft == text { self?.draft = "" }
            } catch .invalid(let problem) {
                self?.sendProblem = Copy.consoleProblem(problem)
            } catch {
                self?.sendProblem = Copy.notConnectedReason.capitalizedSentence
            }
        }
    }
}

/// The XML console window of one account.
struct XMLConsoleWindow: View {
    let appModel: AppModel
    @State private var console: XMLConsoleModel

    init(model: AppModel, accountID: Int64) {
        appModel = model
        _console = State(initialValue: XMLConsoleModel(model: model, accountID: accountID))
    }

    var body: some View {
        XMLConsoleView(console: console, online: isOnline)
            .navigationTitle(Copy.xmlConsole)
            .navigationSubtitle(console.jid)
            .onAppear { console.start() }
            .onDisappear { console.stop() }
    }

    private var isOnline: Bool {
        if case .online = appModel.status.connection[console.accountID] { return true }
        return false
    }
}

/// The console's list, toolbar and send box.
struct XMLConsoleView: View {
    @Bindable var console: XMLConsoleModel
    let online: Bool

    var body: some View {
        VStack(spacing: 0) {
            records
            Divider()
            SendBox(console: console, online: online)
        }
        .frame(minWidth: 640, minHeight: 420)
        .font(.appBody)
        .searchable(text: $console.filterText, placement: .toolbar, prompt: Copy.consoleFilter)
        .toolbar { ConsoleToolbar(console: console) }
        .sheet(isPresented: $console.confirmingSend) {
            ConfirmationSheet(
                title: Copy.sendRawTitle(console.jid), actionTitle: Copy.sendXML,
                identifier: "console-send", onConfirm: console.confirmSend,
                onCancel: console.cancelSend)
        }
        .accessibilityIdentifier("xml-console")
    }

    @ViewBuilder private var records: some View {
        if console.shown.isEmpty {
            ContentUnavailableView(
                console.total == 0 ? Copy.noStanzas : Copy.noMatches,
                systemImage: "chevron.left.forwardslash.chevron.right"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(console.shown, selection: $console.selection) { record in
                    ConsoleRow(record: record, pretty: console.pretty)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("xml-console-records")
                .onChange(of: console.shown.last?.id) { _, last in
                    guard let last, !console.paused else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onAppear {
                    // The newest at the bottom, in view, as a console opens.
                    if let last = console.shown.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

/// Direction, pause, layout, copy and clear. The direction is a picker of words; the rest are
/// icons of one size.
private struct ConsoleToolbar: ToolbarContent {
    @Bindable var console: XMLConsoleModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(Copy.direction, selection: $console.direction) {
                Text(Copy.directionAll).tag(XMLConsoleModel.DirectionChoice.all)
                Text(Copy.directionIncoming).tag(XMLConsoleModel.DirectionChoice.incoming)
                Text(Copy.directionOutgoing).tag(XMLConsoleModel.DirectionChoice.outgoing)
            }
            .pickerStyle(.segmented)
            .pointerStyle(.link)
            .accessibilityIdentifier("console-direction")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let pauseTitle = console.paused ? Copy.resume : Copy.pauseConsole
            Button(pauseTitle, systemImage: console.paused ? "play.fill" : "pause.fill") {
                console.paused.toggle()
            }
            .help(pauseTitle)
            .accessibilityIdentifier("console-pause")
            let layoutTitle = console.pretty ? Copy.plainXML : Copy.prettyPrint
            Button(
                layoutTitle, systemImage: console.pretty ? "text.alignleft" : "list.bullet.indent"
            ) {
                console.pretty.toggle()
            }
            .help(layoutTitle)
            .accessibilityIdentifier("console-pretty")
            Button(Copy.copyShown, systemImage: "doc.on.doc", action: console.copy)
                .help(Copy.copyShown)
                .accessibilityIdentifier("console-copy")
            Button(
                Copy.clearConsole, systemImage: "trash", role: .destructive, action: console.clear
            )
            .foregroundStyle(.red)
            .help(Copy.clearConsole)
            .accessibilityIdentifier("console-clear")
        }
    }
}

/// One element: its direction as an arrow and a coloured bar, the time, and the XML.
private struct ConsoleRow: View {
    let record: StreamTapRecord
    let pretty: Bool

    var body: some View {
        let incoming = record.direction == .incoming
        let colour: Color = incoming ? .blue : .green
        let (text, cut) = Self.shortened(pretty ? StreamTapFormat.pretty(record.xml) : record.xml)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                .foregroundStyle(colour)
                .accessibilityLabel(incoming ? Copy.received : Copy.sent)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.date, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                Text(verbatim: text)
                    .font(.appMonospaced)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if cut > 0 || record.omittedBytes > 0 {
                    Text(Copy.notShown(characters: cut, bytes: record.omittedBytes))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            colour.frame(width: ControlHeight.Tools.directionBar)
        }
        // One element per row: its direction and time, and the XML as its value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(incoming ? Copy.received : Copy.sent), \(record.date.formatted(date: .omitted, time: .standard))"
        )
        .accessibilityValue(Text(verbatim: record.xml))
        .accessibilityIdentifier(incoming ? "console-in" : "console-out")
    }

    /// At most `rowCharacters` of `text`, and how many more there are; Copy takes it whole.
    static func shortened(_ text: String) -> (String, Int) {
        let limit = ControlHeight.Tools.rowCharacters
        guard text.utf8.count > limit else { return (text, 0) }
        let head = String(text.prefix(limit))
        return (head, text.count - head.count)
    }
}

/// The send box: raw XML, its problem in red, and Send.
private struct SendBox: View {
    @Bindable var console: XMLConsoleModel
    let online: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $console.draft)
                    .font(.appMonospaced)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: ControlHeight.Tools.sendBox)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if console.draft.isEmpty {
                            Text(Copy.rawXML)
                                .font(.appMonospaced)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }
                    .accessibilityLabel(Copy.rawXML)
                    .accessibilityIdentifier("console-draft")
                VStack(alignment: .trailing, spacing: 6) {
                    Text(Self.count(console))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("console-count")
                    ToolButton(title: Copy.sendXML, identifier: "console-send") {
                        console.send()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!online)
                }
            }
            if !online {
                Text(Copy.notConnectedReason.capitalizedSentence)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("console-offline")
            }
            ToolError(text: console.sendProblem, identifier: "console-send-problem")
        }
        .padding(12)
    }

    private static func count(_ console: XMLConsoleModel) -> String {
        let count = Copy.stanzaCount(console.shown.count, of: console.total)
        return console.paused ? "\(Copy.paused), \(count)" : count
    }
}

extension String {
    /// The text with its first letter in upper case: a reason ("not connected") on its own.
    var capitalizedSentence: String {
        prefix(1).uppercased() + dropFirst()
    }
}
