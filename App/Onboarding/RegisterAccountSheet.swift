import SwiftUI
import XippiSession

/// Registers a new account (XEP-0077): the provider and an invite link (XEP-0401) first,
/// then the server's own form, CAPTCHA included. The new account is logged in and kept.
struct RegisterAccountSheet: View {
    @Bindable var flow: RegisterAccountFlow
    let onCancel: () -> Void
    /// Switches to logging in with an existing account.
    let onAddExisting: () -> Void

    var body: some View {
        Group {
            switch flow.step {
            case .server:
                ServerStep(flow: flow, onCancel: onCancel, onAddExisting: onAddExisting)
            case .form(let form):
                VStack(spacing: 0) {
                    Text(flow.domain)
                        .font(.appTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    if let error = flow.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .accessibilityIdentifier("register-error")
                    }
                    DataFormView(
                        form: form, submitTitle: Copy.createAccount,
                        actions: [
                            FormAction(
                                id: "register-cancel", title: Copy.cancel, perform: onCancel),
                            FormAction(id: "register-back", title: Copy.back) { flow.back() },
                        ],
                        busy: flow.busy, media: { flow.media($0) },
                        onSubmit: { flow.submit($0) })
                }
                .frame(minHeight: 420)
            }
        }
        .font(.appBody)
        .frame(width: 520)
        .sheet(
            isPresented: Binding(
                get: { flow.certificate != nil },
                set: { if !$0, flow.certificate != nil { flow.rejectCertificate() } })
        ) {
            if let problem = flow.certificate {
                CertificateTrustSheet(
                    problem: problem, onTrust: { flow.trustCertificate() },
                    onCancel: { flow.rejectCertificate() })
            }
        }
        .accessibilityIdentifier("register-sheet")
    }
}

/// Where to register: a provider from the list, xippi.eu first, or any other domain.
private struct ServerStep: View {
    @Bindable var flow: RegisterAccountFlow
    let onCancel: () -> Void
    let onAddExisting: () -> Void
    private let providers = ProviderDirectory.shared
    /// The picker's tag for a domain typed in: no domain is empty.
    private static let other = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(
                        Copy.provider,
                        selection: Binding(
                            get: { flow.customDomain ? Self.other : flow.domain },
                            set: { flow.choose(provider: $0 == Self.other ? nil : $0) })
                    ) {
                        ForEach(providers.domains, id: \.self) { domain in
                            Text(verbatim: domain).tag(domain)
                        }
                        Divider()
                        Text(Copy.otherProvider).tag(Self.other)
                    }
                    .pointerStyle(.link)
                    .accessibilityIdentifier("register-provider")
                    if flow.customDomain {
                        TextField(Copy.domain, text: $flow.domain, prompt: Text(Copy.domainPrompt))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("register-domain")
                    }
                    TextField(Copy.inviteLink, text: $flow.invite, prompt: Text(Copy.optional))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("register-invite")
                } header: {
                    Text(Copy.newAccount)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                }
                if let error = flow.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("register-error")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(flow.busy)
            .task { await providers.load() }
            Divider()
            HStack(spacing: 10) {
                Button(Copy.addAccount, action: onAddExisting)
                    .disabled(flow.busy)
                    .accessibilityIdentifier("register-existing")
                Spacer()
                if flow.busy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Copy.connecting)
                }
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("register-cancel")
                Button(Copy.continueAction) { flow.fetchForm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canContinue)
                    .accessibilityIdentifier("register-continue")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
    }
}
