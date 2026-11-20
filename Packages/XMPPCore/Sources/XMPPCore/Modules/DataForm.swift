/// A XEP-0004 data form, with XEP-0221 media in its fields.
public struct DataForm: Sendable, Hashable {
    public static let namespace = "jabber:x:data"
    public static let mediaNamespace = "urn:xmpp:media-element"

    public enum FormType: String, Sendable, CaseIterable {
        case form, submit, cancel, result
    }

    public struct Option: Sendable, Hashable {
        public var label: String?
        public var value: String

        public init(label: String? = nil, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// One `<uri/>` of a field's XEP-0221 `<media/>`: an `http(s):` or `cid:` address and its
    /// MIME type. The URI is kept as text: whether and how to fetch it is the caller's call.
    public struct MediaURI: Sendable, Hashable {
        public var type: String?
        public var uri: String

        public init(type: String?, uri: String) {
            self.type = type
            self.uri = uri
        }
    }

    public struct Field: Sendable, Hashable {
        public enum FieldType: String, Sendable, CaseIterable {
            case boolean
            case fixed
            case hidden
            case jidMulti = "jid-multi"
            case jidSingle = "jid-single"
            case listMulti = "list-multi"
            case listSingle = "list-single"
            case textMulti = "text-multi"
            case textPrivate = "text-private"
            case textSingle = "text-single"
        }

        /// The field's `var`.
        public var variable: String?
        /// nil when the field names no type, or one XEP-0004 does not define; such a field is
        /// handled as `text-single`.
        public var type: FieldType?
        public var label: String?
        /// The field's `<desc/>`.
        public var description: String?
        public var required: Bool
        public var values: [String]
        public var options: [Option]
        public var media: [MediaURI]

        public init(
            variable: String?, type: FieldType? = nil, label: String? = nil,
            description: String? = nil, required: Bool = false, values: [String] = [],
            options: [Option] = [], media: [MediaURI] = []
        ) {
            self.variable = variable
            self.type = type
            self.label = label
            self.description = description
            self.required = required
            self.values = values
            self.options = options
            self.media = media
        }

        /// The first value.
        public var value: String? { values.first }

        /// The value of a boolean field: `1`/`true` or `0`/`false`; nil for anything else.
        public var boolValue: Bool? {
            switch value {
            case "1", "true": true
            case "0", "false": false
            default: nil
            }
        }

        init?(element: Element) {
            guard element.name == "field", element.namespace == DataForm.namespace else {
                return nil
            }
            variable = element[attribute: "var"]
            type = element[attribute: "type"].flatMap(FieldType.init(rawValue:))
            label = element[attribute: "label"]
            description = element.child("desc", namespace: DataForm.namespace)?.text
            required = element.child("required", namespace: DataForm.namespace) != nil
            values = element.children("value", namespace: DataForm.namespace).map(\.text)
            options = element.children("option", namespace: DataForm.namespace).compactMap {
                option in
                guard let value = option.child("value", namespace: DataForm.namespace) else {
                    return nil
                }
                return Option(label: option[attribute: "label"], value: value.text)
            }
            media = element.children("media", namespace: DataForm.mediaNamespace).flatMap {
                $0.children("uri", namespace: DataForm.mediaNamespace).compactMap { uri in
                    uri.trimmedText.map { MediaURI(type: uri[attribute: "type"], uri: $0) }
                }
            }
        }

        var element: Element {
            var field = Element("field", namespace: DataForm.namespace)
            field[attribute: "var"] = variable
            field[attribute: "type"] = type?.rawValue
            field[attribute: "label"] = label
            if let description {
                field.append(DataForm.text("desc", description))
            }
            if required { field.append(Element("required", namespace: DataForm.namespace)) }
            for value in values { field.append(DataForm.text("value", value)) }
            for option in options {
                var element = Element("option", namespace: DataForm.namespace)
                element[attribute: "label"] = option.label
                element.append(DataForm.text("value", option.value))
                field.append(element)
            }
            if !media.isEmpty {
                var element = Element("media", namespace: DataForm.mediaNamespace)
                for uri in media {
                    var child = Element(
                        "uri", namespace: DataForm.mediaNamespace, children: [.text(uri.uri)])
                    child[attribute: "type"] = uri.type
                    element.append(child)
                }
                field.append(element)
            }
            return field
        }
    }

    public var type: FormType
    public var title: String?
    /// Each `<instructions/>` element, in order.
    public var instructions: [String]
    public var fields: [Field]
    /// The columns of a multi-item result.
    public var reported: [Field]
    /// The rows of a multi-item result.
    public var items: [[Field]]

    public init(
        type: FormType, title: String? = nil, instructions: [String] = [], fields: [Field] = [],
        reported: [Field] = [], items: [[Field]] = []
    ) {
        self.type = type
        self.title = title
        self.instructions = instructions
        self.fields = fields
        self.reported = reported
        self.items = items
    }

    /// Reads an `<x xmlns='jabber:x:data'/>`; nil for another element or an unknown form type.
    public init?(element: Element) {
        guard element.name == "x", element.namespace == Self.namespace,
            let type = element[attribute: "type"].flatMap(FormType.init(rawValue:))
        else { return nil }
        self.type = type
        title = element.child("title", namespace: Self.namespace)?.text
        instructions = element.children("instructions", namespace: Self.namespace).map(\.text)
        fields = element.children("field", namespace: Self.namespace).compactMap(Field.init)
        reported =
            element.child("reported", namespace: Self.namespace)?
            .children("field", namespace: Self.namespace).compactMap(Field.init) ?? []
        items = element.children("item", namespace: Self.namespace).map {
            $0.children("field", namespace: Self.namespace).compactMap(Field.init)
        }
    }

    public var element: Element {
        var x = Element("x", namespace: Self.namespace, attributes: ["type": type.rawValue])
        for line in instructions { x.append(Self.text("instructions", line)) }
        if let title { x.append(Self.text("title", title)) }
        for field in fields { x.append(field.element) }
        if !reported.isEmpty {
            x.append(
                Element(
                    "reported", namespace: Self.namespace,
                    children: reported.map { .element($0.element) }))
        }
        for item in items {
            x.append(
                Element(
                    "item", namespace: Self.namespace, children: item.map { .element($0.element) }))
        }
        return x
    }

    /// The value of the hidden `FORM_TYPE` field (XEP-0068).
    public var formType: String? {
        fields.first { $0.variable == "FORM_TYPE" && $0.type == .hidden }?.value
    }

    /// The first field with this `var`.
    public func field(_ variable: String) -> Field? {
        fields.first { $0.variable == variable }
    }

    /// The form filled in for sending back (XEP-0004 3.2): every field with a `var` except fixed
    /// ones, with its type and its value from `values` (or the form's default when `values`
    /// has none), and nothing meant only for display. Keys the form does not have are ignored.
    public func submit(values: [String: [String]]) -> DataForm {
        let submitted = fields.compactMap { field -> Field? in
            guard let variable = field.variable, field.type != .fixed else { return nil }
            return Field(
                variable: variable, type: field.type, values: values[variable] ?? field.values)
        }
        return DataForm(type: .submit, fields: submitted)
    }

    /// A submit form of `formType` (a hidden `FORM_TYPE` first) and these fields, in order:
    /// publish-options and other forms the client writes itself.
    public static func submission(formType: String, _ values: KeyValuePairs<String, [String]>)
        -> DataForm
    {
        var fields = [Field(variable: "FORM_TYPE", type: .hidden, values: [formType])]
        for (variable, value) in values {
            fields.append(Field(variable: variable, values: value))
        }
        return DataForm(type: .submit, fields: fields)
    }

    static func text(_ name: String, _ text: String) -> Element {
        Element(name, namespace: namespace, children: [.text(text)])
    }
}
