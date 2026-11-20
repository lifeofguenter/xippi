import AppKit
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// One row of the sidebar's chat list: a section title or a chat.
enum SidebarRow: Equatable {
    case header(String)
    case chat(ChatListItem, stateLabel: String?, showsDraft: Bool)

    var chatID: Int64? {
        if case .chat(let item, _, _) = self { return item.id }
        return nil
    }

    /// What a row is, apart from what it shows: a reload keeps rows with the same identity.
    var identity: String {
        switch self {
        case .header(let title): "header:\(title)"
        case .chat(let item, _, _): "chat:\(item.id)"
        }
    }
}

/// The sidebar's chats in an AppKit table (R73), as the transcript is: rows drawn by AppKit,
/// their heights from fixed metrics, never measured. The scroll view reaches under the search
/// and filter bars; the insets keep the first and last rows clear of them.
struct SidebarTable: NSViewRepresentable {
    let model: AppModel
    let sheets: ChatSheets
    let rows: [SidebarRow]
    let selection: Int64?
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeCoordinator() -> SidebarTableController {
        SidebarTableController(model: model, sheets: sheets)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = context.coordinator.makeScrollView()
        update(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ controller: SidebarTableController) {
        controller.setInsets(top: topInset, bottom: bottomInset)
        controller.show(rows, selection: selection)
    }
}

/// Drives the sidebar table: rows, selection both ways, and each chat's menu.
@MainActor
final class SidebarTableController: NSObject, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate
{
    private let model: AppModel
    private let sheets: ChatSheets
    private var rows: [SidebarRow] = []
    private weak var table: NSTableView?
    private weak var scrollView: NSScrollView?
    /// The table is being told the model's selection: not a choice of the user's.
    private var applyingSelection = false
    private var avatarRedrawPending = false
    private var insets = NSEdgeInsets()

    init(model: AppModel, sheets: ChatSheets) {
        self.model = model
        self.sheets = sheets
    }

    func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chat"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: SidebarMetrics.rowSpacing)
        table.floatsGroupRows = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityIdentifier("sidebar")
        table.setAccessibilityLabel(Copy.chats)
        scrollView.documentView = table
        self.table = table
        self.scrollView = scrollView
        // A scroll of the user's own drops a pending scroll-to (I-3): a live scroll (trackpad,
        // scroller), and any other move of the list the table did not make itself (a mouse
        // wheel, page up and down, home and end).
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(liveScrollWillStart(_:)),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(avatarDidLoad(_:)), name: AvatarImages.didLoad,
            object: model.avatars)
        // After midnight a time from today is "Yesterday": the rows say it again.
        center.addObserver(
            self, selector: #selector(dayDidChange(_:)), name: .NSCalendarDayChanged, object: nil)
        return scrollView
    }

    /// The selection last passed to `show`.
    private var currentSelection: Int64?
    /// The table is moving the list itself: not a scroll of the user's.
    private var scrollingItself = false
    /// Where the list was last seen, to tell a move from another bounds change.
    private var lastOrigin: CGFloat?

    @objc private func liveScrollWillStart(_ notification: Notification) {
        userScrolled()
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let scrollView else { return }
        let origin = scrollView.contentView.bounds.origin.y
        defer { lastOrigin = origin }
        // A window being resized moves the list too; that is not a scroll.
        guard !scrollingItself, let lastOrigin, origin != lastOrigin,
            scrollView.window?.inLiveResize != true
        else { return }
        userScrolled()
    }

    /// The user put the list somewhere: a selection still waiting for its row no longer
    /// scrolls there when the row arrives.
    private func userScrolled() {
        shownSelection = currentSelection
    }

    /// Runs `body` as the table's own move of the list.
    private func asOwnScroll(_ body: () -> Void) {
        let outer = scrollingItself
        scrollingItself = true
        body()
        scrollingItself = outer
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        let new = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard let scrollView, new.top != insets.top || new.bottom != insets.bottom else { return }
        let atTop = scrollView.contentView.bounds.minY <= -insets.top + 1
        insets = new
        scrollView.contentInsets = new
        scrollView.scrollerInsets = new
        if atTop {
            asOwnScroll {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -new.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// The chat last selected and scrolled to through `show`: the list scrolls to the
    /// selection only when it changes or its row first arrives, never when the selected row's
    /// place does (I-2).
    private var shownSelection: Int64?

    /// Shows the rows as table changes (I-2): moves, inserts and removals one after the other,
    /// then a reload of the rows whose content changed. A reorder keeps the scroll position
    /// and the selection; only the first rows, or a different list (a new filter), reload all.
    func show(_ new: [SidebarRow], selection: Int64?) {
        guard let table else { return }
        currentSelection = selection
        asOwnScroll { apply(new, to: table) }
        select(selection, in: table)
    }

    private func apply(_ new: [SidebarRow], to table: NSTableView) {
        if new != rows {
            let old = rows
            let changes = ListChanges(from: old.map(\.identity), to: new.map(\.identity))
            rows = new
            applyingSelection = true
            // A first load, a different list, or ids that cannot be diffed (m-19) reload all;
            // `select` below puts the selection back by chat id.
            if old.isEmpty
                || changes.map({ Self.isDifferentList($0, old: old.count, new: new.count) }) ?? true
            {
                table.reloadData()
            } else if let changes {
                let origin = scrollView?.contentView.bounds.origin
                table.beginUpdates()
                for step in changes.steps {
                    switch step {
                    case .remove(let index):
                        table.removeRows(at: [index], withAnimation: [])
                    case .insert(let index, _):
                        table.insertRows(at: [index], withAnimation: [])
                    case .move(let from, let to):
                        table.moveRow(at: from, to: to)
                    }
                }
                table.endUpdates()
                let oldByID = Dictionary(
                    old.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
                let changed = IndexSet(
                    new.indices.filter { index in
                        oldByID[new[index].identity].map { $0 != new[index] } ?? false
                    })
                if !changed.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: changed)
                    table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                }
                if let origin, let scrollView {
                    scrollView.contentView.scroll(to: origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            applyingSelection = false
        }
    }

    /// Most rows changed place or came and went: a filter, not new messages.
    private static func isDifferentList(_ changes: ListChanges, old: Int, new: Int) -> Bool {
        changes.steps.count > max(old, new) / 2 + 2
    }

    /// Selects the chat, and scrolls to it once per selection: when it is chosen, or when its
    /// row first arrives (I-3: a chat restored at launch, or one Add contact made, is selected
    /// before the chat list brings its row).
    private func select(_ chatID: Int64?, in table: NSTableView) {
        let index = chatID.flatMap { id in rows.firstIndex { $0.chatID == id } }
        let changed = chatID != shownSelection
        // Shown only once its row was there to scroll to.
        if chatID == nil || index != nil { shownSelection = chatID }
        if table.selectedRow != (index ?? -1) {
            applyingSelection = true
            if let index {
                table.selectRowIndexes([index], byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            applyingSelection = false
        }
        if changed, let index { asOwnScroll { table.scrollRowToVisible(index) } }
    }

    #if DEBUG || UITEST_HOOKS
        /// For the snapshot hook: where the list is scrolled to, and which chat is selected.
        var debugState: String {
            let origin = scrollView?.contentView.bounds.origin.y ?? 0
            let selected = table.map { $0.selectedRow >= 0 ? rows[$0.selectedRow].chatID : nil }
            return
                "origin=\(Int(origin)) selected=\(selected.flatMap { $0 }.map(String.init) ?? "none")"
        }

        /// Scrolls the list to `y`, for the snapshot hook.
        func debugScroll(to y: CGFloat) {
            guard let scrollView else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    #endif

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: SidebarMetrics.header
        case .chat(let item, let stateLabel, _):
            SidebarMetrics.rowHeight(
                badge: item.chat.unreadCount > 0 || item.chat.mentionCount > 0,
                state: stateLabel != nil)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].chatID != nil
    }

    /// Section titles are group rows, so VoiceOver reads them as headers; they do not float.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].chatID == nil
    }

    /// Typing a name selects the chat (m-10); section titles are skipped.
    func tableView(
        _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
    ) -> String? {
        if case .chat(let item, _, _) = rows[row] { return item.displayName }
        return nil
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell =
                tableView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil)
                as? SidebarHeaderCell ?? SidebarHeaderCell()
            cell.title = title
            return cell
        case .chat(let item, let stateLabel, let showsDraft):
            let cell =
                tableView.makeView(withIdentifier: ChatRowCell.identifier, owner: nil)
                as? ChatRowCell ?? ChatRowCell()
            cell.configure(
                item, stateLabel: stateLabel, showsDraft: showsDraft,
                avatar: model.avatars.image(for: item.chat.avatarHash))
            return cell
        }
    }

    /// Posted on any thread: the rows on screen are drawn again on the main thread.
    @objc private nonisolated func dayDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let table = self?.table else { return }
            table.enumerateAvailableRowViews { row, _ in
                for cell in row.subviews { cell.needsDisplay = true }
            }
        }
    }

    /// Avatars arrive one by one after launch: the rows on screen are drawn again once per
    /// turn, however many arrived in it.
    @objc private func avatarDidLoad(_ notification: Notification) {
        guard !avatarRedrawPending else { return }
        avatarRedrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.avatarRedrawPending = false
            guard let table = self.table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            for row in visible.location..<min(NSMaxRange(visible), self.rows.count) {
                guard case .chat(let item, let stateLabel, let showsDraft) = self.rows[row],
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? ChatRowCell
                else { continue }
                cell.configure(
                    item, stateLabel: stateLabel, showsDraft: showsDraft,
                    avatar: self.model.avatars.image(for: item.chat.avatarHash))
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let table else { return }
        let row = table.selectedRow
        let chatID = row >= 0 && row < rows.count ? rows[row].chatID : nil
        if model.selection != chatID { model.selection = chatID }
    }

    // MARK: Menu

    /// Pin, Mark as read, and for a 1:1 chat Block and Report spam (App Review guideline
    /// 1.2), both asked first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A menu opened by keyboard or VoiceOver has no clicked row: the selected one (m-11).
        guard let table else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, case .chat(let item, _, _) = rows[row] else { return }
        for entry in ChatRowActions.items(for: item, model: model, sheets: sheets) {
            menu.addItem(entry)
        }
    }
}

/// The menu of a chat in the sidebar.
@MainActor enum ChatRowActions {
    static func items(for item: ChatListItem, model: AppModel, sheets: ChatSheets) -> [NSMenuItem] {
        let pinned = item.chat.pinned
        let chatID = item.id
        var items: [NSMenuItem] = []
        items.append(
            symbol(
                MenuAction.item(title: pinned ? Copy.unpin : Copy.pin) { [weak model] in
                    model?.setPinned(!pinned, chatID: chatID)
                }, pinned ? "pin.slash" : "pin"))
        let markRead = symbol(
            MenuAction.item(title: Copy.markAsRead) { [weak model] in
                model?.markRead(chatID: chatID)
            }, "checkmark.message")
        if item.chat.unreadCount == 0 && item.chat.mentionCount == 0 {
            markRead.target = nil
            markRead.action = nil
            markRead.isEnabled = false
        }
        items.append(markRead)
        guard item.chat.kind == .direct, let jid = try? JID(item.chat.jid),
            jid.bare.description != item.accountJID
        else { return items }
        items.append(.separator())
        func request(_ kind: SafetyRequest.Kind) -> SafetyRequest {
            SafetyRequest(
                kind: kind, accountID: item.chat.accountID, target: .contact(jid.bare),
                name: item.displayName)
        }
        if model.status.blocklists[item.chat.accountID]?.contains(jid.bare.description) != true {
            items.append(
                symbol(
                    MenuAction.item(title: Copy.blockContact, destructive: true) {
                        [weak sheets] in
                        sheets?.safety = request(.block)
                    }, "hand.raised"))
        }
        items.append(
            symbol(
                MenuAction.item(title: Copy.reportSpam, destructive: true) { [weak sheets] in
                    sheets?.safety = request(.report)
                }, "exclamationmark.bubble"))
        return items
    }

    private static func symbol(_ item: NSMenuItem, _ name: String) -> NSMenuItem {
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return item
    }
}

/// The sidebar's fixed metrics, from the app's text size: a row's height follows what it
/// shows (a badge, a room state line), never a measurement of its contents.
@MainActor enum SidebarMetrics {
    static let verticalPadding: CGFloat = 5
    static let leading: CGFloat = 6
    static let trailing: CGFloat = 8
    static let avatarGap: CGFloat = 10
    static let lineSpacing: CGFloat = 2
    static let rowSpacing: CGFloat = 2
    static let header: CGFloat = 28

    static var bodyFont: NSFont { Typography.body() }
    static var nameFont: NSFont { Typography.body(weight: .semibold) }
    static var badgeFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: Typography.bodySize, weight: .semibold)
    }

    static var lineHeight: CGFloat {
        let font = bodyFont
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// The second line holds the unread badge when there is one, and grows to it.
    static func rowHeight(badge: Bool, state: Bool) -> CGFloat {
        verticalPadding * 2
            + max(ControlHeight.Sidebar.avatar, textHeight(badge: badge, state: state))
    }

    static func textHeight(badge: Bool, state: Bool) -> CGFloat {
        let second = badge ? max(lineHeight, ControlHeight.Sidebar.badge) : lineHeight
        return lineHeight + lineSpacing + second + (state ? lineSpacing + lineHeight : 0)
    }
}

/// "Pinned", "Chats".
final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar-header")

    var title = "" {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(title)
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = SidebarMetrics.nameFont
        let text = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let height = SidebarMetrics.lineHeight
        let x = SidebarMetrics.leading + chatInset
        text.draw(
            with: NSRect(
                x: x, y: bounds.height - height - 4,
                width: bounds.width - x - SidebarMetrics.trailing, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A group row's cell starts at the row's edge, a chat's is inset by the source-list
    /// style: the title lines up with the avatars by the inset of a chat cell on screen.
    private var chatInset: CGFloat {
        guard let table = enclosingScrollView?.documentView as? NSTableView,
            let visible = Range(table.rows(in: table.visibleRect))
        else { return 0 }
        for row in visible where !(table.delegate?.tableView?(table, isGroupRow: row) ?? false) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                continue
            }
            return max(
                0, cell.convert(NSPoint.zero, to: table).x - convert(NSPoint.zero, to: table).x)
        }
        return 0
    }
}

/// One chat: avatar, name, time, newest message or draft, unread count and mention marker,
/// and a room's state when it is not joined. Drawn in one view; the same layout as before.
final class ChatRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("chat-row")

    private var item: ChatListItem?
    private var stateLabel: String?
    private var showsDraft = false
    private var avatar: NSImage?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    /// A row opens its chat: the pointer says so (owner rule, m-7).
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func configure(
        _ item: ChatListItem, stateLabel: String?, showsDraft: Bool, avatar: NSImage?
    ) {
        self.avatar = avatar
        self.item = item
        self.stateLabel = stateLabel
        self.showsDraft = showsDraft
        let name = item.displayName
        setAccessibilityIdentifier("chat:\(name)")
        setAccessibilityLabel(name)
        setAccessibilityValue(accessibilityText(item, name: name))
        needsDisplay = true
    }

    private var draftText: String? {
        guard showsDraft,
            let draft = item?.chat.draft?.trimmingCharacters(in: .whitespacesAndNewlines),
            !draft.isEmpty
        else { return nil }
        return ChatDisplay.singleLine(draft)
    }

    private func accessibilityText(_ item: ChatListItem, name: String) -> String {
        var parts: [String] = []
        if item.chat.unreadCount > 0 { parts.append(Copy.unreadCount(item.chat.unreadCount)) }
        if item.chat.mentionCount > 0 { parts.append(Copy.mentioned) }
        if item.chat.muted { parts.append(Copy.muted) }
        if let stateLabel { parts.append(stateLabel) }
        if let draftText {
            parts.append("\(Copy.draft): \(draftText)")
        } else if let last = item.lastMessage {
            parts.append(Copy.lastMessage(ChatDisplay.preview(of: last, isRoom: item.isGroup)))
        }
        return parts.joined(separator: ", ")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor =
            selected
            ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let name = item.displayName
        let unread = item.chat.unreadCount
        let mentions = item.chat.mentionCount
        let hasBadge = unread > 0 || mentions > 0

        // The avatar, centred on the row.
        let size = ControlHeight.Sidebar.avatar
        let avatar = NSRect(
            x: SidebarMetrics.leading, y: ((bounds.height - size) / 2).rounded(), width: size,
            height: size)
        Self.drawAvatar(
            in: avatar, image: self.avatar, name: name, identifier: item.chat.jid,
            isGroup: item.isGroup)

        // The text block, centred too.
        let lineHeight = SidebarMetrics.lineHeight
        let textHeight = SidebarMetrics.textHeight(badge: hasBadge, state: stateLabel != nil)
        let x = avatar.maxX + SidebarMetrics.avatarGap
        let width = bounds.width - x - SidebarMetrics.trailing
        var y = ((bounds.height - textHeight) / 2).rounded()

        // Name and time.
        let bodyFont = SidebarMetrics.bodyFont
        var nameWidth = width
        if let date = item.lastMessage?.timestamp ?? item.chat.lastActivity {
            let time = NSAttributedString(
                string: RelativeDay.short(date),
                attributes: [.font: bodyFont, .foregroundColor: secondary])
            let timeWidth = ceil(time.size().width)
            time.draw(at: NSPoint(x: x + width - timeWidth, y: y))
            nameWidth -= timeWidth + 6
        }
        Self.drawLine(
            name, font: unread > 0 ? SidebarMetrics.nameFont : bodyFont, color: primary,
            in: NSRect(x: x, y: y, width: max(nameWidth, 0), height: lineHeight))
        y += lineHeight + SidebarMetrics.lineSpacing

        // The newest message or the draft, and the badges beside it.
        let secondHeight = hasBadge ? max(lineHeight, ControlHeight.Sidebar.badge) : lineHeight
        var previewWidth = width
        if hasBadge {
            let badgesWidth = Self.drawBadges(
                unread: unread, mentions: mentions, muted: item.chat.muted, selected: selected,
                trailing: x + width, centreY: y + secondHeight / 2)
            previewWidth -= badgesWidth + 6
        }
        let preview = NSMutableAttributedString()
        if let draftText {
            preview.append(
                NSAttributedString(
                    string: Copy.draft,
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: selected ? primary : NSColor.controlAccentColor,
                    ]))
            preview.append(
                NSAttributedString(
                    string: ": \(draftText)",
                    attributes: [.font: bodyFont, .foregroundColor: secondary]))
        } else if let last = item.lastMessage {
            preview.append(
                NSAttributedString(
                    string: ChatDisplay.preview(of: last, isRoom: item.isGroup),
                    attributes: [.font: bodyFont, .foregroundColor: secondary]))
        }
        Self.drawLine(
            preview,
            in: NSRect(
                x: x, y: y + (secondHeight - lineHeight) / 2, width: max(previewWidth, 0),
                height: lineHeight))
        y += secondHeight

        // A room that is not joined says so.
        if let stateLabel {
            y += SidebarMetrics.lineSpacing
            Self.drawLine(
                stateLabel, font: bodyFont, color: selected ? primary : .systemOrange,
                in: NSRect(x: x, y: y, width: width, height: lineHeight))
        }
    }

    private static func drawLine(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        drawLine(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]),
            in: rect)
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static func drawLine(_ text: NSAttributedString, in rect: NSRect) {
        let line = NSMutableAttributedString(attributedString: text)
        line.addAttribute(
            .paragraphStyle, value: truncating, range: NSRange(location: 0, length: line.length))
        line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The avatar, else initials on the chat's colour: a circle for a person, a rounded square
    /// for a group.
    static func drawAvatar(
        in rect: NSRect, image: NSImage?, name: String, identifier: String, isGroup: Bool
    ) {
        let path =
            isGroup
            ? NSBezierPath(
                roundedRect: rect, xRadius: rect.width * 0.28, yRadius: rect.width * 0.28)
            : NSBezierPath(ovalIn: rect)
        IdentityColor.avatarColor(for: identifier).setFill()
        path.fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(
                in: aspectFill(image.size, in: rect), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let font = initialsFont(size: max(rect.width * 0.4, 14))
        // A small avatar (beside a name in the transcript) has room for one letter at 14 pt.
        let letters = ChatDisplay.initials(of: name)
        let initials = NSAttributedString(
            string: rect.width < 26 ? String(letters.prefix(1)) : letters,
            attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = initials.size()
        initials.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// The image's frame that fills `rect`, centred, keeping its proportions.
    private static func aspectFill(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static var initialsFonts: [CGFloat: NSFont] = [:]

    private static func initialsFont(size: CGFloat) -> NSFont {
        if let font = initialsFonts[size] { return font }
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let font =
            base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
            ?? base
        initialsFonts[size] = font
        return font
    }

    /// The "@" marker and the unread capsule, right-aligned at `trailing`; returns their width.
    /// On the selected row, which is accent-filled, they turn white with accent digits (m-11).
    private static func drawBadges(
        unread: Int, mentions: Int, muted: Bool, selected: Bool, trailing: CGFloat,
        centreY: CGFloat
    ) -> CGFloat {
        let height = ControlHeight.Sidebar.badge
        let font = SidebarMetrics.badgeFont
        let fill: NSColor = selected ? .white : .controlAccentColor
        let ink: NSColor = selected ? .controlAccentColor : .white
        var right = trailing
        if unread > 0 {
            let text = NSAttributedString(
                string: unread > 999 ? "999+" : String(unread),
                attributes: [.font: font, .foregroundColor: ink])
            let width = max(height, ceil(text.size().width) + 14)
            let rect = NSRect(
                x: right - width, y: centreY - height / 2, width: width, height: height)
            (muted && !selected ? NSColor.secondaryLabelColor : fill).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            right = rect.minX - 4
        }
        if mentions > 0 {
            let rect = NSRect(
                x: right - height, y: centreY - height / 2, width: height, height: height)
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let text = NSAttributedString(
                string: "@", attributes: [.font: font, .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            right = rect.minX - 4
        }
        return trailing - right - 4
    }
}
