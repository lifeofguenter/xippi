import Foundation
import XMPPCore

/// The status the user sets for an account: available, away or do not disturb, with an
/// optional message. Kept per account by the app and sent with every presence; idle time
/// shows as away over it, never over do not disturb (`AccountSession.presenceElement`).
public struct UserStatus: Sendable, Equatable, Codable {
    public enum Show: String, Sendable, Equatable, Codable, CaseIterable {
        case available, away, doNotDisturb

        /// The presence `<show/>`: none for available.
        public var presence: Presence.Show? {
            switch self {
            case .available: nil
            case .away: .away
            case .doNotDisturb: .dnd
            }
        }
    }

    /// The longest message kept, in characters.
    public static let maxMessageLength = 200

    public var show: Show
    /// One line, trimmed, at most `maxMessageLength` characters; nil when blank.
    public private(set) var message: String?

    public static let available = UserStatus(show: .available, message: nil)

    public init(show: Show, message: String?) {
        self.show = show
        self.message = Self.normalised(message)
    }

    private enum CodingKeys: String, CodingKey {
        case show, message
    }

    /// The stored form is read like typed text: an unknown show is available, and the
    /// message is normalised again.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let show = try container.decodeIfPresent(String.self, forKey: .show)
        self.init(
            show: show.flatMap(Show.init(rawValue:)) ?? .available,
            message: try container.decodeIfPresent(String.self, forKey: .message))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(show, forKey: .show)
        try container.encodeIfPresent(message, forKey: .message)
    }

    private static func normalised(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxMessageLength)).trimmingCharacters(in: .whitespaces)
    }
}

extension AccountSession {
    /// `setStatus(show:text:)` with the status as the user set it.
    public func setStatus(_ status: UserStatus) async {
        await setStatus(show: status.show.presence, text: status.message)
    }
}
