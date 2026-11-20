import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XippiSession

/// The composer's text field: an `NSTextView` that grows with its text up to a limit, sends on
/// Return (or on ⌘Return, with Return adding a line, when "Send with Return" is off), adds a
/// line on ⇧Return or ⌥Return, edits the last message on ↑ when empty, and leaves reply or
/// edit mode on Escape. Files and images pasted or dropped on it go to the composer instead of
/// into the text. In rooms, Tab completes the nick before the cursor (again for the next
/// match), and "@" followed by a letter offers the matching nicks; elsewhere Tab moves on to
/// the next control. ":" and two letters offer emoji by shortcode, and a whole ":smile:"
/// becomes its emoji.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let focusRequest: Int
    let onSubmit: () -> Void
    let onUpArrowWhenEmpty: () -> Bool
    let onCancel: () -> Void
    /// The user typed, deleted or pasted text.
    var onUserEdit: () -> Void = {}
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (Data, UTType) -> Void = { _, _ in }
    /// Tab: the completion for the text and cursor (UTF-16), or nil.
    var onTab: (String, Int) -> NickCompleter.Edit? = { _, _ in nil }
    /// The nicks for what follows "@"; empty outside rooms.
    var nickSuggestions: (String) -> [String] = { _ in [] }
    /// A room: Tab completes nicks instead of moving the focus.
    var completesNicks = false
    /// The "Send with Return" setting.
    var sendOnReturn = true
    /// The message text size.
    var fontSize = Typography.bodySize

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.string = text
        textView.placeholder = placeholder
        textView.media = context.coordinator
        textView.onCommandReturn = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // Replaced by send, edit or a chat switch: undo must not bring back other text.
            textView.undoManager?.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage {
                textView.undoManager?.removeAllActions(withTarget: storage)
            }
            coordinator.updateHeight()
        }
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            textView.needsDisplay = true
            coordinator.updateHeight()
        }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, ComposerMediaReceiver {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var lastFocusRequest = Int.min
        /// Our own completion edit is under way: it is not the user typing.
        private var applyingCompletion = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
            guard !applyingCompletion else { return }
            parent.onUserEdit()
            if replaceTypedShortcode(in: textView) { return }
            offerCompletions(in: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) || !parent.sendOnReturn {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard textView.string.isEmpty else { return false }
                return parent.onUpArrowWhenEmpty()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                guard parent.completesNicks else {
                    textView.window?.selectNextKeyView(nil)
                    return true
                }
                return completeNick(in: textView)
            default:
                return false
            }
        }

        // MARK: Nicks

        /// Tab: replaces the word before the cursor with the next matching nick. Without a
        /// match the Tab is used up all the same, so focus stays in the field.
        private func completeNick(in textView: NSTextView) -> Bool {
            let cursor = textView.selectedRange().location
            guard let edit = parent.onTab(textView.string, cursor) else { return true }
            applyingCompletion = true
            defer { applyingCompletion = false }
            if textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                textView.replaceCharacters(in: edit.range, with: edit.replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: edit.cursor, length: 0))
            }
            parent.onUserEdit()
            return true
        }

        /// "@" and at least one letter: the system's completion list with the matching nicks.
        /// ":" and two letters: the matching emoji.
        private func offerCompletions(in textView: ComposerNSTextView) {
            let cursor = textView.selectedRange().location
            var offers = false
            if let token = NickCompletion.token(in: textView.string, cursor: cursor),
                token.hasAt, !token.prefix.isEmpty
            {
                offers = !parent.nickSuggestions(token.prefix).isEmpty
            } else if let token = EmojiShortcodes.token(in: textView.string, cursor: cursor) {
                offers = !EmojiShortcodes.matches(token.prefix).isEmpty
            }
            guard offers else {
                textView.isCompleting = false
                return
            }
            guard !textView.isCompleting else { return }
            textView.isCompleting = true
            textView.complete(nil)
        }

        /// A whole ":code:" just typed becomes its emoji.
        private func replaceTypedShortcode(in textView: NSTextView) -> Bool {
            let selection = textView.selectedRange()
            guard selection.length == 0,
                let done = EmojiShortcodes.completed(
                    in: textView.string, cursor: selection.location)
            else { return false }
            applyingCompletion = true
            defer { applyingCompletion = false }
            if textView.shouldChangeText(in: done.range, replacementString: done.emoji) {
                textView.replaceCharacters(in: done.range, with: done.emoji)
                textView.didChangeText()
                textView.setSelectedRange(
                    NSRange(
                        location: done.range.location + (done.emoji as NSString).length, length: 0
                    ))
            }
            return true
        }

        func textView(
            _ textView: NSTextView, completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange)
            if partial.hasPrefix("@") {
                index?.pointee = 0
                return parent.nickSuggestions(String(partial.dropFirst())).map { "@" + $0 }
            }
            if partial.hasPrefix(":") {
                index?.pointee = 0
                return EmojiShortcodes.matches(String(partial.dropFirst()))
                    .map(EmojiShortcodes.completion(for:))
            }
            return []
        }

        // MARK: Files

        func receive(files: [URL]) {
            parent.onFiles(files)
        }

        func receive(image: Data, type: UTType) {
            parent.onImage(image, type)
        }

        /// One line at least, `maxLines` at most; beyond that the field scrolls.
        func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                let container = textView.textContainer, let font = textView.font
            else { return }
            layoutManager.ensureLayout(for: container)
            let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
            let used = ceil(layoutManager.usedRect(for: container).height)
            let inset = textView.textContainerInset.height * 2
            let content = max(used, lineHeight) + inset
            let limit = lineHeight * CGFloat(ControlHeight.Composer.maxLines) + inset
            let height = min(max(content, ControlHeight.Composer.field), limit)
            if height != parent.height {
                let binding = parent.$height
                DispatchQueue.main.async { binding.wrappedValue = height }
            }
        }
    }
}

/// Takes the files and images the field does not insert as text.
@MainActor protocol ComposerMediaReceiver: AnyObject {
    func receive(files: [URL])
    func receive(image: Data, type: UTType)
}

/// Files and images on a pasteboard, as the composer takes them: files first; an image only
/// when there is no text beside it (a copied picture, a screenshot), so pasting from a document
/// still pastes its words.
enum ComposerPasteboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init("public.jpeg")]

    /// Hands what the pasteboard holds to `receiver`; false when it holds neither.
    @MainActor static func deliver(_ pasteboard: NSPasteboard, to receiver: ComposerMediaReceiver?)
        -> Bool
    {
        guard let receiver else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
            !urls.isEmpty
        {
            receiver.receive(files: urls)
            return true
        }
        guard pasteboard.string(forType: .string) == nil else { return false }
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let uti = UTType(type.rawValue) {
                receiver.receive(image: data, type: uti)
                return true
            }
        }
        return false
    }

    static func holdsMedia(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: imageTypes) != nil
    }
}

/// TextKit 1, plain text, no smart substitutions (what is typed is what is sent), and a
/// placeholder while empty.
final class ComposerNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    weak var media: ComposerMediaReceiver?
    /// The completion list is up.
    var isCompleting = false
    /// ⌘Return, which sends whatever "Send with Return" says.
    var onCommandReturn: (() -> Void)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 2, height: 7)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        registerForDraggedTypes([.fileURL] + ComposerPasteboard.imageTypes)
        setAccessibilityIdentifier("composer")
        setAccessibilityLabel(Copy.messageField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(
            at: NSPoint(x: x, y: textContainerInset.height), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        if string.isEmpty || string.count == 1 { needsDisplay = true }
    }

    override func accessibilityPlaceholderValue() -> String? {
        placeholder
    }

    override func keyDown(with event: NSEvent) {
        let returnKeys: Set<UInt16> = [36, 76]
        // Caps Lock, and the keypad's own flags on its Enter key, do not change the shortcut.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if returnKeys.contains(event.keyCode), flags == .command, !isCompleting {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        if ComposerPasteboard.deliver(.general, to: media) { return }
        super.paste(sender)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ComposerPasteboard.holdsMedia(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if ComposerPasteboard.holdsMedia(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if ComposerPasteboard.deliver(sender.draggingPasteboard, to: media) { return true }
        return super.performDragOperation(sender)
    }

    // MARK: Completion

    /// The word to complete is the "@nick" before the cursor, "@" included, or the ":code".
    override var rangeForUserCompletion: NSRange {
        let cursor = selectedRange().location
        if let token = NickCompletion.token(in: string, cursor: cursor), token.hasAt {
            return token.range
        }
        if let token = EmojiShortcodes.token(in: string, cursor: cursor) {
            return token.range
        }
        return super.rangeForUserCompletion
    }

    /// A chosen nick is followed by a space, a chosen emoji goes in on its own; leaving the
    /// list keeps what was typed.
    override func insertCompletion(
        _ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool
    ) {
        let chosen =
            flag
            && (movement == NSTextMovement.return.rawValue
                || movement == NSTextMovement.tab.rawValue)
        let inserted: String
        if chosen, let emoji = EmojiShortcodes.emoji(forCompletion: word) {
            inserted = emoji
        } else {
            inserted = chosen ? word + " " : word
        }
        super.insertCompletion(
            inserted, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { isCompleting = false }
    }
}
