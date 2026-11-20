import AppKit
import SwiftUI
import XMPPCore
import XippiSession

/// A XEP-0004 data form: room configuration, registration, ad-hoc commands, channel admin.
/// Shows the title, the instructions, and every field type (hidden fields are kept but not
/// shown), with XEP-0221 images (a CAPTCHA) above their field. Submit checks required fields
/// and addresses, then hands back `DataForm.submit(values:)`. A result form is shown read-only,
/// private values masked. A new `form` replaces the old one and what was typed into it.
struct DataFormView: View {
    let form: DataForm
    let submitTitle: String
    /// Text buttons placed before Submit, such as Cancel and Back.
    var actions: [FormAction] = []
    /// A second button that checks and sends the form as Submit does, for another action
    /// (an ad-hoc command's Finish beside Next). Placed just before Submit.
    var alternateSubmit: FormSubmit?
    /// Submit is off while the form is being sent.
    var busy = false
    /// The data behind a field's `cid:` media URI (Bits of Binary); nil when the caller has
    /// none. Only `cid:` URIs are asked for. Nothing is fetched here: an `http(s)` image
    /// without data gets a link.
    let media: (DataForm.MediaURI) -> Data?
    let onSubmit: (DataForm) -> Void
    @State private var input: DataFormInput
    @State private var showsProblems = false
    /// The form's decoded images, by `cid:` URI; decoded once per form, and only the
    /// current form's decode is taken.
    @State private var images = FormImages()

    init(
        form: DataForm, submitTitle: String = Copy.submit, actions: [FormAction] = [],
        alternateSubmit: FormSubmit? = nil, busy: Bool = false,
        media: @escaping (DataForm.MediaURI) -> Data? = { _ in nil },
        onSubmit: @escaping (DataForm) -> Void
    ) {
        self.form = form
        self.submitTitle = submitTitle
        self.actions = actions
        self.alternateSubmit = alternateSubmit
        self.busy = busy
        self.media = media
        self.onSubmit = onSubmit
        _input = State(initialValue: DataFormInput(form: form))
    }

    var body: some View {
        let problems = showsProblems ? input.problems : [:]
        let editable = input.isEditable
        VStack(spacing: 0) {
            Form {
                if input.form.title != nil || !input.form.instructions.isEmpty {
                    Section {
                        FormHeader(title: input.form.title, instructions: input.form.instructions)
                    }
                }
                ForEach(input.sections) { section in
                    Section {
                        ForEach(section.fields, id: \.self) { index in
                            let field = input.form.fields[index]
                            let fieldMedia = DataFormInput.media(of: field)
                            FieldRow(
                                field: field, entry: $input.entries[index],
                                problem: problems[index].map(Self.words(for:)),
                                editable: editable, display: input.display(of: index),
                                offersEmptyChoice: input.offersEmptyChoice(index),
                                media: fieldMedia,
                                image: fieldMedia?.contentID.flatMap { images.image(for: $0.uri) })
                        }
                    } header: {
                        if let title = section.title { SectionTitle(title) }
                    }
                }
            }
            .formStyle(.grouped)
            if editable {
                Divider()
                HStack(spacing: 10) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    ForEach(actions) { action in
                        Button(action.title, action: action.perform)
                            .disabled(busy)
                            .accessibilityIdentifier(action.id)
                    }
                    if let alternateSubmit {
                        Button(alternateSubmit.title) { submit(to: alternateSubmit.perform) }
                            .disabled(busy)
                            .accessibilityIdentifier(alternateSubmit.id)
                    }
                    Button(submitTitle) { submit(to: onSubmit) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                        .accessibilityIdentifier("form-submit")
                }
                .controlSize(.large)
                .pointerStyle(.link)
                .padding(16)
            }
        }
        .font(.appBody)
        .accessibilityIdentifier("data-form")
        .onChange(of: form) { _, newForm in
            input.replace(with: newForm)
            showsProblems = false
        }
        .task(id: form) {
            let ticket = images.begin(for: form)
            let decoded = await Self.decode(contentData())
            images.finish(ticket, with: decoded)
        }
    }

    private func submit(to handler: (DataForm) -> Void) {
        guard let form = input.submission() else {
            showsProblems = true
            return
        }
        showsProblems = false
        handler(form)
    }

    /// The data of each `cid:` image the form shows, from the caller.
    private func contentData() -> [String: Data] {
        var found: [String: Data] = [:]
        for field in form.fields {
            guard let uri = DataFormInput.media(of: field)?.contentID, found[uri.uri] == nil,
                let data = media(uri)
            else { continue }
            found[uri.uri] = data
        }
        return found
    }

    /// Decodes untrusted image data off the main thread, within `FormImage`'s bounds; what
    /// it refuses is left out.
    @concurrent private static func decode(_ data: [String: Data]) async -> [String: CGImage] {
        data.compactMapValues(FormImage.decode)
    }

    static func words(for problem: DataFormInput.Problem) -> String {
        switch problem {
        case .required: Copy.required
        case .invalidAddress(let value): Copy.invalidAddress(value)
        }
    }
}

#if DEBUG || UITEST_HOOKS
    extension DataFormView {
        /// The form as it shows after a submit that found problems, for the snapshot hook.
        init(
            form: DataForm, showingProblems: Bool,
            media: @escaping (DataForm.MediaURI) -> Data? = { _ in nil }
        ) {
            self.init(form: form, media: media, onSubmit: { _ in })
            _showsProblems = State(initialValue: showingProblems)
        }
    }
#endif

/// A second Submit: checks the form and hands it to `perform`.
struct FormSubmit {
    /// Also the button's accessibility identifier.
    let id: String
    let title: String
    let perform: (DataForm) -> Void
}

/// A text button beside a form's Submit.
struct FormAction: Identifiable {
    /// Also the button's accessibility identifier.
    let id: String
    let title: String
    let perform: () -> Void
}

/// The form's title and instructions.
private struct FormHeader: View {
    let title: String?
    let instructions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.appTitle)
            }
            ForEach(Array(instructions.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One field: its media, its control, its description, and what is wrong with it.
private struct FieldRow: View {
    let field: DataForm.Field
    @Binding var entry: DataFormInput.Entry
    /// What is wrong with the field, in words.
    let problem: String?
    let editable: Bool
    let display: DataFormInput.Display
    let offersEmptyChoice: Bool
    let media: DataFormInput.Media?
    let image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let media {
                FieldMediaView(media: media, image: image)
            }
            if editable {
                FieldControl(
                    field: field, label: label, entry: $entry,
                    offersEmptyChoice: offersEmptyChoice
                )
                .accessibilityHint(problem ?? "")
            } else {
                LabeledContent(label) {
                    ReadOnlyValue(display: display)
                }
            }
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("form-problem")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form-field:\(field.variable ?? "")")
    }

    private var label: String { field.label ?? field.variable ?? "" }
}

/// A value of a result form: private values masked and never selectable.
private struct ReadOnlyValue: View {
    let display: DataFormInput.Display

    var body: some View {
        switch display {
        case .masked:
            Text(verbatim: Copy.hiddenValue)
                .accessibilityLabel(Copy.hiddenValue)
        case .boolean(let value):
            Text(value ? Copy.yes : Copy.no)
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
        }
    }
}

/// The control for a field's type.
private struct FieldControl: View {
    let field: DataForm.Field
    let label: String
    @Binding var entry: DataFormInput.Entry
    let offersEmptyChoice: Bool

    var body: some View {
        let prompt = field.required ? Text(Copy.required) : nil
        switch DataFormInput.kind(of: field) {
        case .boolean:
            Toggle(label, isOn: $entry.flag)
                .pointerStyle(.link)
        case .textPrivate:
            SecureField(label, text: $entry.text, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        case .jidSingle:
            TextField(label, text: $entry.text, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled()
        case .textMulti, .jidMulti:
            let addresses = field.type == .jidMulti
            LabeledContent(label) {
                MultiLineField(
                    text: $entry.text, label: label,
                    hint: addresses ? Copy.oneAddressPerLine : nil, addresses: addresses)
            }
        case .listSingle:
            Picker(label, selection: $entry.text) {
                if offersEmptyChoice {
                    Text(Copy.noChoice).tag("")
                }
                ForEach(Self.options(field, keeping: [entry.text]), id: \.value) { option in
                    Text(option.label ?? option.value).tag(option.value)
                }
            }
            .pointerStyle(.link)
        case .listMulti:
            LabeledContent(label) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.options(field, keeping: entry.selection), id: \.value) {
                        option in
                        Toggle(
                            option.label ?? option.value,
                            isOn: Binding(
                                get: { entry.selection.contains(option.value) },
                                set: { chosen in
                                    if chosen {
                                        entry.selection.insert(option.value)
                                    } else {
                                        entry.selection.remove(option.value)
                                    }
                                })
                        )
                        .toggleStyle(.checkbox)
                        .pointerStyle(.link)
                    }
                }
            }
        case .textSingle, .hidden, .fixed:
            TextField(label, text: $entry.text, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
        }
    }

    /// The field's options, and a current value it does not offer, so the choice still shows.
    private static func options(
        _ field: DataForm.Field, keeping current: some Sequence<String>
    ) -> [DataForm.Option] {
        var options = field.options
        let offered = Set(options.map(\.value))
        for value in Set(current).subtracting(offered).sorted() where !value.isEmpty {
            options.append(DataForm.Option(value: value))
        }
        return options
    }
}

/// A text-multi or jid-multi field: one value per line.
private struct MultiLineField: View {
    @Binding var text: String
    let label: String
    let hint: String?
    /// Addresses: no autocorrection or text replacement may rewrite them.
    let addresses: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $text)
                .font(.appBody)
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled(addresses)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: ControlHeight.Form.multiLineHeight)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: .rect(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                }
                .accessibilityLabel(label)
            if let hint {
                Text(hint)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 220)
    }
}

/// A field's image at no more than its own size, or a link to its media when it is not here.
private struct FieldMediaView: View {
    let media: DataFormInput.Media
    let image: CGImage?

    var body: some View {
        if let image {
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(
                    maxWidth: min(max(width, 1), ControlHeight.Form.maxImageWidth),
                    maxHeight: min(max(height, 1), ControlHeight.Form.maxImageHeight)
                )
                .accessibilityIdentifier("form-image")
        } else {
            HStack(spacing: 8) {
                Text(Copy.mediaNotLoaded(media.kind))
                    .foregroundStyle(.secondary)
                if let link = media.link {
                    Link(Copy.openMedia(media.kind), destination: link)
                        .pointerStyle(.link)
                }
            }
        }
    }
}
