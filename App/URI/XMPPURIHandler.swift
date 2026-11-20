import Foundation
import Observation
import XMPPCore
import XippiSession
import XippiStore
import os

/// A link waiting for the user's answer in a sheet: what it asks, and the accounts to act as.
struct URIRequest: Identifiable, Equatable {
    let id = UUID()
    var intent: XMPPURIIntent
    /// The accounts offered; with one, the sheet shows no choice.
    var accounts: [Int64]
    var account: Int64
}

/// Opens `xmpp:` links (RFC 5122, XEP-0147, XEP-0401) from the browser or another app.
///
/// A link never acts by itself (`XMPPURIIntent`): a chat opens with the text filled in and
/// not sent; joining a room and adding a contact open a sheet to confirm; a registration link
/// opens the register sheet with its invite. With several accounts the sheet asks which one,
/// starting from the one used for a link last (`URIAccountChoice`).
@MainActor @Observable final class XMPPURIHandler {
    /// The sheet over the main window, while set.
    var request: URIRequest?

    /// Fills in the composer of the open chat; set by the main window.
    @ObservationIgnored var prefill: ((_ chatID: Int64, _ text: String) -> Void)?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let presenter: MainWindowPresenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var queue: Task<Void, Never>?

    static let lastAccountKey = "eu.xippi.lastLinkAccount"

    /// - Parameter defaults: where the last account used is kept; UI test launches keep it
    ///   apart.
    init(presenter: MainWindowPresenter, defaults: UserDefaults = LaunchDefaults.make("links")) {
        self.presenter = presenter
        self.defaults = defaults
    }

    func attach(to model: AppModel) {
        self.model = model
    }

    /// Takes a link opened from outside; links are handled one after the other.
    func open(_ url: URL) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.handle(url)
        }
    }

    private var lastUsed: Int64? {
        get { (defaults.object(forKey: Self.lastAccountKey) as? NSNumber)?.int64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Self.lastAccountKey) }
    }

    func handle(_ url: URL) async {
        guard let model else { return }
        // A link can arrive with the launch, before the accounts and chats are read.
        await model.reloadAccounts()
        for _ in 0..<50 where !model.chatsLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let intent = XMPPURIIntent(url: url, hasAccounts: !model.accounts.isEmpty) else {
            appLog.info("Link ignored")
            return
        }
        if case .register(let invite) = intent {
            await presenter.showAndWait()
            model.onboarding = .register(invite)
            return
        }
        let choice = URIAccountChoice(
            for: intent, accounts: model.accounts, chats: model.chats.map(\.chat),
            lastUsed: lastUsed)
        switch choice {
        case .none, .notNeeded:
            appLog.info("Link ignored: no enabled account")
        case .use(let account):
            if case .openChat = intent {
                if await perform(intent, account: account, fields: URIFields(intent)) != nil {
                    appLog.error("Link not opened: chat not stored")
                }
            } else {
                await ask(URIRequest(intent: intent, accounts: [account], account: account))
            }
        case .ask(let accounts, let preselected):
            await ask(URIRequest(intent: intent, accounts: accounts, account: preselected))
        }
    }

    private func ask(_ request: URIRequest) async {
        await presenter.showAndWait()
        self.request = request
    }

    func cancel() {
        request = nil
    }

    /// Does what the sheet confirmed; the reason it was not done, or nil.
    func confirm(_ request: URIRequest, account: Int64, fields: URIFields) async -> String? {
        let failure = await perform(request.intent, account: account, fields: fields)
        if failure == nil, self.request?.id == request.id { self.request = nil }
        return failure
    }

    /// Opens the chat, joins the room or adds the contact as `account`, then shows the chat.
    private func perform(_ intent: XMPPURIIntent, account: Int64, fields: URIFields) async
        -> String?
    {
        guard let model else { return nil }
        lastUsed = account
        switch intent {
        case .openChat(let jid, let body):
            guard let chatID = await Self.chat(jid, account: account, in: model.database) else {
                return Copy.notOpened(Copy.notStored)
            }
            await show(chatID, in: model)
            if let body { prefill?(chatID, body) }
            return nil
        case .joinRoom(let room, _, _):
            guard let session = await model.sessions.session(for: account) else {
                return Copy.notJoined(Copy.notConnectedReason)
            }
            do {
                let chatID = try await session.joinRoom(
                    jid: room, nick: fields.nick, password: fields.password)
                await show(chatID, in: model)
                return nil
            } catch {
                return Copy.notJoined(Self.reason(error))
            }
        case .addContact(let jid, _):
            guard let session = await model.sessions.session(for: account) else {
                return Copy.notAdded(Copy.notConnectedReason)
            }
            // A contact already on the roster keeps its name and groups; its chat opens.
            let chatID: Int64
            do {
                try await session.addContact(jid, name: fields.name)
                chatID = try await session.startChat(with: jid)
            } catch {
                return Copy.notAdded(Self.reason(error))
            }
            await show(chatID, in: model)
            return nil
        case .register:
            return nil
        }
    }

    /// Opens the chat once the chat list has it (at most 3 s).
    private func show(_ chatID: Int64, in model: AppModel) async {
        await presenter.showAndWait()
        await model.openWhenListed(chatID: chatID)
    }

    private static func reason(_ error: SessionError) -> String {
        ChatCommandError(error).errorDescription ?? Copy.notStored
    }

    /// The account's chat with the address, whatever its kind; a new direct chat when there
    /// is none.
    @concurrent private static func chat(_ jid: JID, account: Int64, in database: AppDatabase)
        async -> Int64?
    {
        do {
            if let existing = try database.chat(accountID: account, jid: jid.description) {
                return existing.id
            }
            return try database.ensureChat(accountID: account, jid: jid.description, kind: .direct)
                .id
        } catch {
            appLog.error("Chat not stored: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The nick to start with for a room: the one the link names, else the one the account
    /// used there before, else the account's user name.
    func defaultNick(for request: URIRequest, account: Int64) -> String {
        guard case .joinRoom(let room, let nick, _) = request.intent else { return "" }
        if let nick { return nick }
        if let stored = model?.chats.first(where: {
            $0.chat.accountID == account && $0.chat.jid == room.description
        })?.chat.nick, !stored.isEmpty {
            return stored
        }
        let jid = model?.accounts.first { $0.id == account }?.jid
        return jid.flatMap { try? JID($0) }?.localpart ?? ""
    }
}

/// What the sheet lets the user change before confirming.
struct URIFields: Equatable {
    var nick = ""
    var password: String?
    var name: String?

    init(nick: String = "", password: String? = nil, name: String? = nil) {
        self.nick = nick
        self.password = password
        self.name = name
    }

    /// The fields as the link fills them in.
    init(_ intent: XMPPURIIntent) {
        switch intent {
        case .joinRoom(_, let nick, let password):
            self.init(nick: nick ?? "", password: password)
        case .addContact(_, let name):
            self.init(name: name)
        case .openChat, .register:
            self.init()
        }
    }
}
