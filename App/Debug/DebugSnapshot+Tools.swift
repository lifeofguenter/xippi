#if DEBUG || UITEST_HOOKS
    import AppKit
    import SwiftUI
    import XMPPCore
    import XippiSession
    import XippiStore

    /// `-UITestAction` steps for the power tools and the channels, on the first account (with
    /// `-UITestDatabase memory` the account connects for real):
    /// - `console`: puts an XML console on the account; `consolesend <xml>` types and sends
    ///   it (the first time it asks); `consoleconfirm`; `consolefilter <text>`;
    ///   `consolepretty`; `consolepause`; `consoleshot <suffix>`: saves
    ///   `<name>.console-<suffix>.png` and `.txt` (every record, and checks: own presence, SASL
    ///   hidden).
    /// - `disco [jid]`: service discovery from the server or `jid`; `discoopen <jid>`: lists the
    ///   items of a row; `discoselect <jid>`; `discoshot <suffix>`.
    /// - `adhoc <jid> [node]`: the ad-hoc commands of `jid`, running `node`; `adhocrun <node>`;
    ///   `adhocnext`: the step's default action with its form as it is; `adhocshot <suffix>`.
    /// - `joinchannel <jid> <nick>`: the account joins a channel; `createchannel <service>
    ///   <name> <nick>`; `channelsheet <join|create> [jid]`: saves the sheet;
    ///   `channelshot <chat name> <suffix>`: the channel inspector of that chat.
    /// - `formtable`: saves a multi-item result (`<name>.form-table.png`).
    extension DebugSnapshot {
        private static var console: XMLConsoleModel?
        private static var discovery: DiscoveryModel?
        private static var adHoc: AdHocModel?
        private static var channelResult = ""

        /// Whether the step was one of these.
        static func performTools(_ parts: [String]) async -> Bool {
            guard toolSteps.contains(parts.first ?? "") else { return false }
            guard let model, let account = model.accounts.first, let accountID = account.id
            else { return true }
            let argument = parts.count > 1 ? parts[1] : ""
            let words = argument.split(separator: " ").map(String.init)
            switch parts.first {
            case "console":
                let console = XMLConsoleModel(model: model, accountID: accountID)
                console.start()
                self.console = console
            case "consolesend":
                console?.draft = argument
                console?.send()
            case "consoleconfirm": console?.confirmSend()
            case "consolefilter": console?.filterText = argument
            case "consolepretty": console?.pretty.toggle()
            case "consolepause": console?.paused.toggle()
            case "consoleshot": await consoleShot(argument, model: model)
            case "disco":
                let discovery = DiscoveryModel(
                    model: model,
                    target: DiscoveryTarget(
                        accountID: accountID, jid: argument.isEmpty ? nil : argument))
                discovery.load()
                self.discovery = discovery
            case "discoopen":
                guard let jid = try? JID(argument) else { return true }
                discovery?.loadItems(DiscoKey(jid: jid))
            case "discoselect":
                guard let discovery else { return true }
                discovery.selection = discovery.rowID(of: argument)
            case "discoshot": await discoShot(argument, model: model)
            case "adhoc":
                let adHoc = AdHocModel(
                    model: model,
                    target: AdHocTarget(
                        accountID: accountID, jid: words.first ?? "",
                        node: words.count > 1 ? words[1] : nil))
                adHoc.start()
                self.adHoc = adHoc
            case "adhocrun":
                guard let adHoc, case .loaded(let commands) = adHoc.commands,
                    let command = commands.first(where: { $0.node == argument })
                else { return true }
                adHoc.run(command)
            case "adhocnext":
                guard let adHoc, let step = adHoc.step, let action = step.primaryAction else {
                    return true
                }
                adHoc.perform(action, form: step.form?.submit(values: [:]))
            case "adhocshot": await adHocShot(argument, model: model)
            case "joinchannel":
                await channelCommand(model: model, accountID: accountID) { session in
                    guard let jid = try? JID(words.first ?? "") else { return "invalid" }
                    let chatID = try await session.joinChannel(
                        jid: jid, nick: words.count > 1 ? words[1] : "tester")
                    let state = await ChannelJoining.settledState(model, chatID: chatID)
                    return "joined chat \(chatID) state=\(String(describing: state))"
                }
            case "createchannel":
                await channelCommand(model: model, accountID: accountID) { session in
                    guard words.count > 2, let service = try? JID(words[0]) else {
                        return "invalid"
                    }
                    let chatID = try await session.createChannel(
                        on: service, name: words[1], nick: words[2])
                    return "created chat \(chatID)"
                }
            case "channelsheet":
                await channelSheet(words, model: model, accountID: accountID)
            case "channelshot":
                await channelShot(words, model: model)
            case "accountrows":
                // The account popover's rows with the settings, so the Tools pull-down shows.
                await renderOffscreen(
                    AccountStatusList(model: model).environment(AppSettings()),
                    size: NSSize(width: 380, height: 320),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling("account-rows-\(argument)"))
            case "formtable":
                guard let table = Self.sampleTable.table else { return true }
                await renderOffscreen(
                    ScrollView {
                        DataFormResultView(form: Self.sampleTable, table: table)
                            .padding(16)
                    }, size: NSSize(width: 640, height: 360),
                    dark: NSApp.effectiveAppearance.isDark, to: sibling("form-table"))
            default:
                break
            }
            return true
        }

        private static let toolSteps: Set<String> = [
            "console", "consolesend", "consoleconfirm", "consolefilter", "consolepretty",
            "consolepause", "consoleshot", "disco", "discoopen", "discoselect", "discoshot",
            "adhoc", "adhocrun", "adhocnext", "adhocshot", "joinchannel", "createchannel",
            "channelsheet", "channelshot", "formtable", "accountrows",
        ]

        // MARK: Console

        private static func consoleShot(_ suffix: String, model: AppModel) async {
            guard let console else { return }
            let online: Bool
            if case .online = model.status.connection[console.accountID] {
                online = true
            } else {
                online = false
            }
            await renderOffscreen(
                XMLConsoleView(console: console, online: online),
                size: NSSize(width: 900, height: 640), dark: NSApp.effectiveAppearance.isDark,
                to: sibling("console-\(suffix)"))
            if console.confirmingSend {
                await renderOffscreen(
                    ConfirmationSheet(
                        title: Copy.sendRawTitle(console.jid), actionTitle: Copy.sendXML,
                        identifier: "console-send", onConfirm: {}, onCancel: {}),
                    size: NSSize(width: 420, height: 130), dark: NSApp.effectiveAppearance.isDark,
                    to: sibling("console-\(suffix)-sheet"))
            }
            let records = console.tap.records
            let sasl = records.filter {
                $0.xml.contains("urn:ietf:params:xml:ns:xmpp-sasl")
                    && ["<auth ", "<response", "<challenge", "<success"].contains(
                        where: $0.xml.hasPrefix)
            }
            var lines = [
                "online=\(online) total=\(console.total) shown=\(console.shown.count)"
                    + " paused=\(console.paused) pretty=\(console.pretty)",
                "ownPresenceOut=\(records.contains { $0.direction == .outgoing && $0.xml.hasPrefix("<presence") })",
                "ownPresenceIn=\(records.contains { $0.direction == .incoming && $0.xml.hasPrefix("<presence") && $0.xml.contains("from='\(console.jid)/") })",
                "saslRecords=\(sasl.count) saslAllHidden=\(sasl.allSatisfy { $0.xml.contains(">hidden<") || $0.xml.hasSuffix("/>") })",
                "passwordInRing=\(records.contains { $0.xml.contains("xippi-test") })",
                "sendProblem=\(console.sendProblem ?? "-") confirming=\(console.confirmingSend)",
            ]
            for record in records {
                lines.append("\(record.direction == .incoming ? "IN " : "OUT") \(record.xml)")
            }
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension(
                    "console-\(suffix).txt"))
        }

        // MARK: Discovery

        private static func discoShot(_ suffix: String, model: AppModel) async {
            guard let discovery else { return }
            await renderOffscreen(
                ServiceDiscoveryWindow(model: model, discovery: discovery),
                size: NSSize(width: 960, height: 620), dark: NSApp.effectiveAppearance.isDark,
                to: sibling("disco-\(suffix)"))
            var lines: [String] = []
            func walk(_ nodes: [DiscoNode], depth: Int) {
                for node in nodes {
                    lines.append(String(repeating: "  ", count: depth) + "\(node.kind)")
                    walk(node.children ?? [], depth: depth + 1)
                }
            }
            walk(discovery.tree(), depth: 0)
            if let selected = discovery.selected {
                lines.append("selected=\(selected.key.jid)#\(selected.key.node ?? "")")
                if case .loaded(let details) = discovery.infos[selected.key] {
                    let info = details.info
                    lines.append("identities=\(details.identities)")
                    lines.append("features=\(details.features) omitted=\(details.omitted)")
                    lines.append(
                        "actions=\(discovery.actions(for: selected.key, parent: selected.parent, info: info))"
                    )
                } else {
                    lines.append("info=\(String(describing: discovery.infos[selected.key]))")
                }
            }
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("disco-\(suffix).txt"))
        }

        // MARK: Ad-hoc

        private static func adHocShot(_ suffix: String, model: AppModel) async {
            guard let adHoc else { return }
            // Read first: closing the drawn window cancels the command, as a closed window does.
            var lines = ["commands=\(adHoc.commands)", "error=\(adHoc.error ?? "-")"]
            if let step = adHoc.step {
                lines.append(
                    "step node=\(step.node) status=\(step.status) allowed=\(step.allowedActions)"
                        + " primary=\(String(describing: step.primaryAction))")
                lines.append("notes=\(step.notes.map(\.text))")
                lines.append(
                    "form=\(String(describing: step.form?.title)) fields=\(step.form?.fields.map { $0.variable ?? "" } ?? [])"
                )
                lines.append("table=\(String(describing: step.form?.table))")
            }
            write(
                lines.joined(separator: "\n").data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("adhoc-\(suffix).txt"))
            await renderOffscreen(
                AdHocCommandWindow(adHoc: adHoc), size: NSSize(width: 900, height: 620),
                dark: NSApp.effectiveAppearance.isDark, to: sibling("adhoc-\(suffix)"))
        }

        // MARK: Channels

        private static func channelCommand(
            model: AppModel, accountID: Int64,
            _ work: @MainActor (AccountSession) async throws -> String
        ) async {
            guard let session = await model.sessions.session(for: accountID) else {
                channelResult += "no session\n"
                return
            }
            do {
                channelResult += try await work(session) + "\n"
            } catch {
                channelResult += "error: \(error)\n"
            }
            write(
                channelResult.data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("channels.txt"))
        }

        private static func channelSheet(_ words: [String], model: AppModel, accountID: Int64)
            async
        {
            let dark = NSApp.effectiveAppearance.isDark
            if words.first == "create" {
                await renderOffscreen(
                    CreateChannelSheet(model: model) { _ in },
                    size: NSSize(width: 460, height: 420),
                    dark: dark, to: sibling("channel-create"))
            } else {
                await renderOffscreen(
                    JoinChannelSheet(
                        model: model, accountID: accountID,
                        channel: words.count > 1 ? words[1] : nil
                    ) { _ in }, size: NSSize(width: 460, height: 360), dark: dark,
                    to: sibling("channel-join"))
            }
        }

        private static func channelShot(_ words: [String], model: AppModel) async {
            guard
                let item = model.chats.first(where: {
                    $0.chat.jid == words.first || $0.displayName == words.first
                })
            else {
                channelResult += "no chat \(words.first ?? "")\n"
                return
            }
            let info = OpenChatInfo(item)
            await renderOffscreen(
                ScrollView {
                    VStack(alignment: .leading, spacing: ControlHeight.Inspector.sectionSpacing) {
                        InspectorHeader(info: info)
                        ChannelDetails(
                            model: model, info: info, sheets: ChatSheets(),
                            context: OpenChatContext())
                    }
                    .padding(ControlHeight.Inspector.margin)
                }, size: NSSize(width: 300, height: 600),
                dark: NSApp.effectiveAppearance.isDark,
                to: sibling("channel-\(words.count > 1 ? words[1] : "inspector")"))
            if let session = await model.sessions.session(for: item.chat.accountID) {
                let members = try? await session.channelMembers(chatID: item.id)
                channelResult +=
                    "members of \(item.chat.jid): \(members?.map { "\($0.name ?? "nil") self=\($0.isSelf)" } ?? [])\n"
                channelResult += "state=\(String(describing: model.status.rooms[item.id]))\n"
            }
            write(
                channelResult.data(using: .utf8),
                to: outputURL.deletingPathExtension().appendingPathExtension("channels.txt"))
        }

        /// XEP-0004 example 8: a multi-item result.
        static let sampleTable = DataForm(
            type: .result, title: "Search Results",
            reported: [
                .init(variable: "name", label: "Name"),
                .init(variable: "url", label: "URL"),
                .init(variable: "admin", type: .boolean, label: "Admin"),
            ],
            items: [
                [
                    .init(
                        variable: "name",
                        values: ["Comune di Verona - Benvenuti nel sito ufficiale"]),
                    .init(variable: "url", values: ["http://www.comune.verona.it/"]),
                    .init(variable: "admin", values: ["1"]),
                ],
                [
                    .init(variable: "name", values: ["benvenuto!"]),
                    .init(variable: "url", values: ["http://www.hellasweb.it/"]),
                ],
                [
                    .init(
                        variable: "name", values: ["Universita degli Studi di Verona - Home Page"]),
                    .init(variable: "url", values: ["http://www.univr.it/"]),
                    .init(variable: "admin", values: ["0"]),
                ],
            ])
    }
#endif
