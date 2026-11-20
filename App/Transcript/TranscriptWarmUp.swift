import Foundation
import XippiStore

/// What the first chat opened after launch would otherwise pay on its own, paid off the main
/// thread once the first chat list is drawn (spec 10): a page of the chat likely opened first
/// read as the transcript reads it (the database's statements and pages), and styled and
/// measured as the transcript does (fonts, the text system, the emoji font).
enum TranscriptWarmUp {
    /// The width rows are measured at here: any width warms the same caches.
    static let width: CGFloat = 640

    @concurrent static func run(
        chat: TranscriptChat, database: AppDatabase, fontSize: CGFloat
    ) async {
        guard
            let page = try? database.page(
                chatID: chat.id, before: nil, limit: TranscriptController.tailPage),
            let items = try? database.transcriptItems(for: page)
        else { return }
        _ = TranscriptPreparation.prepare(
            TranscriptPreparation.Input(
                items: items, styled: [:], chat: chat, unreadBefore: nil, highlighted: nil,
                width: width, fontSize: fontSize, calendar: .current, layouts: [:],
                eventHeights: [:]))
    }
}
