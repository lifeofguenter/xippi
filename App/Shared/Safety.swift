import SwiftUI
import XMPPCore
import XippiSession

/// Blocking (XEP-0191) or reporting (XEP-0377) someone, waiting for the user to confirm it:
/// from a 1:1 chat's sidebar row, a room member's menu or a message's menu (App Review
/// guideline 1.2). Whom it acts on comes from `SafetyTarget`; someone in a room or channel is
/// ignored on this Mac (ruling R72), and only by nickname where nothing better is known.
struct SafetyRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case block
        /// Reports as spam and blocks.
        case report
    }

    let kind: Kind
    let accountID: Int64
    let target: SafetyTarget
    /// Who the question names: the contact's or the member's name.
    let name: String
    /// The stored messages the report points at, by their archive's stanza id.
    var messageIDs: [Int64] = []

    var id: String { "\(kind):\(accountID):\(target):\(messageIDs)" }

    private var nickOnly: Bool {
        if case .participant(let participant) = target { return participant.isNickOnly }
        return false
    }

    /// The menu item that asks: "Block", or "Ignore this nickname in this room".
    static func blockLabel(for target: SafetyTarget) -> String {
        if case .participant(let participant) = target, participant.isNickOnly {
            return Copy.ignoreNickname
        }
        return Copy.blockContact
    }

    /// "Block Bob?", "Ignore this nickname in this room?", "Report Bob as spam?"
    var title: String {
        switch kind {
        case .block: nickOnly ? Copy.ignoreNicknameTitle : Copy.blockTitle(name)
        case .report: Copy.reportTitle(name)
        }
    }

    /// The button that goes ahead.
    var action: String {
        switch kind {
        case .block: nickOnly ? Copy.ignore : Copy.blockContact
        case .report: Copy.reportAndBlock
        }
    }

    /// What it does, said plainly: the address the server blocks, and what is only on this
    /// Mac (m1): ignoring in rooms and channels never reaches the account's other devices.
    var detail: String {
        switch (kind, target) {
        case (.block, .contact(let jid)):
            return jid.description
        case (.block, .participant(let participant)):
            if let realJID = participant.realJID {
                let detail = Copy.blockInRoomsDetail(realJID.description)
                return participant.archiveMayShow ? detail + " " + Copy.archiveMayShow : detail
            }
            return participant.isNickOnly
                ? Copy.nicknameHereDetail(participant.address?.description ?? participant.name)
                : Copy.blockHereOnly
        case (.report, .contact):
            return Copy.reportDetail
        case (.report, .participant(let participant)):
            if participant.realJID != nil { return Copy.reportInRoomsDetail }
            // The report blocks the address the room sends their messages from (m-6).
            if let address = participant.address {
                return Copy.reportAddressDetail(address.description)
            }
            return participant.isNickOnly ? Copy.reportNicknameDetail : Copy.reportHereDetail
        }
    }

    /// Who the question names: a participant the room shows without a nickname reads "No
    /// nickname", never their participant id (m2).
    static func name(of participant: SafetyTarget.Participant) -> String {
        participant.name.isEmpty ? Copy.noNickname : participant.name
    }

    /// Runs it on the account's session: nil when done, else what went wrong.
    func perform(model: AppModel) async -> String? {
        let what = kind == .block ? Self.blockLabel(for: target) : Copy.reportSpam
        guard let session = await model.session(accountID: accountID) else {
            return Copy.failed(what, Copy.notConnectedReason)
        }
        do throws(SessionError) {
            let outcome: SafetyOutcome =
                switch kind {
                case .block: try await session.block(target)
                case .report: try await session.report(target, messageIDs: messageIDs)
                }
            // m6: ignored here, but the server did not take it: say so.
            guard case .ignoredOnly(let error) = outcome,
                case .participant(let participant) = target
            else { return nil }
            let reason = ChatCommandError.words(error)
            return kind == .block
                ? Copy.ignoredNotBlocked(participant.realJID?.description ?? name, reason)
                : Copy.ignoredNotReported(reason)
        } catch {
            return Copy.failed(what, ChatCommandError.words(error))
        }
    }
}

/// Asks before a block or a report: the button that goes ahead is red and names the action,
/// Cancel is the default. A failure shows where it was asked, in an alert over the window: the
/// selection never changes, so the chat of the person being blocked is not opened (I6).
struct SafetyConfirmation: ViewModifier {
    let model: AppModel
    @Bindable var sheets: ChatSheets

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                sheets.safety?.title ?? "",
                isPresented: Binding(
                    get: { sheets.safety != nil },
                    set: { if !$0 { sheets.safety = nil } }),
                presenting: sheets.safety
            ) { request in
                Button(request.action, role: .destructive) { run(request) }
                Button(Copy.cancel, role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { request in
                Text(request.detail)
            }
            .alert(
                sheets.safetyFailure ?? "",
                isPresented: Binding(
                    get: { sheets.safetyFailure != nil },
                    set: { if !$0 { sheets.safetyFailure = nil } })
            ) {
                Button(Copy.close, role: .cancel) {}
            }
    }

    private func run(_ request: SafetyRequest) {
        Task {
            guard let failure = await request.perform(model: model) else { return }
            sheets.safetyFailure = failure
        }
    }
}
