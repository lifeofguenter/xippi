import Foundation
import Observation
import XMPPCore
import XippiSession

/// The add-account sheet's state: what is typed, the login under way, its error, and a
/// certificate waiting for the user's decision.
@MainActor @Observable final class AddAccountFlow {
    var address: String {
        didSet { if address != oldValue { pinned = [] } }
    }
    var password = ""
    /// Where to connect instead of the server the domain names: only the UI tests set one.
    var server = TestServer.address {
        didSet { if server != oldValue { pinned = [] } }
    }
    private(set) var connecting = false
    private(set) var error: String?
    /// A certificate the server showed and the system does not trust; the trust sheet is open
    /// while it is set.
    var certificate: ServerCertificateProblem?

    @ObservationIgnored let model: AppModel
    /// Called once the account is stored and its session started.
    @ObservationIgnored var onAdded: () -> Void = {}
    /// Certificates the user trusted for the address and server as typed.
    @ObservationIgnored private var pinned: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel, address: String = "") {
        self.model = model
        self.address = address
    }

    var canLogIn: Bool {
        !connecting && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    /// Logs in once; the account is kept only when that works.
    func logIn() {
        guard canLogIn else { return }
        connecting = true
        error = nil
        let address = address
        let password = password
        let server = server
        let pinned = pinned
        task = Task { [weak self, model] in
            let outcome = await model.addAccount(
                address: address, password: password, server: server, pinned: pinned)
            guard let self else { return }
            self.connecting = false
            switch outcome {
            case .added: self.onAdded()
            case .failed(let message): self.error = message
            case .certificate(let problem): self.certificate = problem
            case .cancelled: break
            }
        }
    }

    /// Stops a login under way.
    func cancel() {
        task?.cancel()
        task = nil
        connecting = false
    }

    /// The user trusts the certificate: it is pinned on the account, and the login runs again.
    func trustCertificate() {
        guard let certificate else { return }
        pinned.append(certificate.sha256)
        self.certificate = nil
        logIn()
    }

    func rejectCertificate() {
        certificate = nil
        error = Copy.certificateNotTrusted
    }
}

/// The register sheet's state: the server and invite, then the server's form, then the login
/// with the new account.
@MainActor @Observable final class RegisterAccountFlow {
    enum Step: Equatable {
        /// The domain, an invite link and the server.
        case server
        /// The server's registration form.
        case form(DataForm)
    }

    var domain: String {
        didSet { if domain != oldValue { pinned = [] } }
    }
    /// The domain is typed rather than picked from the providers: "Other", or an invite's.
    var customDomain: Bool
    var invite: String
    /// Where to connect instead of the server the domain names: only the UI tests set one.
    var server = TestServer.address {
        didSet { if server != oldValue { pinned = [] } }
    }
    private(set) var step = Step.server
    private(set) var busy = false
    private(set) var error: String?
    var certificate: ServerCertificateProblem?

    @ObservationIgnored let model: AppModel
    @ObservationIgnored var onAdded: () -> Void = {}
    /// The invite the sheet was opened with (an `xmpp:` URI), used while the link field is
    /// empty.
    @ObservationIgnored private let preset: RegistrationInvite?
    /// Where the form was asked for, with the invite's token and reserved user name.
    @ObservationIgnored private var request: RegistrationRequest?
    @ObservationIgnored private var registration: RegistrationForm?
    @ObservationIgnored private var client: RegistrationClient?
    @ObservationIgnored private var pinned: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel, invite: RegistrationInvite? = nil, link: String = "") {
        self.model = model
        preset = invite
        domain = invite?.server ?? ProviderDirectory.own
        customDomain = invite != nil
        self.invite = link
    }

    /// Picks a provider from the list, or `nil` for one typed in.
    func choose(provider: String?) {
        customDomain = provider == nil
        domain = provider ?? ""
    }

    var canContinue: Bool {
        !busy
            && !(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && preset == nil)
    }

    /// Connects to the server and asks for its form, with the invite's token first.
    func fetchForm() {
        guard canContinue else { return }
        error = nil
        let request: RegistrationRequest
        do throws(RegistrationRequest.Problem) {
            request = try RegistrationRequest(domain: domain, inviteText: invite, preset: preset)
        } catch {
            switch error {
            case .invalidInvite: self.error = Copy.invalidInvite
            case .invalidDomain: self.error = Copy.invalidDomain
            case .inviteForOtherDomain(let other): self.error = Copy.inviteFor(other)
            }
            return
        }
        let endpoint: ServerAddress?
        do {
            endpoint = try ServerAddress.parse(server)
        } catch {
            self.error = Copy.invalidServer
            return
        }
        if domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            domain = request.domain
        }
        self.request = request
        busy = true
        let previous = client
        let client = model.registrationClient(
            domain: request.domain, server: endpoint, pinned: pinned)
        self.client = client
        task = Task { [weak self] in
            await previous?.close()
            do throws(RegistrationError) {
                let form = try await client.fetchForm(preauthToken: request.token)
                self?.show(form, username: request.username)
            } catch {
                self?.failed(error)
            }
            self?.busy = false
        }
    }

    private func show(_ form: RegistrationForm, username: String?) {
        registration = form
        step = .form(RegistrationInput.form(for: form, label: Self.label, username: username))
    }

    private func failed(_ error: RegistrationError) {
        if case .certificateRejected(let problem) = error {
            certificate = problem
        } else {
            self.error = Copy.registrationFailed(error)
        }
    }

    /// The data behind a form image (a CAPTCHA).
    func media(_ uri: DataForm.MediaURI) -> Data? {
        registration?.media(for: uri.uri)?.data
    }

    /// Registers with the filled-in form, then logs in with the new account and keeps it.
    func submit(_ filled: DataForm) {
        guard !busy, let client else { return }
        guard let submission = RegistrationInput.submission(from: filled) else {
            error = Copy.userNameAndPasswordRequired
            return
        }
        busy = true
        error = nil
        let server = server
        let pinned = pinned
        let hasChallenge = registration.map(RegistrationInput.hasChallenge) ?? false
        task = Task { [weak self, model] in
            let jid: JID
            do throws(RegistrationError) {
                jid = try await client.submit(submission)
            } catch {
                guard let self else { return }
                self.failed(error)
                // A challenge answers once: a new one comes with a new form.
                if hasChallenge, case .form = self.step {
                    await self.refetch(client)
                }
                self.busy = false
                return
            }
            let outcome = await model.addAccount(
                address: jid.description, password: submission.password, server: server,
                pinned: pinned)
            guard let self else { return }
            self.busy = false
            switch outcome {
            case .added: self.onAdded()
            case .failed(let message): self.error = message
            case .certificate: self.error = Copy.certificateNotTrusted
            case .cancelled: break
            }
        }
    }

    /// A new form on the stream (or a new stream, when the server closed it), with the
    /// invite's token again: the client sends it only to a stream that has not taken it.
    private func refetch(_ client: RegistrationClient) async {
        do throws(RegistrationError) {
            let form = try await client.fetchForm(preauthToken: request?.token)
            show(form, username: request?.username)
        } catch {
            failed(error)
        }
    }

    /// Back to the server and invite, closing the stream.
    func back() {
        task?.cancel()
        let client = client
        self.client = nil
        Task { await client?.close() }
        busy = false
        error = nil
        step = .server
    }

    func cancel() {
        back()
    }

    func trustCertificate() {
        guard let certificate else { return }
        pinned.append(certificate.sha256)
        self.certificate = nil
        fetchForm()
    }

    func rejectCertificate() {
        certificate = nil
        error = Copy.certificateNotTrusted
    }

    /// Names for the legacy registration fields (XEP-0077 3.1).
    private static func label(_ field: String) -> String? {
        switch field {
        case "username": Copy.userName
        case "password": Copy.password
        case "email": Copy.email
        default: nil
        }
    }
}

/// The server the UI tests' accounts connect to, on this Mac (`-UITestServer localhost`): their
/// domains are not in the DNS. Empty everywhere else, so the domain names the server.
enum TestServer {
    static var address: String {
        #if DEBUG || UITEST_HOOKS
            UITestLaunch.isActive ? UITestLaunch.value("UITestServer") ?? "" : ""
        #else
            ""
        #endif
    }
}
