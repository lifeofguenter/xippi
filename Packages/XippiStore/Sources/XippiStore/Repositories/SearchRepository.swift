import Foundation
import GRDB

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var messageID: Int64
    public var chatID: Int64
    public var accountID: Int64
    /// The bare JID of the contact or room.
    public var chatJID: String
    public var chatName: String?
    public var direction: MessageDirection
    public var senderJID: String?
    public var senderNick: String?
    public var body: String
    public var timestamp: Date

    public var id: Int64 { messageID }
}

extension AppDatabase {
    /// Messages whose words start with every word of `text`, newest first. Case, accents and
    /// letters such as ß or ø do not matter ("grusse" finds "Grüße"). Retracted messages are not
    /// found. `limit` is capped at 1,000.
    public func search(_ text: String, chatID: Int64? = nil, limit: Int = 200) throws -> [SearchHit]
    {
        guard limit > 0, let pattern = SearchText.pattern(for: text) else { return [] }
        var chatFilter = ""
        var arguments: StatementArguments = ["pattern": pattern, "limit": min(limit, 1000)]
        if let chatID {
            chatFilter = "AND message.chatID = :chatID"
            arguments += ["chatID": chatID]
        }
        return try reader.read { db in
            let rows = try Row.fetchAll(
                db.cachedStatement(
                    sql: """
                        SELECT message.id, message.chatID, message.accountID, chat.jid AS chatJID,
                            chat.name AS chatName, message.direction, message.senderJID, message.senderNick,
                            message.body, message.timestamp
                        FROM messageFTS
                        JOIN message ON message.id = messageFTS.rowid
                        JOIN chat ON chat.id = message.chatID
                        WHERE messageFTS MATCH :pattern \(chatFilter)
                            AND message.retracted = 0 AND message.body IS NOT NULL
                            AND NOT message.hidden
                        ORDER BY message.timestamp DESC, message.id DESC
                        LIMIT :limit
                        """),
                arguments: arguments)
            return try rows.map { row in
                SearchHit(
                    messageID: try row.decode(forColumn: "id"),
                    chatID: try row.decode(forColumn: "chatID"),
                    accountID: try row.decode(forColumn: "accountID"),
                    chatJID: try row.decode(forColumn: "chatJID"),
                    chatName: try row.decode(forColumn: "chatName"),
                    direction: try row.decode(forColumn: "direction"),
                    senderJID: try row.decode(forColumn: "senderJID"),
                    senderNick: try row.decode(forColumn: "senderNick"),
                    body: try row.decode(forColumn: "body"),
                    timestamp: try row.decode(forColumn: "timestamp"))
            }
        }
    }
}

/// Turns what a person typed into an FTS5 query. The input never reaches MATCH itself: it is cut
/// into words at anything that is not a letter, digit or mark, so no FTS5 syntax survives, and
/// each word becomes a quoted prefix term.
enum SearchText {
    /// Letters the search index spells out, as migration v2 does for message bodies. A change here
    /// needs a migration that rebuilds the index the same way.
    static let foldings: [(letter: String, replacement: String)] = [
        ("ß", "ss"), ("ẞ", "ss"), ("æ", "ae"), ("Æ", "ae"), ("œ", "oe"), ("Œ", "oe"),
        ("ø", "o"), ("Ø", "o"), ("ł", "l"), ("Ł", "l"), ("đ", "d"), ("Đ", "d"),
        ("ð", "d"), ("Ð", "d"), ("þ", "th"), ("Þ", "th"),
    ]
    static let maxWords = 16
    static let maxWordLength = 64

    static func pattern(for text: String) -> String? {
        var folded = text.precomposedStringWithCanonicalMapping
        for folding in foldings {
            folded = folded.replacingOccurrences(of: folding.letter, with: folding.replacement)
        }
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if isWordScalar(scalar) {
                word.append(scalar)
            } else if !word.isEmpty {
                words.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        guard !words.isEmpty else { return nil }
        return words.prefix(maxWords)
            .map { "\"\($0.prefix(maxWordLength))\"*" }
            .joined(separator: " ")
    }

    /// Letters, digits and combining marks: what the index's unicode61 tokenizer keeps in a word.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber,
            .nonspacingMark, .spacingMark, .enclosingMark,
            .privateUse:
            true
        default:
            false
        }
    }
}
