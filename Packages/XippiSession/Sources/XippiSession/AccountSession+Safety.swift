import Foundation
import XMPPCore
import XippiStore
import os

/// What Block or Report did to someone in a room or channel.
public enum SafetyOutcome: Sendable, Equatable {
    case done
    /// Ignored on this Mac, but the server did not take the block or report (m6): the error
    /// says why.
    case ignoredOnly(SessionError)
}

/// Block and Report on a `SafetyTarget` (spec 13, App Review guideline 1.2, ruling R72).
extension AccountSession {
    /// A contact is blocked on the server (XEP-0191). Someone in a room or channel is ignored
    /// on this Mac by every identity known first, then their real JID, where the room shows
    /// it, is blocked on the server as well.
    @discardableResult
    public func block(_ target: SafetyTarget) async throws(SessionError) -> SafetyOutcome {
        switch target {
        case .contact(let jid):
            try await block(jid)
            return .done
        case .participant(let participant):
            try ignore(participant)
            guard let realJID = participant.realJID else { return .done }
            do {
                try await block(realJID)
            } catch {
                return .ignoredOnly(error)
            }
            return .done
        }
    }

    /// Blocks and reports as spam (XEP-0377), naming the stored messages given by their
    /// archive's stanza id. Someone in a room or channel is ignored on this Mac first, then
    /// reported by their real JID where known, else by the address the room sends their
    /// messages from.
    @discardableResult
    public func report(_ target: SafetyTarget, messageIDs: [Int64] = []) async throws(SessionError)
        -> SafetyOutcome
    {
        switch target {
        case .contact(let jid):
            try await report(jid, reason: .spam, messageIDs: messageIDs)
            return .done
        case .participant(let participant):
            try ignore(participant)
            guard let item = participant.realJID ?? participant.address else { return .done }
            do {
                try await report(item, reason: .spam, messageIDs: messageIDs)
            } catch {
                return .ignoredOnly(error)
            }
            return .done
        }
    }

    /// Takes back everything Block and Report did (N2): every entry that ignores the
    /// participant here first, then the server's entries for their real JID and for the room
    /// address a report blocked. A server without a blocklist (XEP-0191) has nothing to take
    /// back: `.ignoredOnly(.unavailable)` says so (m-5).
    @discardableResult
    public func unblock(_ target: SafetyTarget) async throws(SessionError) -> SafetyOutcome {
        switch target {
        case .contact(let jid):
            try await unblock(jid)
            return .done
        case .participant(let participant):
            do {
                try database.unignore(participant, accountID: accountID)
            } catch {
                throw .storage(String(describing: error))
            }
            reloadIgnoreList()
            let onServer = participant.realJID != nil || participant.address.map(isBlocked) == true
            guard live else { return onServer ? .ignoredOnly(.notConnected) : .done }
            guard serverFeatures.contains(Blocking.namespace) else {
                return onServer ? .ignoredOnly(.unavailable) : .done
            }
            // Only what the server holds (m-17): a block it refused has nothing to take back.
            // Once this Mac's part is done, a refusal is that part's outcome, not a failure.
            let held = [participant.realJID, participant.address].compactMap { $0 }
                .filter { isBlocked($0) }
            do {
                for jid in held { try await unblock(jid) }
            } catch {
                return .ignoredOnly(error)
            }
            return .done
        }
    }

    private func ignore(_ participant: SafetyTarget.Participant) throws(SessionError) {
        do {
            try database.ignore(
                participant.entries(accountID: accountID, at: environment.now()))
        } catch {
            throw .storage(String(describing: error))
        }
        reloadIgnoreList()
    }

    /// The account's ignore list, kept in the session (m4): read once, then followed.
    func currentIgnoreList() -> IgnoreList {
        if let ignoreCache { return ignoreCache }
        reloadIgnoreList()
        return ignoreCache ?? IgnoreList([])
    }

    /// Reads the list again; a failed read keeps the last one.
    func reloadIgnoreList() {
        do {
            ignoreCache = try database.ignoreList(accountID: accountID)
        } catch {
            Self.log.error("Ignore list not read")
        }
    }

    /// Follows changes made outside the session (Settings) while it runs.
    func followIgnoreList() {
        guard ignoreFollower == nil else { return }
        let updates = database.ignoreListUpdates(accountID: accountID)
        ignoreFollower = Task { [weak self] in
            for await list in updates {
                await self?.setIgnoreCache(list)
            }
        }
    }

    private func setIgnoreCache(_ list: IgnoreList) {
        ignoreCache = list
    }

    /// Whether a room or channel message comes from someone the account ignores (R72). With
    /// a real JID ignored and none shown with the message, the one the channel stamped or the
    /// one the room showed for the sender's id earlier counts (C1).
    func isIgnored(_ sender: IgnoreList.Sender, stampedJID: JID? = nil) -> Bool {
        let list = currentIgnoreList()
        guard !list.isEmpty else { return false }
        if list.covers(sender) { return true }
        guard sender.realJID == nil, list.hasRealJIDs,
            let realJID = stampedJID?.bare.description ?? pairedRealJID(of: sender)
        else { return false }
        var known = sender
        known.realJID = realJID
        return list.covers(known)
    }

    /// The real JID the room or channel showed earlier for the sender's occupant id or
    /// participant id.
    private func pairedRealJID(of sender: IgnoreList.Sender) -> String? {
        let pair: (kind: IgnoredParticipant.Kind, value: String)?
        if let occupantID = sender.occupantID {
            pair = (.occupantID, occupantID)
        } else if sender.kind == .channel, let address = sender.senderJID,
            let slash = address.firstIndex(of: "/")
        {
            pair = (.participantID, String(address[address.index(after: slash)...]))
        } else {
            pair = nil
        }
        guard let pair else { return nil }
        return try? database.pairedRealJID(
            accountID: accountID, room: sender.room, kind: pair.kind, value: pair.value)
    }

    /// N3: an unblock from any device (the server's push) also drops the real JIDs' entries
    /// here, with the occupant ids and participant ids the rooms paired with them (m-3);
    /// "unblock everything" drops every real-JID entry and theirs. Other entries by occupant
    /// id, participant id or nick are this Mac's alone and stay (m-18).
    func blockPushUnblocked(_ jids: [JID]?) {
        do {
            if let jids {
                for jid in jids where jid.resourcepart == nil {
                    try database.unignore(accountID: accountID, realJID: jid.description)
                }
            } else {
                try database.unignoreAllRealJIDs(accountID: accountID)
            }
        } catch {
            Self.log.error("Ignore entries not dropped after an unblock")
        }
        reloadIgnoreList()
    }
}

extension AppDatabase {
    /// Drops every entry that ignores the participant on this Mac (R72): what Unblock does
    /// here, with or without a connection.
    public func unignore(_ participant: SafetyTarget.Participant, accountID: Int64) throws {
        for key in participant.keys {
            if key.kind == .realJID {
                try unignore(accountID: accountID, realJID: key.value)
            } else {
                try unignore(
                    accountID: accountID, room: participant.room.description, kind: key.kind,
                    value: key.value)
            }
        }
    }
}
