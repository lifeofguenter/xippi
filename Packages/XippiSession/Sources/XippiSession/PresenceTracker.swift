import Foundation
import XMPPCore

/// The presence of every device the account hears from, and what each contact shows overall.
///
/// Available presence replaces a device's earlier one; unavailable presence removes the device,
/// or every device when it comes from the bare JID. A fresh session starts empty: the server
/// sends every contact's presence again after the initial presence.
struct PresenceTracker {
    /// By bare JID, then resource ("" for presence from the bare JID).
    private var devices: [JID: [String: Presence]] = [:]

    /// Applies an available or unavailable presence. Returns the bare JID whose summary may
    /// have changed, or nil when the presence was of another type.
    mutating func apply(_ presence: Presence) -> JID? {
        guard let from = presence.from else { return nil }
        let bare = from.bare
        let resource = from.resourcepart ?? ""
        switch presence.type {
        case .available:
            devices[bare, default: [:]][resource] = presence
        case .unavailable:
            if resource.isEmpty {
                devices[bare] = nil
            } else {
                devices[bare]?[resource] = nil
                if devices[bare]?.isEmpty == true { devices[bare] = nil }
            }
        default:
            return nil
        }
        return bare
    }

    /// Forgets everyone; returns the bare JIDs that were online.
    mutating func removeAll() -> [JID] {
        defer { devices = [:] }
        return Array(devices.keys)
    }

    func isOnline(_ jid: JID) -> Bool {
        devices[jid.bare]?.isEmpty == false
    }

    /// The devices online for `jid`'s bare JID.
    func resources(of jid: JID) -> [String: Presence] {
        devices[jid.bare] ?? [:]
    }

    /// What the contact shows: the device with the highest priority, and among those the most
    /// available; nil when no device is online.
    func summary(for jid: JID) -> PresenceSummary? {
        guard let online = devices[jid.bare], !online.isEmpty else { return nil }
        let best = online.values.max { lhs, rhs in
            (lhs.priority, Self.rank(lhs.show)) < (rhs.priority, Self.rank(rhs.show))
        }
        guard let best else { return nil }
        return PresenceSummary(
            availability: Self.availability(best.show), status: best.status,
            idleSince: best.idleSince, resources: online.count)
    }

    static func availability(_ show: Presence.Show?) -> PresenceSummary.Availability {
        switch show {
        case nil: .available
        case .chat: .chat
        case .away: .away
        case .xa: .extendedAway
        case .dnd: .doNotDisturb
        }
    }

    /// Higher is more available.
    private static func rank(_ show: Presence.Show?) -> Int {
        switch show {
        case .chat: 4
        case nil: 3
        case .away: 2
        case .xa: 1
        case .dnd: 0
        }
    }
}
