import Foundation
import XMPPCore

/// The parts of the account's own profile the user edits (vCard4, XEP-0292): full name,
/// nickname, one email address, a web page and a note. Everything else the vCard holds is
/// kept as it is when they are published (`applied(to:)`).
///
/// Typed in by the user, so checked here before anything is sent (`problems`): blanks are
/// trimmed, each field has a length bound, the email must look like one address and the web
/// page must be an `http` or `https` address with a host.
public struct ProfileFields: Codable, Sendable, Equatable {
    public enum Field: String, Codable, Sendable, CaseIterable {
        case fullName, nickname, email, webPage, note
    }

    public enum Problem: Sendable, Hashable {
        case tooLong(Field)
        case invalidEmail
        case invalidWebPage
    }

    public var fullName: String
    public var nickname: String
    public var email: String
    public var webPage: String
    public var note: String

    public static let maxName = 256
    /// RFC 5321's limit for a path.
    public static let maxEmail = 254
    public static let maxWebPage = 2048
    public static let maxNote = 2000

    public init(
        fullName: String = "", nickname: String = "", email: String = "", webPage: String = "",
        note: String = ""
    ) {
        self.fullName = fullName
        self.nickname = nickname
        self.email = email
        self.webPage = webPage
        self.note = note
    }

    /// The fields a profile shows: its first email address.
    public init(_ profile: Profile) {
        self.init(
            fullName: profile.fullName ?? "", nickname: profile.nickname ?? "",
            email: profile.emails.first ?? "", webPage: profile.url?.absoluteString ?? "",
            note: profile.note ?? "")
    }

    /// The fields kept in the account's own profile row; nil when the row holds none.
    public init?(stored data: Data) {
        guard !data.isEmpty, let fields = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = fields
    }

    var stored: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Without blanks around each value (the note keeps its inner lines).
    public var normalized: ProfileFields {
        func trim(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ProfileFields(
            fullName: trim(fullName), nickname: trim(nickname), email: trim(email),
            webPage: trim(webPage), note: trim(note))
    }

    /// What keeps the fields from being published; empty when they can be.
    public var problems: [Problem] {
        let fields = normalized
        var problems: [Problem] = []
        let limits: [(Field, String, Int)] = [
            (.fullName, fields.fullName, Self.maxName), (.nickname, fields.nickname, Self.maxName),
            (.email, fields.email, Self.maxEmail), (.webPage, fields.webPage, Self.maxWebPage),
            (.note, fields.note, Self.maxNote),
        ]
        for (field, value, limit) in limits where value.count > limit {
            problems.append(.tooLong(field))
        }
        if !fields.email.isEmpty, !Self.isEmail(fields.email) { problems.append(.invalidEmail) }
        if !fields.webPage.isEmpty, Self.webURL(fields.webPage) == nil {
            problems.append(.invalidWebPage)
        }
        return problems
    }

    /// `profile` with these fields written in; its other properties, and its other email
    /// addresses, stay. Call on fields without `problems`.
    public func applied(to profile: Profile) -> Profile {
        let fields = normalized
        var profile = profile
        profile.fullName = fields.fullName.isEmpty ? nil : fields.fullName
        profile.nickname = fields.nickname.isEmpty ? nil : fields.nickname
        var emails = profile.emails
        if fields.email.isEmpty {
            if !emails.isEmpty { emails.removeFirst() }
        } else if emails.isEmpty {
            emails = [fields.email]
        } else {
            emails[0] = fields.email
        }
        profile.emails = emails
        profile.url = Self.webURL(fields.webPage)
        profile.note = fields.note.isEmpty ? nil : fields.note
        return profile
    }

    /// One address: a local part and a domain with a dot, no spaces or controls, one `@`.
    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
            !parts[1].hasPrefix("."), !parts[1].hasSuffix(".")
        else { return false }
        return !text.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }
    }

    /// An `http` or `https` address with a host.
    static func webURL(_ text: String) -> URL? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
