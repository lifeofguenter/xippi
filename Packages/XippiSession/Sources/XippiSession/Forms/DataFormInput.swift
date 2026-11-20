import Foundation
import XMPPCore

/// What the user entered into a XEP-0004 form, field by field, with the checks before it goes
/// back: required fields filled, addresses that are JIDs. Values are normalised before they are
/// checked and sent: text and addresses trimmed, addresses in their canonical form and each
/// address once (XEP-0004 3.3). Passwords are sent as typed. Also what a read-only form shows,
/// private values masked, and which of a field's XEP-0221 media may be shown.
public struct DataFormInput: Sendable, Equatable {
    /// One field's entry. Which part is used depends on the field's type.
    public struct Entry: Sendable, Equatable {
        /// Single-line and multi-line text, addresses (one per line) and the list-single choice.
        public var text = ""
        /// A boolean field.
        public var flag = false
        /// The chosen values of a list-multi field.
        public var selection: Set<String> = []

        public init() {}
    }

    public enum Problem: Sendable, Equatable {
        case required
        case invalidAddress(String)
    }

    /// A run of fields under a fixed field's text, or before the first one.
    public struct Section: Sendable, Equatable, Identifiable {
        public let id: Int
        public var title: String?
        /// Indexes into the form's fields; hidden and fixed fields are not among them.
        public var fields: [Int]
    }

    public private(set) var form: DataForm
    public var entries: [Entry]

    public init(form: DataForm) {
        self.form = form
        entries = form.fields.map { field in
            var entry = Entry()
            switch Self.kind(of: field) {
            case .boolean: entry.flag = field.boolValue ?? false
            case .listMulti: entry.selection = Set(field.values)
            case .textMulti, .jidMulti: entry.text = field.values.joined(separator: "\n")
            default: entry.text = field.value ?? ""
            }
            return entry
        }
    }

    /// Every field is handled as its type, and one without a known type as text-single.
    public static func kind(of field: DataForm.Field) -> DataForm.Field.FieldType {
        field.type ?? .textSingle
    }

    /// Whether the form is filled in and sent back, or only shown (a result).
    public var isEditable: Bool { form.type == .form }

    /// The fields to show, under the text of the fixed field before them.
    public var sections: [Section] {
        var sections = [Section(id: 0, title: nil, fields: [])]
        for (index, field) in form.fields.enumerated() {
            switch Self.kind(of: field) {
            case .hidden:
                continue
            case .fixed:
                let text = field.values.joined(separator: "\n")
                sections.append(
                    Section(id: index + 1, title: text.isEmpty ? nil : text, fields: []))
            default:
                sections[sections.count - 1].fields.append(index)
            }
        }
        return sections.filter { !$0.fields.isEmpty || $0.title != nil }
    }

    /// What is wrong with each field, by index; empty when the form can go.
    public var problems: [Int: Problem] {
        var problems: [Int: Problem] = [:]
        for (index, field) in form.fields.enumerated() {
            if let problem = problem(field, entries[index]) { problems[index] = problem }
        }
        return problems
    }

    private func problem(_ field: DataForm.Field, _ entry: Entry) -> Problem? {
        switch Self.kind(of: field) {
        case .hidden, .fixed, .boolean:
            return nil
        case .listMulti:
            return field.required && entry.selection.isEmpty ? .required : nil
        case .jidSingle, .jidMulti:
            let lines = Self.lines(entry.text)
            if field.required && lines.isEmpty { return .required }
            if let bad = lines.first(where: { (try? JID($0)) == nil }) {
                return .invalidAddress(bad)
            }
            return nil
        case .textMulti:
            return field.required && Self.lines(entry.text).isEmpty ? .required : nil
        case .textSingle, .textPrivate, .listSingle:
            return field.required && Self.trimmed(entry.text).isEmpty ? .required : nil
        }
    }

    /// The form to send back (`DataForm.submit(values:)`), or nil while a field has a problem.
    public func submission() -> DataForm? {
        guard problems.isEmpty else { return nil }
        return form.submit(values: values)
    }

    /// The entered values by field `var`. Hidden fields are left out, so they go back with the
    /// form's own values.
    public var values: [String: [String]] {
        var values: [String: [String]] = [:]
        for (index, field) in form.fields.enumerated() {
            guard let variable = field.variable else { continue }
            let entry = entries[index]
            switch Self.kind(of: field) {
            case .hidden, .fixed:
                continue
            case .boolean:
                values[variable] = [entry.flag ? "1" : "0"]
            case .listMulti:
                let offered = field.options.map(\.value).filter(entry.selection.contains)
                let others = entry.selection.subtracting(offered).sorted()
                values[variable] = offered + others
            case .jidSingle, .jidMulti:
                var seen = Set<String>()
                values[variable] = Self.lines(entry.text).map(Self.canonicalJID).filter {
                    seen.insert($0).inserted
                }
            case .textMulti:
                values[variable] = Self.paragraphLines(entry.text)
            case .textPrivate:
                values[variable] = entry.text.isEmpty ? [] : [entry.text]
            case .textSingle, .listSingle:
                let text = Self.trimmed(entry.text)
                values[variable] = text.isEmpty ? [] : [text]
            }
        }
        return values
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The trimmed, non-empty lines: one address each.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { trimmed(String($0)) }.filter { !$0.isEmpty }
    }

    /// The lines of a text-multi field as typed, without the empty lines at the end.
    private static func paragraphLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, trimmed(last).isEmpty { lines.removeLast() }
        return lines
    }

    private static func canonicalJID(_ text: String) -> String {
        (try? JID(text))?.description ?? text
    }

    // MARK: - A new form

    /// Takes the form the other side sent next (the next stage, a new challenge). A different
    /// form starts over from its own values: nothing typed into the old one carries over. The
    /// same form again keeps what was typed.
    public mutating func replace(with form: DataForm) {
        guard form != self.form else { return }
        self = DataFormInput(form: form)
    }

    // MARK: - Read-only forms

    /// How a read-only form shows a field's value.
    public enum Display: Sendable, Equatable {
        case text(String)
        case boolean(Bool)
        /// A private value: never shown.
        case masked
    }

    /// The value of the field at `index` as a read-only form shows it: private values
    /// masked, booleans as such, list values by their option's label.
    public func display(of index: Int) -> Display {
        guard form.fields.indices.contains(index) else { return .text("") }
        let field = form.fields[index]
        switch Self.kind(of: field) {
        case .textPrivate:
            return field.values.allSatisfy(\.isEmpty) ? .text("") : .masked
        case .boolean:
            if let value = field.boolValue { return .boolean(value) }
            return .text(field.values.joined(separator: "\n"))
        case .listSingle, .listMulti:
            let labels = field.values.map { value in
                field.options.first { $0.value == value }?.label ?? value
            }
            return .text(labels.joined(separator: ", "))
        default:
            return .text(field.values.joined(separator: "\n"))
        }
    }

    /// Whether a list-single field offers an empty choice: only when the form chose no value.
    public func offersEmptyChoice(_ index: Int) -> Bool {
        form.fields.indices.contains(index) && form.fields[index].value == nil
    }

    // MARK: - Media (XEP-0221)

    /// What a field's media can show.
    public struct Media: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case image, audio, video, other
        }

        /// What the media is, for the words beside its link.
        public var kind: Kind
        /// The `cid:` URI of an image to show inline, for the caller to resolve (Bits of
        /// Binary). Nothing else is ever resolved: no `file:`, `data:` or web address.
        public var contentID: DataForm.MediaURI?
        /// An `http(s)` address of the media, to open in the browser; never fetched here.
        public var link: URL?
    }

    /// The media of `field`; nil when it has none.
    public static func media(of field: DataForm.Field) -> Media? {
        guard let first = field.media.first else { return nil }
        let image = field.media.first {
            $0.uri.lowercased().hasPrefix("cid:") && mediaKind($0.type) == .image
        }
        let web = field.media.first { webURL($0.uri) != nil }
        let kind = image != nil ? .image : mediaKind((web ?? first).type)
        return Media(kind: kind, contentID: image, link: web.flatMap { webURL($0.uri) })
    }

    private static func mediaKind(_ type: String?) -> Media.Kind {
        guard let type = type?.lowercased() else { return .other }
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("video/") { return .video }
        return .other
    }

    /// `text` when it is an `http` or `https` address with a host.
    private static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }
}
