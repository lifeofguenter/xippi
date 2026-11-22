import AppKit
import XippiSession
import XippiStore

/// What decides about a chat's senders: the chat (its kind and encryption) and the bare JIDs
/// in the account's roster, for link previews (`LinkPreviewTrust`) and maps (`LocationTrust`).
struct SenderTrust: Sendable {
    var chat: ChatRecord
    var roster: Set<String>
}

/// A message body and the text it was styled from, so a correction restyles it, with the
/// body's first http(s) link.
struct StyledEntry: Sendable {
    var source: String
    var text: StyledText
    var link: URL?
}

/// A message row's frames at one width.
struct CachedLayout: Sendable {
    var width: CGFloat
    var model: MessageRowModel
    var layout: MessageLayout
}

/// A centred event row's height at one width.
struct CachedHeight: Sendable {
    var width: CGFloat
    var text: String
    var height: CGFloat
}

/// Everything the transcript does before the table sees a change, off the main thread: styling
/// new text, building rows, and measuring every row at the table's width. The main thread then
/// only reloads and scrolls.
enum TranscriptPreparation {
    struct Input: Sendable {
        var items: [TranscriptItem]
        var styled: [Int64: StyledEntry]
        var chat: TranscriptChat
        var unreadBefore: Int64?
        var highlighted: Int64?
        /// Zero before the table is laid out: rows are then measured on the main thread later.
        var width: CGFloat
        var fontSize: CGFloat
        /// Where days begin: the viewer's calendar and time zone.
        var calendar: Calendar
        var layouts: [Int64: CachedLayout]
        var eventHeights: [Int64: CachedHeight]
        /// Fetched link previews, by message.
        var linkPreviews: [Int64: LinkPreview] = [:]
        /// Nil until loaded: locations show as coordinates meanwhile (R62).
        var trust: SenderTrust?
        /// The user's keywords: marked where others write them, with the room nick.
        var keywords: [String] = []
        /// Messages from distrusted devices whose text the user showed.
        var revealed: Set<Int64> = []
        /// History missing from the chat's archive, and the gaps being loaded.
        var gaps: [ArchiveGap] = []
        var loadingGaps: Set<Int64> = []
        /// Where stored files are found, for the pictures that show as themselves.
        var media: MediaLibrary?
    }

    struct Output: Sendable {
        var rows: [TranscriptRow]
        /// Entries for the messages in `rows` only, so the cache never outgrows what is loaded.
        var styled: [Int64: StyledEntry]
        var layouts: [Int64: CachedLayout]
        var eventHeights: [Int64: CachedHeight]
    }

    @concurrent static func run(_ input: Input) async -> Output {
        prepare(input)
    }

    /// A distrusted device's message: its text once shown, else "Text hidden" and a Show link
    /// that the cell takes (`MessageTextView`).
    static func distrustedEntry(
        _ item: TranscriptItem, revealed: Bool, cached: [Int64: StyledEntry], size: CGFloat
    ) -> StyledEntry {
        let palette = TranscriptColors.palette(outgoing: false)
        let text = revealed ? item.message.distrustedText ?? "" : ""
        // A source of its own for the hidden form, so showing restyles it.
        let source = revealed ? text : "\u{0}hidden"
        if let entry = cached[item.id], entry.source == source { return entry }
        if revealed {
            return StyledEntry(
                source: source,
                text: StyledText(
                    string: MessageStyling.attributed(text, size: size, palette: palette)),
                link: nil)
        }
        let hidden = NSMutableAttributedString(
            string: Copy.textHidden + "  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: palette.quote,
            ])
        hidden.append(
            NSAttributedString(
                string: Copy.showText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .link: MessageTextView.revealLink(item.id),
                ]))
        return StyledEntry(source: source, text: StyledText(string: hidden), link: nil)
    }

    /// The keywords and the room nick, marked on the text's background (spec 5.1).
    static func highlighted(_ text: NSAttributedString, matcher: KeywordMatcher)
        -> NSAttributedString
    {
        let string = text.string
        let ranges = matcher.ranges(in: string)
        guard !ranges.isEmpty else { return text }
        let marked = NSMutableAttributedString(attributedString: text)
        for range in ranges {
            marked.addAttribute(
                .backgroundColor, value: TranscriptColors.keyword, range: NSRange(range, in: string)
            )
        }
        return marked
    }

    static func prepare(_ input: Input) -> Output {
        var styled: [Int64: StyledEntry] = [:]
        styled.reserveCapacity(input.items.count)
        let matcher = KeywordMatcher(keywords: input.keywords, nickname: input.chat.ownNick)
        for item in input.items {
            let message = item.message
            if message.isFromDistrustedDevice {
                styled[item.id] = distrustedEntry(
                    item, revealed: input.revealed.contains(item.id), cached: input.styled,
                    size: input.fontSize)
                continue
            }
            guard !message.retracted, let body = message.body, !body.isEmpty else { continue }
            if let cached = input.styled[item.id], cached.source == body {
                styled[item.id] = cached
                continue
            }
            let outgoing = message.direction == .outgoing
            let palette = TranscriptColors.palette(outgoing: outgoing)
            var text = MessageStyling.attributed(body, size: input.fontSize, palette: palette)
            if !outgoing { text = highlighted(text, matcher: matcher) }
            styled[item.id] = StyledEntry(
                source: body, text: StyledText(string: text),
                link: LinkPreviewFetcher.firstLink(in: body))
        }

        let rows = TranscriptRowBuilder.rows(
            for: input.items, styled: { styled[$0] }, chat: input.chat,
            unreadBefore: input.unreadBefore, highlighted: input.highlighted,
            calendar: input.calendar, linkPreviews: input.linkPreviews,
            locationDisplay: { message in
                guard let trust = input.trust else { return .coordinates }
                return LocationTrust.display(for: message, in: trust.chat, roster: trust.roster)
            }, revealed: input.revealed, gaps: input.gaps, loadingGaps: input.loadingGaps,
            pictureSize: { InlinePicture.pixelSize(of: $0, media: input.media) })

        var layouts: [Int64: CachedLayout] = [:]
        var eventHeights: [Int64: CachedHeight] = [:]
        if input.width > 50 {
            let fonts = TranscriptFonts(size: input.fontSize)
            let measurer = TextMeasurer()
            layouts.reserveCapacity(rows.count)
            for row in rows {
                switch row {
                case .message(let model):
                    if let cached = input.layouts[model.id], cached.width == input.width,
                        cached.model == model
                    {
                        layouts[model.id] = cached
                    } else {
                        let layout = MessageLayout.make(
                            model, width: input.width, fonts: fonts, measurer: measurer)
                        layouts[model.id] = CachedLayout(
                            width: input.width, model: model, layout: layout)
                    }
                case .event(let id, let text):
                    if let cached = input.eventHeights[id], cached.width == input.width,
                        cached.text == text
                    {
                        eventHeights[id] = cached
                    } else {
                        let height = EventCellView.height(
                            for: text, width: input.width, font: fonts.body, measurer: measurer)
                        eventHeights[id] = CachedHeight(
                            width: input.width, text: text, height: height)
                    }
                case .day, .unread, .gap:
                    break
                }
            }
        }
        return Output(rows: rows, styled: styled, layouts: layouts, eventHeights: eventHeights)
    }
}
