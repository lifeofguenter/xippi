import Observation
import SwiftUI
import XMPPCore
import XippiSession
import XippiStore

/// One entity, or one of its nodes, in service discovery (XEP-0030).
struct DiscoKey: Hashable, Sendable {
    var jid: JID
    var node: String?
}

/// Something asked for and its answer.
enum DiscoLoad<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// A row of the discovery tree. The same entity can be listed under several parents, so a
/// row's id is its path from the top.
struct DiscoNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case entity(DiscoKey, name: String?)
        /// Shown under a parent whose items are not in yet; asks for them when it appears.
        case loading(parent: DiscoKey)
        case failed(String)
    }

    let id: String
    let kind: Kind
    /// Nil for a leaf.
    var children: [DiscoNode]?
}

/// What the service discovery window shows of one account: a tree of disco#items from the
/// account's server (or another entity), each item's disco#info on selection, and what can
/// be done with it.
@MainActor @Observable final class DiscoveryModel {
    /// Items shown per entity: a big server lists thousands of rooms.
    static let maxItems = 500
    /// How deep the tree goes; an entity is never listed under itself.
    static let maxDepth = 12

    let accountID: Int64
    private(set) var root: DiscoKey?
    var address: String
    private(set) var addressProblem: String?
    var selection: String?
    private(set) var items: [DiscoKey: DiscoLoad<[DiscoItem]>] = [:]
    private(set) var infos: [DiscoKey: DiscoLoad<DiscoDetails>] = [:]

    @ObservationIgnored private let model: AppModel
    /// The rows by id, from the last tree built, for the selection.
    @ObservationIgnored private var keysByID: [String: (key: DiscoKey, parent: DiscoKey?)] = [:]

    init(model: AppModel, target: DiscoveryTarget) {
        self.model = model
        accountID = target.accountID
        let account = model.accounts.first { $0.id == target.accountID }?.jid ?? ""
        let start = target.jid ?? (try? JID(account))?.domainpart ?? account
        address = start
        root = (try? JID(start)).map { DiscoKey(jid: $0) }
    }

    var accountJID: String {
        model.accounts.first { $0.id == accountID }?.jid ?? ""
    }

    /// Starts again from the entity in the address field.
    func browse() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jid = try? JID(text) else {
            addressProblem = Copy.invalidAddress(text)
            return
        }
        addressProblem = nil
        address = jid.description
        root = DiscoKey(jid: jid)
        items = [:]
        infos = [:]
        selection = nil
        load()
    }

    /// Asks for the root's items and info.
    func load() {
        guard let root else { return }
        loadItems(root)
        loadInfo(root)
    }

    /// The tree under the root, built from what has been read.
    func tree() -> [DiscoNode] {
        guard let root else { return [] }
        var index: [String: (key: DiscoKey, parent: DiscoKey?)] = [:]
        let nodes = children(of: root, path: "", ancestors: [root], index: &index) ?? []
        keysByID = index
        return nodes
    }

    private func children(
        of key: DiscoKey, path: String, ancestors: Set<DiscoKey>,
        index: inout [String: (key: DiscoKey, parent: DiscoKey?)]
    ) -> [DiscoNode]? {
        switch items[key] {
        case nil, .loading:
            return [DiscoNode(id: path + "/~loading", kind: .loading(parent: key))]
        case .failed(let reason):
            return [DiscoNode(id: path + "/~failed", kind: .failed(reason))]
        case .loaded(let list):
            guard !list.isEmpty else { return nil }
            return list.prefix(Self.maxItems).enumerated().compactMap { offset, item in
                let child = DiscoKey(jid: item.jid, node: item.node)
                guard !ancestors.contains(child) else { return nil }
                let id = "\(path)/\(offset):\(item.jid)#\(item.node ?? "")"
                index[id] = (child, key)
                var node = DiscoNode(id: id, kind: .entity(child, name: item.name))
                if ancestors.count < Self.maxDepth {
                    node.children = children(
                        of: child, path: id, ancestors: ancestors.union([child]), index: &index)
                }
                return node
            }
        }
    }

    /// The entity selected, or the root without a selection.
    var selected: (key: DiscoKey, parent: DiscoKey?)? {
        if let selection, let entry = keysByID[selection] { return entry }
        return root.map { ($0, nil) }
    }

    func loadItems(_ key: DiscoKey) {
        guard items[key] == nil else { return }
        items[key] = .loading
        let accountID = accountID
        Task { [weak self, model] in
            guard let session = await model.sessions.session(for: accountID) else {
                self?.items[key] = .failed(Copy.notConnectedReason)
                return
            }
            do throws(IQError) {
                let found = try await Disco.items(
                    key.jid, node: key.node, via: session.toolRequests)
                self?.items[key] = .loaded(found)
            } catch {
                self?.items[key] = .failed(Copy.toolReason(error))
            }
        }
    }

    func loadInfo(_ key: DiscoKey) {
        if case .loaded = infos[key] { return }
        if case .loading = infos[key] { return }
        infos[key] = .loading
        let accountID = accountID
        Task { [weak self, model] in
            guard let session = await model.sessions.session(for: accountID) else {
                self?.infos[key] = .failed(Copy.notConnectedReason)
                return
            }
            do throws(IQError) {
                let info = try await Disco.info(key.jid, node: key.node, via: session.toolRequests)
                self?.infos[key] = .loaded(await DiscoDetails.make(info))
            } catch {
                self?.infos[key] = .failed(Copy.toolReason(error))
            }
        }
    }

    /// Tries a failed lookup again.
    func retry(_ key: DiscoKey) {
        if case .failed = items[key] { items[key] = nil }
        if case .failed = infos[key] { infos[key] = nil }
        loadItems(key)
        loadInfo(key)
    }

    // MARK: What can be done

    enum EntityAction: Hashable {
        /// The entity lists ad-hoc commands (XEP-0050).
        case commands
        /// The entity is a command node: run it.
        case run(node: String)
        /// A MUC room.
        case joinRoom
        /// A MIX channel.
        case joinChannel
        /// Browse from this entity.
        case browse
    }

    func actions(for key: DiscoKey, parent: DiscoKey?, info: DiscoInfo?) -> [EntityAction] {
        var actions: [EntityAction] = []
        let features = info?.features ?? []
        if let node = key.node {
            let isCommand =
                parent?.node == AdHoc.namespace
                || info?.identities.contains {
                    $0.category == "automation" && $0.type == "command-node"
                } == true
            if isCommand { actions.append(.run(node: node)) }
        } else {
            if features.contains(AdHoc.namespace) { actions.append(.commands) }
            if key.jid.localpart != nil, key.jid.resourcepart == nil {
                if features.contains(MIX.coreNamespace) {
                    actions.append(.joinChannel)
                } else if features.contains(MUC.namespace) {
                    actions.append(.joinRoom)
                }
            }
        }
        if key != root { actions.append(.browse) }
        return actions
    }

    /// The row of the entity `jid` (without a node), the one nearest the top when it is listed
    /// more than once.
    func rowID(of jid: String) -> String? {
        _ = tree()
        return keysByID.filter { $0.value.key.jid.description == jid && $0.value.key.node == nil }
            .keys.min { $0.count < $1.count }
    }

    func browse(from key: DiscoKey) {
        address = key.jid.description
        browse()
    }
}

/// The service discovery window: the tree on the left, the selected entity on the right.
struct ServiceDiscoveryWindow: View {
    @State private var discovery: DiscoveryModel
    @State private var joining: ChannelToJoin?
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    init(model: AppModel, target: DiscoveryTarget) {
        self.init(model: model, discovery: DiscoveryModel(model: model, target: target))
    }

    /// The window on a model already made, for the snapshot hook.
    init(model: AppModel, discovery: DiscoveryModel) {
        self.model = model
        _discovery = State(initialValue: discovery)
    }

    var body: some View {
        @Bindable var discovery = discovery
        HSplitView {
            DiscoveryTree(discovery: discovery)
                .frame(minWidth: 240, idealWidth: ControlHeight.Tools.listWidth)
            DiscoveryDetail(discovery: discovery, perform: perform)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 420)
        .font(.appBody)
        .navigationTitle(Copy.serviceDiscovery)
        .navigationSubtitle(discovery.accountJID)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField(Copy.address, text: $discovery.address)
                    .textFieldStyle(.roundedBorder)
                    .font(.appMonospaced)
                    .autocorrectionDisabled()
                    .frame(minWidth: 260, idealWidth: 340)
                    .onSubmit { discovery.browse() }
                    .accessibilityIdentifier("disco-address")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(Copy.browse, systemImage: "arrow.right.circle") { discovery.browse() }
                    .help(Copy.browse)
                    .pointerStyle(.link)
                    .accessibilityIdentifier("disco-browse")
            }
        }
        .onAppear { discovery.load() }
        .sheet(item: $joining) { channel in
            JoinChannelSheet(
                model: model, accountID: discovery.accountID, channel: channel.id
            ) { chatID in
                joining = nil
                if let chatID { model.open(chatID: chatID) }
            }
        }
        .accessibilityIdentifier("service-discovery")
    }

    private func perform(_ action: DiscoveryModel.EntityAction, on key: DiscoKey) {
        switch action {
        case .commands:
            openWindow(
                id: ToolWindow.commands,
                value: AdHocTarget(accountID: discovery.accountID, jid: key.jid.description))
        case .run(let node):
            openWindow(
                id: ToolWindow.commands,
                value: AdHocTarget(
                    accountID: discovery.accountID, jid: key.jid.description, node: node))
        case .joinRoom:
            // RFC 5122: the address percent-encoded, so ?, # and ; in it stay part of it.
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#;%")
            guard
                let address = key.jid.description.addingPercentEncoding(
                    withAllowedCharacters: allowed),
                let url = URL(string: "xmpp:\(address)?join")
            else { return }
            AppDelegate.links?.open(url)
        case .joinChannel:
            joining = ChannelToJoin(id: key.jid.description)
        case .browse:
            discovery.browse(from: key)
        }
    }
}

/// A channel the join sheet opens for.
struct ChannelToJoin: Identifiable, Hashable {
    let id: String
}

/// The tree of items. Rows whose items are not in yet show "Loading" and ask for them when
/// opened.
private struct DiscoveryTree: View {
    @Bindable var discovery: DiscoveryModel

    var body: some View {
        let nodes = discovery.tree()
        Group {
            if nodes.isEmpty {
                ContentUnavailableView(Copy.noItems, systemImage: "list.bullet.indent")
            } else {
                List(nodes, children: \.children, selection: $discovery.selection) { node in
                    DiscoRow(node: node, discovery: discovery)
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityIdentifier("disco-tree")
    }
}

private struct DiscoRow: View {
    let node: DiscoNode
    let discovery: DiscoveryModel

    var body: some View {
        switch node.kind {
        case .entity(let key, let name):
            VStack(alignment: .leading, spacing: 1) {
                Text(name?.isEmpty == false ? (name ?? "") : key.jid.description)
                    .lineLimit(1)
                if name?.isEmpty == false || key.node != nil {
                    Text(Self.detail(key))
                        .font(.appMonospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(Self.detail(key))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("disco-item:\(key.jid)#\(key.node ?? "")")
        case .loading(let parent):
            Text(Copy.loading)
                .foregroundStyle(.secondary)
                .onAppear { discovery.loadItems(parent) }
        case .failed(let reason):
            Text(Copy.notAvailable(reason))
                .foregroundStyle(.red)
        }
    }

    static func detail(_ key: DiscoKey) -> String {
        key.node.map { "\(key.jid) \($0)" } ?? key.jid.description
    }
}

/// The selected entity: what it is, what it supports, and what can be done with it.
private struct DiscoveryDetail: View {
    let discovery: DiscoveryModel
    let perform: (DiscoveryModel.EntityAction, DiscoKey) -> Void

    var body: some View {
        if let selected = discovery.selected {
            EntityDetail(
                discovery: discovery, key: selected.key, parent: selected.parent,
                perform: perform
            )
            .id(selected.key)
        } else {
            ContentUnavailableView(Copy.noItems, systemImage: "server.rack")
        }
    }
}

private struct EntityDetail: View {
    let discovery: DiscoveryModel
    let key: DiscoKey
    let parent: DiscoKey?
    let perform: (DiscoveryModel.EntityAction, DiscoKey) -> Void

    var body: some View {
        let load = discovery.infos[key]
        let info: DiscoInfo? = if case .loaded(let details) = load { details.info } else { nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(info)
                actions(info)
                switch load {
                case .failed(let reason):
                    ToolError(text: Copy.notAvailable(reason), identifier: "disco-info-error")
                    ToolButton(title: Copy.browse, identifier: "disco-retry") {
                        discovery.retry(key)
                    }
                case .loaded(let details):
                    InfoSections(details: details)
                case .loading, nil:
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { discovery.loadInfo(key) }
        .accessibilityIdentifier("disco-detail")
    }

    private func header(_ info: DiscoInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info?.identities.first { $0.name?.isEmpty == false }?.name ?? key.jid.description)
                .font(.appTitle)
                .textSelection(.enabled)
            Text(key.jid.description)
                .font(.appMonospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("disco-detail-jid")
            if let node = key.node {
                LabeledContent(Copy.node) {
                    Text(node)
                        .font(.appMonospaced)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ info: DiscoInfo?) -> some View {
        let actions = discovery.actions(for: key, parent: parent, info: info)
        if !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(actions, id: \.self) { action in
                    ToolButton(title: Self.title(action), identifier: Self.identifier(action)) {
                        perform(action, key)
                    }
                }
            }
        }
    }

    static func title(_ action: DiscoveryModel.EntityAction) -> String {
        switch action {
        case .commands: Copy.commands
        case .run: Copy.runCommand
        case .joinRoom, .joinChannel: Copy.join
        case .browse: Copy.browse
        }
    }

    static func identifier(_ action: DiscoveryModel.EntityAction) -> String {
        switch action {
        case .commands: "disco-commands"
        case .run: "disco-run"
        case .joinRoom: "disco-join-room"
        case .joinChannel: "disco-join-channel"
        case .browse: "disco-browse-here"
        }
    }
}

/// What the detail pane shows of an entity's disco#info, sorted and bounded once: any
/// address typed in can answer with thousands of features.
struct DiscoDetails: Sendable {
    static let maxIdentities = 100
    static let maxFeatures = 1_000
    static let maxForms = 20

    let info: DiscoInfo
    let identities: [DiscoInfo.Identity]
    let features: [String]
    let forms: [DataForm]
    /// Identities, features and forms not shown.
    let omitted: Int

    /// Sorted off the main actor.
    @concurrent static func make(_ info: DiscoInfo) async -> DiscoDetails {
        let features = info.features.sorted()
        let forms = info.forms.prefix(maxForms).map { $0.bounded() }
        return DiscoDetails(
            info: info, identities: Array(info.identities.prefix(maxIdentities)),
            features: Array(features.prefix(maxFeatures)), forms: forms.map(\.form),
            omitted: max(info.identities.count - maxIdentities, 0)
                + max(features.count - maxFeatures, 0) + max(info.forms.count - maxForms, 0)
                + forms.reduce(0) { $0 + $1.omittedFields })
    }
}

/// Identities, features and extension forms (XEP-0128), as the entity sent them, within
/// `DiscoDetails`' bounds.
private struct InfoSections: View {
    let details: DiscoDetails

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            section(Copy.identities, identifier: "disco-identities") {
                ForEach(Array(details.identities.enumerated()), id: \.offset) { _, identity in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(identity.category)/\(identity.type)")
                            .font(.appMonospaced)
                        if let name = identity.name, !name.isEmpty {
                            Text(name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            section(Copy.features, identifier: "disco-features") {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(details.features, id: \.self) { feature in
                        Text(verbatim: feature)
                            .font(.appMonospaced)
                            .textSelection(.enabled)
                    }
                }
            }
            if !details.forms.isEmpty {
                section(Copy.extensionForms, identifier: "disco-forms") {
                    ForEach(Array(details.forms.enumerated()), id: \.offset) { _, form in
                        FormFieldsSummary(form: form)
                    }
                }
            }
            if details.omitted > 0 {
                Text(Copy.moreNotShown(details.omitted))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section(
        _ title: String, identifier: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A form's fields as label and values, private values masked.
struct FormFieldsSummary: View {
    let form: DataForm

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let type = form.formType {
                Text(verbatim: type)
                    .font(.appMonospaced)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(form.fields.enumerated()), id: \.offset) { _, field in
                if field.type != .hidden, let name = field.label ?? field.variable {
                    LabeledContent(name) {
                        Text(
                            field.type == .textPrivate
                                ? Copy.hiddenValue : field.values.joined(separator: "\n")
                        )
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
