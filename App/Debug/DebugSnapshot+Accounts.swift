#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import XMPPCore
    import XippiSession
    import XippiStore

    /// `-UITestAction` steps for accounts and onboarding (UI test launches only; with
    /// `-UITestDatabase memory` the accounts connect for real, to the test servers with
    /// `-UITestCA <path>`):
    /// - `addaccount <jid> <password> [server]`: opens the add-account sheet, fills it in and
    ///   logs in.
    /// - `register <domain> [server]`: opens the register sheet, fills it in and asks for the
    ///   server's form.
    /// - `trust`: trusts the certificate the sheet shows.
    /// - `disable`, `enable`, `reconnect`, `remove`, `password <new>`: on the first account.
    /// - `contact <jid>`: the first account adds the contact and opens its chat.
    /// - `subscribe`, `approve`, `openchat`, `compose` with `<account> <contact>`: as that
    ///   account; `csiactive`: client state active; `mark`: counts transcript redraws from
    ///   here (`bodies=` in the text).
    /// - `registerinvite <link> [server]`: the register sheet opened with an invite.
    /// - `registeropen`: the register sheet as it opens; `registerother`: Other picked in it.
    /// - `fillform <username> <password>`: submits the register sheet's form with them.
    /// - `wait <seconds>`; `waitonline <seconds>`: until an account is online;
    ///   `waitsheet <seconds>`: until the sheet's login or form request is over.
    /// - `onboardingshot <suffix>`: the first-run sheet with the wordmark, to
    ///   `<name>.onboarding-<suffix>.png`.
    /// - `addshot`, `registershot`, `certshot`, `footershot` with a suffix: save
    ///   `<name>.<kind>-<suffix>.png` of that sheet, the certificate sheet, or the status
    ///   footer with its account list, and `<name>.accounts-<suffix>.txt` with what they show.
    extension DebugSnapshot {
        static weak var addFlow: AddAccountFlow?
        static weak var registerFlow: RegisterAccountFlow?
        private static var bodyMark = 0
        private static var passwordResult: String?

        static func performAccount(_ parts: [String]) async {
            guard let model else { return }
            let arguments = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            switch parts.first {
            case "addaccount":
                addFlow = nil
                await present(.addAccount, on: model)
                guard let flow = await waitForFlow({ addFlow }) else { return }
                flow.address = arguments.first ?? ""
                flow.password = arguments.count > 1 ? arguments[1] : ""
                flow.server = arguments.count > 2 ? arguments[2] : ""
                flow.logIn()
            case "registeropen":
                // The register sheet as it opens: nothing is asked of a server.
                registerFlow = nil
                await present(.register(nil), on: model)
                _ = await waitForFlow({ registerFlow })
            case "registerother":
                registerFlow?.choose(provider: nil)
            case "registerinvite":
                // `registerinvite <link> [server]`: the sheet opened with an invite, as the
                // `xmpp:` URI handler opens it.
                registerFlow = nil
                await present(.register(RegistrationInvite(link: arguments.first ?? "")), on: model)
                guard let flow = await waitForFlow({ registerFlow }) else { return }
                flow.server = arguments.count > 1 ? arguments[1] : ""
                flow.fetchForm()
            case "subscribe", "approve", "openchat", "compose":
                // `<step> <account> <contact>`: as that account.
                await performAs(parts.first ?? "", arguments: arguments, model: model)
            case "csiactive":
                // The app launched from a terminal is not active, so the server holds chat
                // states back (XEP-0352): this marks the client active, as when it is in use.
                model.services.systemEvents.setClientActive(true)
            case "mark":
                bodyMark = DebugCounters.conversationBodies
            case "register":
                // The flow of a sheet closed before must not stand in for the new one.
                registerFlow = nil
                await present(.register(nil), on: model)
                guard let flow = await waitForFlow({ registerFlow }) else { return }
                flow.choose(provider: nil)
                flow.domain = arguments.first ?? ""
                flow.server = arguments.count > 1 ? arguments[1] : ""
                flow.fetchForm()
            case "trust":
                if addFlow?.certificate != nil {
                    addFlow?.trustCertificate()
                } else if registerFlow?.certificate != nil {
                    registerFlow?.trustCertificate()
                }
            case "fillform":
                // `fillform <username> <password>`: submits the register sheet's form.
                guard let flow = registerFlow, case .form(var form) = flow.step else { return }
                for (index, field) in form.fields.enumerated() {
                    switch field.variable {
                    case "username": form.fields[index].values = [arguments.first ?? ""]
                    case "password":
                        form.fields[index].values = [arguments.count > 1 ? arguments[1] : ""]
                    default: break
                    }
                }
                flow.submit(form.submit(values: [:]))
            case "disable", "enable", "reconnect", "remove", "password":
                guard let account = model.accounts.first, let id = account.id else { return }
                switch parts.first {
                case "disable": await model.setEnabled(false, accountID: id)
                case "enable": await model.setEnabled(true, accountID: id)
                case "reconnect": await model.reconnect(accountID: id)
                case "remove": await model.removeAccount(account)
                default:
                    passwordResult =
                        await model.changePassword(arguments.first ?? "", accountID: id)
                        ?? Copy.passwordChanged
                }
            case "contact":
                // `contact <jid>`: the first account adds the contact, and its chat opens.
                guard let account = model.accounts.first, let id = account.id,
                    let session = await model.sessions.session(for: id),
                    let jid = try? JID(arguments.first ?? "")
                else { return }
                _ = try? await session.addContact(jid)
                try? await Task.sleep(for: .seconds(1))
                if let chat = try? model.database.ensureChat(
                    accountID: id, jid: jid.description, kind: .direct), let chatID = chat.id
                {
                    try? await Task.sleep(for: .seconds(1))
                    model.selection = chatID
                }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(arguments.first ?? "") ?? 1))
            case "waitonline":
                await wait(seconds: arguments.first) { model.anyAccountOnline }
            case "waitsheet":
                await wait(seconds: arguments.first) {
                    addFlow?.connecting != true && registerFlow?.busy != true
                }
            case "addshot":
                guard let flow = addFlow else { return }
                await renderOffscreen(
                    AddAccountSheet(flow: flow, onCancel: {}, onRegister: {}),
                    size: NSSize(width: 460, height: 400), dark: isDark,
                    to: sibling("add-\(arguments.first ?? "")"))
                describe(model, suffix: arguments.first)
            case "onboardingshot":
                // The whole first-run sheet, wordmark included: a sheet of its own, so the
                // flows the run uses stay as they are.
                let add = addFlow
                let register = registerFlow
                await renderOffscreen(
                    OnboardingSheet(model: model, start: .addAccount) {},
                    size: NSSize(width: 460, height: 470), dark: isDark,
                    to: sibling("onboarding-\(arguments.first ?? "")"))
                addFlow = add
                registerFlow = register
            case "registershot":
                guard let flow = registerFlow else { return }
                await renderOffscreen(
                    RegisterAccountSheet(flow: flow, onCancel: {}, onAddExisting: {}),
                    size: NSSize(width: 520, height: 700), dark: isDark,
                    to: sibling("register-\(arguments.first ?? "")"))
                describe(model, suffix: arguments.first)
            case "certshot":
                guard
                    let problem = addFlow?.certificate ?? registerFlow?.certificate
                        ?? model.certificateReview?.problem
                else { return }
                await renderOffscreen(
                    CertificateTrustSheet(problem: problem, onTrust: {}, onCancel: {}),
                    size: NSSize(width: 560, height: 280), dark: isDark,
                    to: sibling("certificate-\(arguments.first ?? "")"))
                describe(model, suffix: arguments.first)
            case "footershot":
                await renderOffscreen(
                    VStack(spacing: 0) {
                        AccountStatusFooter(model: model)
                        Divider()
                        AccountStatusList(model: model, enterPassword: { _ in })
                        Spacer(minLength: 0)
                    },
                    size: NSSize(width: 360, height: 260), dark: isDark,
                    to: sibling("footer-\(arguments.first ?? "")"))
                describe(model, suffix: arguments.first)
            default:
                await performSystem(parts)
            }
        }

        private static var isDark: Bool { NSApp.effectiveAppearance.isDark }

        /// Opens the account sheet afresh: a sheet already open (the one at launch) closes
        /// first, so the new one starts as asked.
        private static func present(_ start: OnboardingStart, on model: AppModel) async {
            if model.onboarding != nil {
                model.onboarding = nil
                try? await Task.sleep(for: .seconds(1))
            }
            model.onboarding = start
        }

        private static func performAs(_ step: String, arguments: [String], model: AppModel)
            async
        {
            guard arguments.count > 1,
                let account = model.accounts.first(where: { $0.jid == arguments[0] }),
                let id = account.id, let session = await model.sessions.session(for: id),
                let contact = try? JID(arguments[1]),
                let chatID = try? model.database.ensureChat(
                    accountID: id, jid: contact.description, kind: .direct
                ).id
            else { return }
            switch step {
            case "subscribe": _ = try? await session.addContact(contact)
            case "approve": try? await session.approveSubscription(contact)
            case "openchat": model.selection = chatID
            default: try? await session.setChatState(.composing, chatID: chatID)
            }
        }

        private static func waitForFlow<Flow: AnyObject>(_ flow: () -> Flow?) async -> Flow? {
            for _ in 0..<50 {
                if let found = flow() { return found }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        private static func wait(seconds: String?, until condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(Double(seconds ?? "") ?? 10)
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        /// What the account views show, as text beside the pictures.
        private static func describe(_ model: AppModel, suffix: String?) {
            var lines = model.accounts.map { account in
                let status = model.status(of: account)
                return "account \(account.jid) enabled=\(account.enabled)"
                    + " status=\(Copy.statusLine(status))"
                    + " detail=\(Copy.statusDetail(status) ?? "-")"
                    + " pins=\(account.pinnedCertSHA256.count)"
            }
            if let flow = addFlow {
                lines.append(
                    "add address=\(flow.address) connecting=\(flow.connecting)"
                        + " error=\(flow.error ?? "-")"
                        + " certificate=\(flow.certificate.map { "\($0.host) \($0.reason)" } ?? "-")"
                )
            }
            if let flow = registerFlow {
                var step = "server"
                if case .form(let form) = flow.step {
                    step =
                        "form "
                        + form.fields.map { field in
                            let value = field.type == .textPrivate ? "" : field.values.joined()
                            return
                                "\(field.variable ?? "?"):\(field.type?.rawValue ?? "-")=\(value)"
                        }
                        .joined(separator: ",")
                }
                lines.append(
                    "register domain=\(flow.domain) busy=\(flow.busy) step=\(step)"
                        + " error=\(flow.error ?? "-")"
                        + " certificate=\(flow.certificate.map { "\($0.host) \($0.reason)" } ?? "-")"
                )
            }
            lines.append("onboarding=\(model.onboarding.map(\.id) ?? "-")")
            if let passwordResult { lines.append("password=\(passwordResult)") }
            lines.append(
                "open=\(model.openChat?.jid ?? "-") callable=\(model.canCall)"
                    + " bodies=\(DebugCounters.conversationBodies - bodyMark)"
                    + " typingAll=\(model.status.typing.mapValues { $0.sorted() })"
                    + " typing=\(model.openChat.flatMap { model.typingText(chatID: $0.id, chatName: $0.name, isRoom: $0.isGroup) } ?? "-")"
            )
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension(
                    "accounts-\(suffix ?? "").txt"))
        }
    }
#endif
