import Foundation
import XMPPCore

/// A server's registration form (XEP-0077) as a data form to fill in, and the filled-in form
/// as what `RegistrationClient.submit` takes.
public enum RegistrationInput {
    /// The server's data form when it sent one. Otherwise one made from the legacy fields, in
    /// the server's order with their values, every one required (XEP-0077 3.1); the user name
    /// and the password come first when the server leaves them out, since every registration
    /// needs them. `label` names a legacy field; nil shows its name. `username`, the name an
    /// invite reserves, fills in an empty user name field.
    public static func form(
        for registration: RegistrationForm, label: (String) -> String?, username: String? = nil
    ) -> DataForm {
        var form = shownForm(for: registration, label: label)
        if let username, !username.isEmpty,
            let index = form.fields.firstIndex(where: { $0.variable == "username" }),
            form.fields[index].values.allSatisfy(\.isEmpty)
        {
            form.fields[index].values = [username]
        }
        return form
    }

    /// Whether the form carries a challenge (XEP-0158): a CAPTCHA form type, or a field with
    /// media. A challenge answers once: a refused submission needs a new form.
    public static func hasChallenge(_ registration: RegistrationForm) -> Bool {
        guard let form = registration.form else { return !registration.media.isEmpty }
        return form.formType == "urn:xmpp:captcha" || form.fields.contains { !$0.media.isEmpty }
            || !registration.media.isEmpty
    }

    private static func shownForm(
        for registration: RegistrationForm, label: (String) -> String?
    ) -> DataForm {
        if let form = registration.form { return form }
        var names = registration.fields.map(\.name)
        for required in ["password", "username"] where !names.contains(required) {
            names.insert(required, at: 0)
        }
        let values = Dictionary(
            registration.fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        let fields = names.map { name in
            DataForm.Field(
                variable: name, type: name == "password" ? .textPrivate : .textSingle,
                label: label(name) ?? name, required: true,
                values: values[name].flatMap { $0.isEmpty ? nil : [$0] } ?? [])
        }
        let instructions = registration.instructions.map { [$0] } ?? []
        return DataForm(type: .form, instructions: instructions, fields: fields)
    }

    /// The submission from a filled-in form (`DataFormInput.submission()`): its `username` and
    /// `password`, and every other field as a value. nil when either is missing or empty.
    public static func submission(from filled: DataForm) -> RegistrationSubmission? {
        var values: [String: [String]] = [:]
        for field in filled.fields {
            guard let variable = field.variable else { continue }
            values[variable] = field.values
        }
        guard let username = values.removeValue(forKey: "username")?.first, !username.isEmpty,
            let password = values.removeValue(forKey: "password")?.first, !password.isEmpty
        else { return nil }
        return RegistrationSubmission(username: username, password: password, values: values)
    }
}
