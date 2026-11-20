import Foundation

/// Why a registration did not go through.
///
/// A text from the server is trimmed and bounded, and left out when it contains the password,
/// the value of another private field or the invite token.
public enum RegistrationError: Error, Equatable {
    /// The server does not offer in-band registration (XEP-0077).
    case notSupported
    /// The username is taken.
    case conflict
    /// The server refused what was filled in, with its text if any: a field missing or
    /// malformed, a weak password, a wrong CAPTCHA answer. Also an empty username or password,
    /// or a username that cannot be a JID localpart, refused before anything is sent (no text).
    case notAcceptable(text: String?)
    /// The server does not allow registration: it is turned off, or not open to this address.
    case notAllowed
    /// The server takes no more registrations for now (rate limited): try again later.
    case resourceConstraint
    /// The server's certificate was not accepted. Show it; when the person accepts it, register
    /// again with a trust evaluator that pins it.
    case certificateRejected(ServerCertificateProblem)
    /// No server could be reached, the stream was lost or closed, or there is no form to submit:
    /// fetch the form again.
    case connectFailed
    /// A step took longer than its deadline.
    case timeout
    /// Any other stanza error, such as `item-not-found` for an invite token the server does not
    /// know or that was used.
    case other(StanzaError)
}

extension RegistrationError {
    /// A short name for logs, without server text.
    var logName: String {
        switch self {
        case .notSupported: "not supported"
        case .conflict: "conflict"
        case .notAcceptable: "not acceptable"
        case .notAllowed: "not allowed"
        case .resourceConstraint: "resource constraint"
        case .certificateRejected(let problem): "certificate rejected (\(problem.reason))"
        case .connectFailed: "connect failed"
        case .timeout: "timeout"
        case .other(let error): error.condition.rawValue
        }
    }
}

/// What a person filled in to register.
public struct RegistrationSubmission: Sendable, Equatable {
    /// The new account's localpart. Whitespace around it is dropped; the rest must be a valid
    /// localpart, and is sent prepared (RFC 7622), as the returned JID has it.
    public var username: String
    /// Sent as it is. Never empty.
    public var password: String
    /// The form's other fields, by legacy field name or data form `var`, such as an email
    /// address or a CAPTCHA answer (`ocr`). A field left out keeps the value the server gave.
    /// `username` and `password` here are ignored.
    public var values: [String: [String]]

    public init(username: String, password: String, values: [String: [String]] = [:]) {
        self.username = username
        self.password = password
        self.values = values
    }
}

extension RegistrationSubmission: CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    // Never the password, and no value of the other fields, which may be private too.
    public var description: String {
        "RegistrationSubmission(\(username), fields: \(values.keys.sorted()))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["username": username, "fields": values.keys.sorted()])
    }
}

/// The XEP-0077 exchange on a stream that is up: a XEP-0445 invite token first when there is
/// one, then the form, then the submission. It goes through a `StanzaSending` with the codecs
/// of `Registration`, and every failure comes back as a `RegistrationError`.
struct RegistrationFlow: Sendable {
    /// The server's domain, where every request goes.
    let server: JID
    /// The server offered in-band registration in its features. Without the offer, a form the
    /// server refuses, or a stream it ends instead of answering, means it does not register; a
    /// request that timed out says nothing either way and stays `.timeout`.
    let registrationAdvertised: Bool

    /// The longest server text an error keeps.
    static let maxTextLength = 1024

    /// What a server that knows neither XEP-0445 nor XEP-0077 answers.
    private static let unsupported: Set<StanzaError.Condition> = [
        .serviceUnavailable, .featureNotImplemented,
    ]

    /// Sends the token, if any, then asks for the form.
    ///
    /// A server that does not know XEP-0445 (`service-unavailable`, `feature-not-implemented`)
    /// is asked for the form anyway: whether it registers without the token is its call.
    func fetchForm(preauthToken: String?, via sender: any StanzaSending)
        async throws(RegistrationError) -> RegistrationForm
    {
        if let token = preauthToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            do throws(IQError) {
                try await Registration.preauth(token: token, server: server, via: sender)
            } catch .error(let error) where Self.unsupported.contains(error.condition) {
                // No XEP-0445 here: go on to the form.
            } catch {
                if case .error(let refusal) = error {
                    throw Self.failure(refusal, secrets: [token])
                }
                throw unoffered(error) ?? Self.failure(error, secrets: [token])
            }
        }
        do throws(IQError) {
            return try await Registration.fetch(server: server, via: sender)
        } catch {
            if case .error = error, !registrationAdvertised { throw .notSupported }
            throw unoffered(error) ?? Self.failure(error, secrets: [])
        }
    }

    /// Submits `submission` filled into `form`, as a data form when the server sent one (XEP-0077
    /// section 6), else as the legacy fields, and returns the new account's bare JID.
    ///
    /// The username and the password are checked before anything is sent.
    func submit(
        _ submission: RegistrationSubmission, to form: RegistrationForm,
        via sender: any StanzaSending
    ) async throws(RegistrationError) -> JID {
        let username = submission.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !submission.password.isEmpty,
            let jid = try? JID(
                localpart: username, domainpart: server.domainpart, resourcepart: nil),
            let localpart = jid.localpart
        else { throw .notAcceptable(text: nil) }
        let secrets = [submission.password] + Self.privateValues(of: submission, in: form)
        do throws(IQError) {
            if let dataForm = form.form {
                var values = submission.values
                values["username"] = [localpart]
                values["password"] = [submission.password]
                try await Registration.submit(
                    server: server, form: dataForm.submit(values: values), via: sender)
            } else {
                try await Registration.submit(
                    server: server,
                    fields: Self.legacyFields(
                        form.fields, username: localpart, password: submission.password,
                        values: submission.values),
                    via: sender)
            }
        } catch {
            throw Self.failure(error, secrets: secrets)
        }
        return jid
    }

    /// The legacy fields in the server's order, filled in. Fields the submission leaves out
    /// keep the server's value. A form that does not list the username or the password still
    /// gets them, first: XEP-0077 requires both.
    static func legacyFields(
        _ fields: [(name: String, value: String)], username: String, password: String,
        values: [String: [String]]
    ) -> [(name: String, value: String)] {
        var filled = fields.map { field -> (name: String, value: String) in
            switch field.name {
            case "username": (field.name, username)
            case "password": (field.name, password)
            default: (field.name, values[field.name]?.first ?? field.value)
            }
        }
        if !fields.contains(where: { $0.name == "password" }) {
            filled.insert(("password", password), at: 0)
        }
        if !fields.contains(where: { $0.name == "username" }) {
            filled.insert(("username", username), at: 0)
        }
        return filled
    }

    /// The submitted values of the data form's `text-private` fields.
    static func privateValues(of submission: RegistrationSubmission, in form: RegistrationForm)
        -> [String]
    {
        (form.form?.fields ?? []).filter { $0.type == .textPrivate }.compactMap(\.variable)
            .flatMap { submission.values[$0] ?? [] }
    }

    // MARK: Errors

    /// `.notSupported` for a failure other than a stanza error or a timeout when the server did
    /// not offer registration: it ended the stream (RFC 6120 has a server refuse stanzas before
    /// authentication with a `not-authorized` stream error) or answered nonsense.
    private func unoffered(_ error: IQError) -> RegistrationError? {
        switch error {
        case .error, .timeout: nil
        case .sessionEnded, .notConnected, .malformedResponse:
            registrationAdvertised ? nil : .notSupported
        }
    }

    static func failure(_ error: IQError, secrets: [String]) -> RegistrationError {
        switch error {
        case .error(let error): failure(error, secrets: secrets)
        case .timeout: .timeout
        case .sessionEnded, .notConnected: .connectFailed
        case .malformedResponse: .other(StanzaError(type: .cancel, condition: .undefinedCondition))
        }
    }

    /// XEP-0077 section 3.1 and the errors servers send in practice: Prosody throttles with
    /// `policy-violation` of type `wait`, ejabberd answers a malformed username with
    /// `jid-malformed` and a denied registration with `forbidden`.
    static func failure(_ error: StanzaError, secrets: [String]) -> RegistrationError {
        let text = Self.text(error.text, without: secrets)
        switch error.condition {
        case .conflict: return .conflict
        case .notAcceptable, .badRequest, .jidMalformed: return .notAcceptable(text: text)
        case .notAllowed, .forbidden: return .notAllowed
        case .resourceConstraint: return .resourceConstraint
        case .policyViolation where error.type == .wait: return .resourceConstraint
        case .serviceUnavailable, .featureNotImplemented: return .notSupported
        default:
            return .other(StanzaError(type: error.type, condition: error.condition, text: text))
        }
    }

    /// A server text for an error: trimmed and bounded; nil when it is empty or contains one of
    /// `secrets`, trimmed, in any case. The parser has already resolved XML escapes in it.
    static func text(_ text: String?, without secrets: [String]) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let folded = text.lowercased()
        let echoed = secrets.contains { secret in
            let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !secret.isEmpty && folded.contains(secret)
        }
        return echoed ? nil : String(text.prefix(maxTextLength))
    }
}
