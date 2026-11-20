import Foundation
import XMPPCore
import XippiStore

/// What a reply quotes of the message it answers (ruling R63 b).
///
/// The quote a reply shows here is the target's text, else its file's name: never a file's
/// link, which for an encrypted file carries the key. The reply's fallback (XEP-0461, the
/// "> " lines for clients without replies) carries that quote only when the target came in
/// the clear or the reply is encrypted itself; otherwise only the reference goes out.
public enum ReplyQuote {
    /// Whether the reply's fallback may carry the quote: never content that came encrypted
    /// in a reply that goes out in the clear.
    public static func goesOut(targetEncryption: EncryptionMode, replyEncrypted: Bool) -> Bool {
        replyEncrypted || targetEncryption == .none
    }

    /// The quote of a message with `body` and its first file's `fileName` and `link`: the
    /// text, else the file's name. A body that is only a file's link (the attachment's, or
    /// any `aesgcm://` one) is no text.
    public static func text(body: String?, fileName: String?, link: String? = nil) -> String? {
        if let body {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != link, !isEncryptedFileLink(trimmed) { return body }
        }
        guard let fileName, !fileName.isEmpty else { return nil }
        return fileName
    }

    /// The quote a reply came with, kept when the message it answers is not here: none when
    /// it is only an encrypted file's link.
    public static func received(_ quote: String?) -> String? {
        guard let quote,
            !isEncryptedFileLink(quote.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return quote
    }

    /// The quote of the stored message `target`, cut to `limit` characters.
    static func text(of target: MessageRecord, in database: AppDatabase, limit: Int) -> String? {
        let file = target.id.flatMap { try? database.attachments(messageID: $0).first }
        return text(body: target.body, fileName: file?.fileName, link: file?.remoteURL)
            .map { String($0.prefix(limit)) }
    }

    static func isEncryptedFileLink(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace)
            && text.lowercased().hasPrefix(AESGCMFile.scheme + "://")
    }
}
