import Foundation
import XMPPCore

/// Whether a contact takes chat state notifications (XEP-0085 5.1).
///
/// The contact's own messages decide first: one carrying a chat state shows support; a reply
/// with content but no chat state withdraws it ("the User MUST NOT send subsequent chat state
/// notifications"), until a chat state comes again. Without such a message the contact's
/// online devices decide, by their disco#info: cached by caps ver when the answer proves the
/// ver (XEP-0115 5.4), else for that device (and that ver) only. One device with chat states
/// is enough; a contact with no device online takes none.
struct ChatStateSupport: Sendable {
    enum Answer: Sendable, Equatable {
        case supported
        case unsupported
        /// Some online device has not been asked yet.
        case unknown
    }

    /// One online device of the contact: its full JID and the caps its presence carried.
    struct Device: Sendable, Hashable {
        var jid: String
        var caps: Caps.Advertisement?
    }

    /// What the contact's own messages showed last, by bare JID.
    private var shown: [String: Bool] = [:]
    /// Proven caps vers, shared by every device that advertises them.
    private var byVer: [String: Bool] = [:]
    /// Answers that prove nothing beyond the device that gave them, by full JID and ver.
    private var byDevice: [String: Bool] = [:]
    /// When a device last left the question unanswered, by full JID and ver.
    private var unanswered: [String: Date] = [:]

    /// A live message from the contact.
    mutating func received(from peer: String, chatState: Bool, content: Bool) {
        if chatState {
            shown[peer] = true
        } else if content {
            shown[peer] = false
        }
    }

    func answer(for peer: String, devices: [Device]) -> Answer {
        if let shown = shown[peer] { return shown ? .supported : .unsupported }
        var unknown = false
        for device in devices {
            switch known(device) {
            case true?: return .supported
            case false?: continue
            case nil: unknown = true
            }
        }
        return unknown ? .unknown : .unsupported
    }

    /// How long a device that did not answer is left alone before it is asked again.
    static let askAgainAfter: TimeInterval = 300

    /// Whether the contact's own replies came without chat states (rule 2): then even a
    /// content message carries none, until a chat state comes from it again.
    func withdrawn(by peer: String) -> Bool {
        shown[peer] == false
    }

    /// The devices to ask: those whose answer is not known, leaving out one that did not
    /// answer until `askAgainAfter` has passed.
    func undiscovered(_ devices: [Device], at now: Date) -> [Device] {
        devices.filter { device in
            guard known(device) == nil else { return false }
            guard let asked = unanswered[Self.key(device)] else { return true }
            return now.timeIntervalSince(asked) >= Self.askAgainAfter
        }
    }

    mutating func learned(_ device: Device, supports: Bool, verified: Bool) {
        if verified, let ver = device.caps?.ver { byVer[ver] = supports }
        byDevice[Self.key(device)] = supports
        unanswered[Self.key(device)] = nil
    }

    /// The device did not answer (a timeout, a session that ended): not known, which is not
    /// "no" (a phone held by its server answers once it wakes).
    mutating func unanswered(_ device: Device, at now: Date) {
        unanswered[Self.key(device)] = now
    }

    private func known(_ device: Device) -> Bool? {
        byDevice[Self.key(device)] ?? device.caps.flatMap { byVer[$0.ver] }
    }

    /// A device that changes its caps (a new client version) is asked again.
    private static func key(_ device: Device) -> String {
        device.jid + " " + (device.caps?.ver ?? "")
    }
}

/// A chat state waiting for the contact's devices to say whether they take chat states
/// (I6): it goes only if it is still the newest one and no message went in the chat since.
struct HeldChatState: Sendable {
    var peer: String
    var state: ChatState
    /// The chat's count of sent messages when it was asked for.
    var sent: Int
}

/// A device's disco#info answer about chat states: whether it lists them, and whether the
/// answer proves its caps ver (so it holds for every device with that ver).
struct ChatStateDiscovery: Sendable {
    var supports: Bool
    var verified: Bool
}
