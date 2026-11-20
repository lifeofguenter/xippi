import Foundation
import Observation
import XippiSession
import XippiStore
import os

/// The status the user set for each account (available, away, do not disturb, and a
/// message), kept across launches in `UserDefaults` by account address and handed to the
/// sessions: before they start at launch, and at once when it changes.
@MainActor @Observable final class UserStatusController {
    /// By the account's bare JID.
    private(set) var statuses: [String: UserStatus]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessions: SessionManager
    /// The last change handed to the sessions; the next one waits for it, so they arrive in
    /// order.
    @ObservationIgnored private var applying: Task<Void, Never>?
    @ObservationIgnored private var knownAccounts: Set<String> = []
    @ObservationIgnored fileprivate var following: Task<Void, Never>?

    static let key = "eu.xippi.userStatus"

    isolated deinit {
        following?.cancel()
    }

    /// - Parameter defaults: where the statuses are kept; UI test launches keep them apart.
    init(sessions: SessionManager, defaults: UserDefaults = LaunchDefaults.make("status")) {
        self.sessions = sessions
        self.defaults = defaults
        statuses = Self.read(from: defaults)
    }

    func status(of account: AccountRecord) -> UserStatus {
        statuses[account.jid] ?? .available
    }

    /// Do not disturb, for the notifications of the account.
    func isDoNotDisturb(accountID: Int64, accounts: [AccountRecord]) -> Bool {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return false }
        return status(of: account).show == .doNotDisturb
    }

    /// The one show every account has; nil when they differ or there are none.
    func commonShow(of accounts: [AccountRecord]) -> UserStatus.Show? {
        let shows = Set(accounts.map { status(of: $0).show })
        return shows.count == 1 ? shows.first : nil
    }

    func set(_ status: UserStatus, for account: AccountRecord) {
        guard let id = account.id, status != self.status(of: account) else { return }
        statuses[account.jid] = status == .available ? nil : status
        save()
        apply(status, accountID: id)
    }

    /// Changes the show of every account, keeping each one's message.
    func setShow(_ show: UserStatus.Show, for accounts: [AccountRecord]) {
        for account in accounts {
            set(UserStatus(show: show, message: status(of: account).message), for: account)
        }
    }

    /// The stored statuses to the sessions, before they start.
    func prepare(accounts: [AccountRecord]) async {
        knownAccounts = Set(accounts.map(\.jid))
        for account in accounts {
            guard let id = account.id, let status = statuses[account.jid] else { continue }
            await sessions.setStatus(status, accountID: id)
        }
    }

    /// Drops the status of an account that was removed, so its address added again starts
    /// available. Only an address seen in the list before counts as removed.
    func accountsChanged(_ accounts: [AccountRecord]) {
        let current = Set(accounts.map(\.jid))
        let removed = knownAccounts.subtracting(current)
        knownAccounts = current
        guard !removed.isEmpty, removed.contains(where: { statuses[$0] != nil }) else { return }
        for jid in removed { statuses[jid] = nil }
        save()
    }

    private func apply(_ status: UserStatus, accountID: Int64) {
        let previous = applying
        let sessions = sessions
        applying = Task {
            await previous?.value
            await sessions.setStatus(status, accountID: accountID)
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(statuses), forKey: Self.key)
        } catch {
            appLog.error("Status not saved")
        }
    }

    private static func read(from defaults: UserDefaults) -> [String: UserStatus] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: UserStatus].self, from: data)) ?? [:]
    }
}

extension UserStatusController {
    /// Follows the account list, to drop the statuses of removed accounts.
    func follow(_ model: AppModel) {
        let accounts = Observations { @MainActor [weak model] in model?.accounts ?? [] }
        following?.cancel()
        following = Task { [weak self] in
            for await list in accounts {
                self?.accountsChanged(list)
            }
        }
    }
}
