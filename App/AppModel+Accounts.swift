import Foundation
import XMPPCore
import XippiSession
import XippiStore
import os

/// How adding an account ended.
enum AddAccountOutcome: Equatable {
    case added
    /// What to show under the fields.
    case failed(String)
    /// The server's certificate was not accepted: show it.
    case certificate(ServerCertificateProblem)
    case cancelled
}

/// The accounts: adding (checked against the server first), enabling, removing, trusting a
/// certificate, changing the password, and the calls of their sessions.
extension AppModel {
    /// The status of each stored account, as the footer and the settings show it.
    func status(of account: AccountRecord) -> AccountStatus {
        AccountStatus(
            state: account.id.flatMap { status.connection[$0] }, enabled: account.enabled)
    }

    /// Whether any account is online, for the menu bar icon.
    var anyAccountOnline: Bool {
        status.connection.values.contains { if case .online = $0 { true } else { false } }
    }

    func reloadAccounts() async {
        let fresh = await Self.fetchAccounts(database)
        if fresh != accounts { accounts = fresh }
    }

    /// Validates the address and the password, logs in once with them, and only then keeps
    /// the password and the account and starts its session. `server` is `host` or
    /// `host:port`, empty to look the domain up; `pinned` holds certificates the user trusted.
    func addAccount(address: String, password: String, server: String, pinned: [String]) async
        -> AddAccountOutcome
    {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = try? JID(trimmed) else { return .failed(Copy.invalidAccountAddress) }
        guard parsed.localpart != nil else { return .failed(Copy.addressWithoutUser) }
        let jid = parsed.bare
        guard !password.isEmpty else { return .failed(Copy.passwordRequired) }
        // An existing account's password: what this client can log in with, an emoji in it
        // included. New passwords (registration, a change) are held to the stricter rule.
        guard SASLSelector.canAuthenticate(withPassword: password) else {
            return .failed(Copy.passwordNotUsable)
        }
        let endpoint: ServerAddress?
        do {
            endpoint = try ServerAddress.parse(server)
        } catch {
            return .failed(Copy.invalidServer)
        }
        let account = AccountRecord(
            jid: jid.description, enabled: true, resource: "", clientID: UUID().uuidString,
            hostOverride: endpoint?.host, portOverride: endpoint?.port,
            directTLSOverride: endpoint.map(\.directTLS), pinnedCertSHA256: pinned,
            rosterVersion: nil, smResume: nil, createdAt: Date())
        // The manager adds one account per address at a time, logs in before writing
        // anything, and removes only the keychain items it wrote itself.
        switch await sessions.add(account: account, password: password) {
        case .added: break
        case .duplicate: return .failed(Copy.accountExists)
        case .refused(.loginFailed(let condition, _)): return .failed(Copy.loginFailed(condition))
        case .refused(.certificateRejected(let problem)): return .certificate(problem)
        case .refused(.unreachable(let problem)):
            return .failed(Copy.connectionProblem(problem))
        case .refused(.invalidAccount): return .failed(Copy.addressWithoutUser)
        case .refused(.online), .refused(.cancelled), .cancelled: return .cancelled
        case .passwordNotStored: return .failed(Copy.passwordNotSaved)
        case .accountNotStored: return .failed(Copy.accountNotSaved)
        }
        await reloadAccounts()
        await attachCalls()
        return .added
    }

    /// A registration (XEP-0077) at `domain`, connecting the way an account does: to `server`
    /// when given, with the certificates in `pinned` trusted.
    func registrationClient(domain: String, server: ServerAddress?, pinned: [String])
        -> RegistrationClient
    {
        RegistrationClient(
            domain: domain, endpointOverride: server?.endpoint,
            environment: services.connectionEnvironment(pinned: pinned))
    }

    func setEnabled(_ enabled: Bool, accountID: Int64) async {
        do {
            try await sessions.setEnabled(enabled, accountID: accountID)
        } catch {
            appLog.error("Account not changed: \(String(describing: error), privacy: .private)")
        }
        await reloadAccounts()
        await attachCalls()
    }

    /// Starts the account's session again: a new login, also after a refused one.
    func reconnect(accountID: Int64) async {
        do {
            try await sessions.restart(accountID: accountID)
        } catch {
            appLog.error("Reconnect failed: \(String(describing: error), privacy: .private)")
        }
        await attachCalls()
    }

    /// Ends the account's session and deletes it with its chats, messages and password. When
    /// the account cannot be deleted, its password stays.
    func removeAccount(_ account: AccountRecord) async {
        guard let accountID = account.id else { return }
        do {
            try await sessions.remove(accountID: accountID)
        } catch {
            appLog.error("Account not removed: \(String(describing: error), privacy: .private)")
            await reloadAccounts()
            return
        }
        if let jid = try? JID(account.jid) {
            await Self.removeSecrets(of: jid, from: services.credentials)
        }
        callSources[accountID] = nil
        await reloadAccounts()
        refreshCallTarget()
    }

    /// Deletes the account on its server (XEP-0077), then removes it here; the reason it was
    /// not deleted, or nil.
    func deleteAccount(_ account: AccountRecord) async -> String? {
        guard let accountID = account.id, let session = await sessions.session(for: accountID)
        else { return Copy.accountNotDeleted(.notConnected) }
        do {
            try await session.deleteFromServer()
        } catch {
            return Copy.accountNotDeleted(error)
        }
        await removeAccount(account)
        return nil
    }

    /// Pins the certificate on the account and connects again with it trusted.
    func trust(_ review: CertificateReview) async {
        await Self.pin(review.problem.sha256, accountID: review.accountID, in: database)
        await reloadAccounts()
        await reconnect(accountID: review.accountID)
    }

    /// Changes the password on the server and here; the reason it was not changed, or nil.
    func changePassword(_ password: String, accountID: Int64) async -> String? {
        guard let session = await sessions.session(for: accountID) else {
            return Copy.passwordNotChanged(.notConnected)
        }
        do {
            try await session.changePassword(password)
            return nil
        } catch {
            return Copy.passwordNotChanged(error)
        }
    }

    // MARK: Calls

    /// Hands every session's calls to the call UI once: sessions started since the last call,
    /// and the new session of an account that was restarted, enabled again or trusted. An
    /// account without a session (disabled, removed) loses its calls.
    func attachCalls() async {
        let running = await sessions.activeSessions
        let runningIDs = Set(running.map(\.accountID))
        callSources = callSources.filter { runningIDs.contains($0.key) }
        for session in running {
            guard callSources[session.accountID]?.session !== session,
                let events = session.callEvents, let manager = session.callManager
            else { continue }
            let source = calls.attach(events: events, actions: manager)
            callSources[session.accountID] = AttachedCalls(session: session, source: source)
        }
        refreshCallTarget()
    }

    /// The open chat can be called when it is a one-to-one chat with a contact in the roster,
    /// on an account whose calls are attached. The contact's roster row is followed while the
    /// chat is open, so the call buttons change as the roster does.
    func refreshCallTarget() {
        callTargetTask?.cancel()
        // A private chat with a room occupant is never called: the room hides who it is.
        guard let chat = openChat, chat.kind == .direct,
            let source = callSources[chat.accountID]?.source,
            let peer = try? JID(chat.jid)
        else {
            if callTarget != nil { callTarget = nil }
            return
        }
        let rows = database.rosterItemUpdates(accountID: chat.accountID, jid: chat.jid)
        callTargetTask = Task { [weak self] in
            for await row in rows {
                guard let self, self.openChat?.id == chat.id else { return }
                let target =
                    row == nil
                    ? nil
                    : CallTarget(
                        chatID: chat.id, accountID: chat.accountID, peer: peer, source: source)
                if self.callTarget != target { self.callTarget = target }
            }
        }
    }

    /// Whether the open chat can be called now: a contact on an account that is online.
    var canCall: Bool {
        guard let target = callTarget, target.chatID == openChat?.id,
            case .online = status.connection[target.accountID]
        else { return false }
        return callSources[target.accountID]?.source == target.source
    }

    func startCall(video: Bool) {
        guard canCall, let target = callTarget else { return }
        calls.startCall(to: target.peer, video: video, from: target.source)
    }

    // MARK: Database work, off the main actor

    @concurrent private static func fetchAccounts(_ database: AppDatabase) async
        -> [AccountRecord]
    {
        do {
            return try database.accounts()
        } catch {
            appLog.error("Accounts not read: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Deletes the account's keychain items off the main actor: a keychain call can wait.
    @concurrent private static func removeSecrets(of jid: JID, from store: any CredentialStore)
        async
    {
        do {
            try store.remove(for: jid)
        } catch {
            appLog.error("Password not removed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Adds the fingerprint to the account's pins; the rest of the account is read fresh and
    /// written back at once.
    @concurrent private static func pin(
        _ sha256: String, accountID: Int64, in database: AppDatabase
    )
        async
    {
        do {
            guard var account = try database.account(id: accountID) else { return }
            guard !account.pinnedCertSHA256.contains(sha256) else { return }
            account.pinnedCertSHA256.append(sha256)
            try database.updateAccount(account)
        } catch {
            appLog.error("Certificate not pinned: \(String(describing: error), privacy: .private)")
        }
    }
}
