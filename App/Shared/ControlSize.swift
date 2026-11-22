import CoreGraphics

/// One height scale per surface. Controls that sit together take their size from the same
/// surface, by name, so a row never mixes sizes.
enum ControlHeight {
    /// The floating composer bar.
    enum Composer {
        /// Attach, emoji, lock and send: every control in the bar.
        static let button: CGFloat = 32
        /// The text field's smallest height: one line, centred on the buttons.
        static let field: CGFloat = 32
        /// The field grows up to this many lines, then scrolls.
        static let maxLines = 8
        static let cornerRadius: CGFloat = 22
        /// Space between the bar and the window's sides.
        static let margin: CGFloat = 16
        /// Space between the bar and the window's bottom, as in Messages.
        static let bottomMargin: CGFloat = 10
        /// The row of files waiting to be sent.
        static let filePreview: CGFloat = 52
        static let fileThumbnail: CGFloat = 40
        /// The remove control inside a waiting file.
        static let fileRemove: CGFloat = 24
        static let fileNameWidth: CGFloat = 180
        /// The location popover's map and width.
        static let locationMap: CGFloat = 200
        static let locationWidth: CGFloat = 340
    }

    /// The sidebar's chat rows.
    enum Sidebar {
        static let avatar: CGFloat = 38
        static let badge: CGFloat = 22
        static let filter: CGFloat = 28
        static let search: CGFloat = 32
        /// Closes a room the account is not in, on its row.
        static let closeButton: CGFloat = 16
    }

    /// The Settings window's account list and header.
    enum Settings {
        /// An account's picture in the account lists.
        static let accountAvatar: CGFloat = 28
        /// The picture in the account's header, a click away from changing it.
        static let headerAvatar: CGFloat = 44
    }

    /// Controls floating over the transcript.
    enum Transcript {
        /// The open chat's picture in the title bar, beside its name.
        static let titleAvatar: CGFloat = 28
        /// The pill around the chat's picture and name in the title bar: the name and the line
        /// under it, with room above and below them.
        static let titlePill: CGFloat = 44
        /// Above and below the name and the line under it, inside the pill.
        static let titleTextVerticalInset: CGFloat = 5
        /// Between the picture and the pill's round end: as far as above and below it, so the
        /// two curves run side by side.
        static let titleAvatarInset: CGFloat = (titlePill - titleAvatar) / 2
        /// Between the words and the pill's other end, clear of its curve.
        static let titleTextInset: CGFloat = 16
        /// The height the toolbar lays its glass out for: it puts a taller item's glass where
        /// this one's would start, and the item hangs below it.
        static let toolbarItem: CGFloat = 36
        /// How far the pill's content is moved down to sit in the middle of its glass: centred
        /// in the bar, it had 4 points of glass over it and 12 under it.
        static let titleDrop: CGFloat = (titlePill - toolbarItem) / 2
        /// The widest the chat's name and subtitle get in the title bar.
        static let titleWidth: CGFloat = 320
        static let jumpButton: CGFloat = 36
        static let daySeparator: CGFloat = 40
        /// "Earlier messages not loaded" with Load.
        static let gapRow: CGFloat = 44
        static let unreadMarker: CGFloat = 32
        static let systemRow: CGFloat = 30
        static let reactionChip: CGFloat = 24
        static let attachmentRow: CGFloat = 44
        static let attachmentIcon: CGFloat = 30
        /// A shared location's map.
        static let locationCard: CGFloat = 150
        /// Play and pause in a voice message, and the cancel or download control of a file.
        static let mediaButton: CGFloat = 28
        /// The add reaction control beside a hovered message.
        static let reactionButton: CGFloat = 20
        /// Each choice in the reaction picker.
        static let reactionChoice: CGFloat = 32
        /// The tabs over the list of who reacted.
        static let reactionTab: CGFloat = 28
        /// A line of the list of who reacted, and the picture on it.
        static let reactorLine: CGFloat = 44
        static let reactorAvatar: CGFloat = 32
    }

    /// The call window and the incoming call panel.
    enum Call {
        /// Every control in the call window's floating bar.
        static let button: CGFloat = 48
        /// The space between the bar's controls.
        static let spacing: CGFloat = 14
        /// The bar's distance from the window's bottom edge.
        static let margin: CGFloat = 20
        /// Accept and decline in the incoming call panel.
        static let panelButton: CGFloat = 40
        static let panelAvatar: CGFloat = 44
        static let panelWidth: CGFloat = 420
        /// The caller's avatar on an audio call.
        static let stageAvatar: CGFloat = 120
        /// The self view's width; its height follows 16:9.
        static let selfViewWidth: CGFloat = 200
        static let selfViewCornerRadius: CGFloat = 14
        /// The privacy button beside a problem line.
        static let noteButton: CGFloat = 30
    }

    /// Data forms (XEP-0004).
    enum Form {
        /// The largest a form image (a CAPTCHA) is shown.
        static let maxImageWidth: CGFloat = 320
        static let maxImageHeight: CGFloat = 160
        static let multiLineHeight: CGFloat = 72
    }

    /// The quick switcher and search lists.
    enum Search {
        static let field: CGFloat = 40
        static let row: CGFloat = 40
        static let panelWidth: CGFloat = 520
    }
}
