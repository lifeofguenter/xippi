import SwiftUI
import XippiSession

/// The account sheet: log in with an existing account, or register a new one. The two share
/// the sheet, so switching between them does not close it.
struct OnboardingSheet: View {
    let dismiss: () -> Void
    /// The first account: the sheet opens with the wordmark.
    private let firstRun: Bool
    @State private var mode: Mode
    @State private var add: AddAccountFlow
    @State private var register: RegisterAccountFlow

    private enum Mode {
        case add, register
    }

    init(model: AppModel, start: OnboardingStart, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        firstRun = model.accounts.isEmpty
        let add = AddAccountFlow(model: model)
        let register: RegisterAccountFlow
        switch start {
        case .addAccount:
            _mode = State(initialValue: .add)
            register = RegisterAccountFlow(model: model)
        case .register(let invite):
            _mode = State(initialValue: .register)
            register = RegisterAccountFlow(model: model, invite: invite)
        }
        add.onAdded = dismiss
        register.onAdded = dismiss
        _add = State(initialValue: add)
        _register = State(initialValue: register)
    }

    var body: some View {
        VStack(spacing: 0) {
            if firstRun {
                Image(.xippiLogo)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 40)
                    .padding(.top, 24)
                    .accessibilityLabel(Copy.appName)
            }
            switch mode {
            case .add:
                AddAccountSheet(
                    flow: add,
                    onCancel: {
                        add.cancel()
                        dismiss()
                    },
                    onRegister: { mode = .register })
            case .register:
                RegisterAccountSheet(
                    flow: register,
                    onCancel: {
                        register.cancel()
                        dismiss()
                    },
                    onAddExisting: {
                        register.cancel()
                        mode = .add
                    })
            }
        }
        #if DEBUG || UITEST_HOOKS
            .onAppear {
                DebugSnapshot.addFlow = add
                DebugSnapshot.registerFlow = register
            }
        #endif
    }
}

/// Logs in with an existing account: address, password and, when the domain does not say
/// where its server is, the server. The account is kept once the login worked.
struct AddAccountSheet: View {
    @Bindable var flow: AddAccountFlow
    let onCancel: () -> Void
    /// Switches to registering a new account; nil leaves the button out.
    var onRegister: (() -> Void)?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(Copy.address, text: $flow.address, prompt: Text(Copy.addressPrompt))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .focused($addressFocused)
                        .accessibilityIdentifier("add-account-address")
                    SecureField(Copy.password, text: $flow.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("add-account-password")
                    TextField(Copy.server, text: $flow.server, prompt: Text(Copy.serverPrompt))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("add-account-server")
                } header: {
                    Text(Copy.addAccount)
                        .font(.appTitle)
                        .foregroundStyle(.primary)
                }
                if let error = flow.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("add-account-error")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(flow.connecting)
            Divider()
            HStack(spacing: 10) {
                if let onRegister {
                    Button(Copy.newAccount, action: onRegister)
                        .disabled(flow.connecting)
                        .accessibilityIdentifier("add-account-register")
                }
                Spacer()
                if flow.connecting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Copy.connecting)
                }
                Button(Copy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("add-account-cancel")
                Button(Copy.logIn) { flow.logIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canLogIn)
                    .accessibilityIdentifier("add-account-login")
            }
            .controlSize(.large)
            .pointerStyle(.link)
            .padding(16)
        }
        .font(.appBody)
        .frame(width: 460)
        .onAppear { addressFocused = flow.address.isEmpty }
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
        .accessibilityIdentifier("add-account-sheet")
    }
}
