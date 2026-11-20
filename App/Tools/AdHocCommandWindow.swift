import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// What the ad-hoc commands window shows and does (XEP-0050): the commands an entity offers
/// the account, and one command run step by step: its form, Back, Next or Finish and Cancel
/// as each step allows, its notes, and its result.
@MainActor @Observable final class AdHocModel {
    let target: AdHocTarget
    private(set) var commands: DiscoLoad<[AdHocCommand]> = .loading
    /// The command being run, or last run.
    private(set) var command: AdHocCommand?
    /// The command's current step; nil until its first answer.
    private(set) var step: AdHocResponse?
    /// The step's multi-item result as a table, built once per step.
    private(set) var table: DataFormTable?
    /// Fields of the step's form beyond `DataFormBounds`, not shown.
    private(set) var omittedFields = 0
    private(set) var busy = false
    private(set) var error: String?
    var selection: String?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var listed = false
    /// The run whose answers are shown; an answer of an earlier run is not.
    @ObservationIgnored private var currentRun = UUID()

    init(model: AppModel, target: AdHocTarget) {
        self.model = model
        self.target = target
        selection = target.node
    }

    var accountJID: String {
        model.accounts.first { $0.id == target.accountID }?.jid ?? ""
    }

    /// Asks for the commands, and runs the target's command when it names one.
    func start() {
        guard !listed else { return }
        listed = true
        reload()
        if let node = target.node, let jid = try? JID(target.jid) {
            run(AdHocCommand(jid: jid, node: node, name: target.name))
        }
    }

    func reload() {
        commands = .loading
        let target = target
        Task { [weak self, model] in
            guard let jid = try? JID(target.jid) else {
                self?.commands = .failed(Copy.invalidAddress(target.jid))
                return
            }
            guard let session = await model.sessions.session(for: target.accountID) else {
                self?.commands = .failed(Copy.notConnectedReason)
                return
            }
            do throws(IQError) {
                self?.commands = .loaded(try await AdHoc.list(jid, via: session.toolRequests))
            } catch {
                self?.commands = .failed(Copy.toolReason(error))
            }
        }
    }

    /// Starts a command; one still running is cancelled first.
    func run(_ next: AdHocCommand) {
        cancelRunning()
        command = next
        step = nil
        table = nil
        error = nil
        selection = next.node
        request { sender throws(IQError) in
            try await AdHoc.execute(next.jid, node: next.node, via: sender)
        }
    }

    /// The next step for `action`, with the step's form filled in where it takes one.
    func perform(_ action: AdHocResponse.Action, form: DataForm? = nil) {
        guard let command, let step else { return }
        request { sender throws(IQError) in
            try await AdHoc.perform(action, after: step, at: command.jid, form: form, via: sender)
        }
    }

    /// Ends a running command on the entity too (XEP-0050 2.4.3), without waiting for it. A
    /// run still waiting for its first answer is cancelled when that answer comes.
    func cancelRunning() {
        currentRun = UUID()
        busy = false
        guard let command, let step, !step.isFinished else { return }
        cancel(step, at: command.jid)
        self.step = nil
        table = nil
    }

    private func cancel(_ step: AdHocResponse, at jid: JID) {
        let accountID = target.accountID
        Task { [model] in
            guard let session = await model.sessions.session(for: accountID) else { return }
            _ = try? await AdHoc.perform(
                .cancel, after: step, at: jid, form: nil, via: session.toolRequests)
        }
    }

    private func request(
        _ work: @escaping @Sendable (any StanzaSending) async throws(IQError) -> AdHocResponse
    ) {
        busy = true
        error = nil
        let accountID = target.accountID
        let run = currentRun
        let jid = command?.jid
        Task { [weak self, model] in
            guard let session = await model.sessions.session(for: accountID) else {
                self?.finish(run, jid: jid, .failure(.notConnected))
                return
            }
            do throws(IQError) {
                self?.finish(run, jid: jid, .success(try await work(session.toolRequests)))
            } catch {
                self?.finish(run, jid: jid, .failure(error))
            }
        }
    }

    private func finish(_ run: UUID, jid: JID?, _ result: Result<AdHocResponse, IQError>) {
        guard run == currentRun else {
            // A run no longer shown: its session on the entity is ended, not left open.
            if case .success(let response) = result, !response.isFinished, let jid {
                cancel(response, at: jid)
            }
            return
        }
        busy = false
        switch result {
        case .success(let response):
            // The entity's form, within bounds (`DataFormBounds`).
            var bounded = response
            let form = response.form?.bounded()
            bounded.form = form?.form
            omittedFields = form?.omittedFields ?? 0
            step = bounded
            table = bounded.form?.table
        case .failure(let failure):
            error = Copy.commandFailed(Copy.toolReason(failure))
        }
    }
}

/// The ad-hoc commands window: the entity's commands on the left, the command run on the
/// right.
struct AdHocCommandWindow: View {
    @State private var adHoc: AdHocModel

    init(model: AppModel, target: AdHocTarget) {
        self.init(adHoc: AdHocModel(model: model, target: target))
    }

    /// The window on a model already made, for the snapshot hook.
    init(adHoc: AdHocModel) {
        _adHoc = State(initialValue: adHoc)
    }

    var body: some View {
        HSplitView {
            CommandList(adHoc: adHoc)
                .frame(minWidth: 220, idealWidth: ControlHeight.Tools.listWidth)
            CommandRun(adHoc: adHoc)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 420)
        .font(.appBody)
        // The title is the app's own: a command's name comes from the entity.
        .navigationTitle(Copy.adHocCommands)
        .navigationSubtitle("\(adHoc.target.jid), \(adHoc.accountJID)")
        .onAppear { adHoc.start() }
        .onDisappear { adHoc.cancelRunning() }
        .accessibilityIdentifier("adhoc-window")
    }
}

private struct CommandList: View {
    @Bindable var adHoc: AdHocModel

    var body: some View {
        Group {
            switch adHoc.commands {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let reason):
                VStack(spacing: 10) {
                    ToolError(text: Copy.notAvailable(reason), identifier: "adhoc-list-error")
                    ToolButton(title: Copy.browse, identifier: "adhoc-reload", action: adHoc.reload)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let commands) where commands.isEmpty:
                ContentUnavailableView(Copy.noCommands, systemImage: "terminal")
            case .loaded(let commands):
                List(commands, id: \.node, selection: $adHoc.selection) { command in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(command.name ?? command.node)
                        if command.name != nil {
                            Text(verbatim: command.node)
                                .font(.appMonospaced)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // A command another entity runs says which.
                        if command.jid.description != adHoc.target.jid {
                            Text(Copy.commandFrom(command.jid.description))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("adhoc-command:\(command.node)")
                }
                .listStyle(.sidebar)
                .onChange(of: adHoc.selection) { _, node in
                    guard let node, node != adHoc.command?.node,
                        let command = commands.first(where: { $0.node == node })
                    else { return }
                    adHoc.run(command)
                }
            }
        }
        .accessibilityIdentifier("adhoc-commands")
    }
}

/// The command's current step, or its result once it has finished.
private struct CommandRun: View {
    let adHoc: AdHocModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let command = adHoc.command {
                VStack(alignment: .leading, spacing: 8) {
                    Text(command.name ?? command.node)
                        .font(.appTitle)
                    Text(Copy.commandFrom(command.jid.description))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("adhoc-from")
                    if adHoc.omittedFields > 0 {
                        Text(Copy.moreNotShown(adHoc.omittedFields))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("adhoc-fields-omitted")
                    }
                    if let step = adHoc.step {
                        if step.isFinished {
                            Text(
                                step.status == .completed
                                    ? Copy.commandCompleted : Copy.commandCanceled
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("adhoc-status")
                        }
                        ForEach(Array(step.notes.enumerated()), id: \.offset) { _, note in
                            NoteRow(note: note)
                        }
                    }
                    ToolError(text: adHoc.error, identifier: "adhoc-error")
                }
                .padding(16)
                if let step = adHoc.step {
                    StepContent(adHoc: adHoc, step: step)
                } else if adHoc.busy {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                ContentUnavailableView(Copy.noCommands, systemImage: "terminal")
            }
        }
    }
}

/// A step's form and the actions it allows, or a finished command's result.
private struct StepContent: View {
    let adHoc: AdHocModel
    let step: AdHocResponse

    var body: some View {
        if step.isFinished {
            VStack(alignment: .leading, spacing: 0) {
                if let form = step.form, let table = adHoc.table {
                    ScrollView {
                        DataFormResultView(form: form, table: table)
                            .padding(16)
                    }
                } else if let form = step.form, form.type == .form {
                    // A form left in a finished command takes no answer: shown, not filled in.
                    ScrollView {
                        FormFieldsSummary(form: form)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let form = step.form {
                    DataFormView(form: form, onSubmit: { _ in })
                } else {
                    Spacer()
                }
                Divider()
                HStack {
                    Spacer()
                    if let command = adHoc.command {
                        ToolButton(title: Copy.runAgain, identifier: "adhoc-run-again") {
                            adHoc.run(command)
                        }
                    }
                }
                .padding(16)
            }
        } else if let form = step.form, form.type == .form {
            DataFormView(
                form: form, submitTitle: Self.title(step.primaryAction ?? .complete),
                actions: backAndCancel, alternateSubmit: alternate, busy: adHoc.busy
            ) { filled in
                adHoc.perform(step.primaryAction ?? .complete, form: filled)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    if let form = step.form {
                        FormFieldsSummary(form: form)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    if adHoc.busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    ForEach(backAndCancel) { action in
                        Button(action.title, action: action.perform)
                            .accessibilityIdentifier(action.id)
                    }
                    if let primary = step.primaryAction {
                        Button(Self.title(primary)) { adHoc.perform(primary) }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("form-submit")
                    }
                }
                .disabled(adHoc.busy)
                .controlSize(.large)
                .pointerStyle(.link)
                .padding(16)
            }
        }
    }

    /// Back where the step allows it, and Cancel while the command runs.
    private var backAndCancel: [FormAction] {
        var actions: [FormAction] = []
        if step.allowedActions.contains(.prev) {
            actions.append(
                FormAction(id: "adhoc-back", title: Copy.previousStep) {
                    adHoc.perform(.prev)
                })
        }
        actions.append(
            FormAction(id: "adhoc-cancel", title: Copy.cancel) { adHoc.perform(.cancel) })
        return actions
    }

    /// Finish beside Next, or Next beside Finish, when the step allows both.
    private var alternate: FormSubmit? {
        let forward = step.allowedActions.filter { $0 == .next || $0 == .complete }
        guard forward.count == 2, let other = forward.first(where: { $0 != step.primaryAction })
        else { return nil }
        return FormSubmit(id: "adhoc-\(other.rawValue)", title: Self.title(other)) { filled in
            adHoc.perform(other, form: filled)
        }
    }

    static func title(_ action: AdHocResponse.Action) -> String {
        switch action {
        case .next: Copy.nextStep
        case .prev: Copy.previousStep
        case .complete, .execute: Copy.finish
        case .cancel: Copy.cancel
        }
    }
}

private struct NoteRow: View {
    let note: AdHocResponse.Note

    var body: some View {
        let (symbol, colour, label): (String, Color, String) =
            switch note.type {
            case .info: ("info.circle", .secondary, Copy.noteInfo)
            case .warn: ("exclamationmark.triangle", .orange, Copy.noteWarning)
            case .error: ("xmark.octagon", .red, Copy.noteError)
            }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(colour)
                .accessibilityLabel(label)
            Text(note.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("adhoc-note")
    }
}
