import Foundation
import OMEMO
import Synchronization
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// The one-time pre key the key exchange for `deviceID` in `stanza` was built from.
func preKeyUsed(in stanza: Element, for deviceID: UInt32, version: OMEMO.OMEMOVersion) throws
    -> UInt32
{
    func keys(_ element: Element) -> [Element] {
        element.elements.flatMap { $0.name == "key" ? [$0] : keys($0) }
    }
    let encrypted = try #require(stanza.child("encrypted", namespace: version.rawValue))
    let key = try #require(keys(encrypted).first { $0[attribute: "rid"] == String(deviceID) })
    let data = try #require(
        Data(base64Encoded: key.text.trimmingCharacters(in: .whitespacesAndNewlines)))
    return try KeyExchangeMessage(serialized: data, version: version).preKeyID
}

/// Every account's PEP nodes and every room's member lists, as servers would keep them, for
/// OMEMO tests. Accounts reach it through `OMEMOTestSender`s, the scripted session server
/// through `answer(_:from:)`.
final class FakePEP: Sendable {
    struct Published: Sendable, Equatable {
        var account: JID
        var node: String
        var itemID: String?
        var options: [String: String]
    }

    struct Configured: Sendable, Equatable {
        var account: JID
        var node: String
        var options: [String: String]
    }

    private struct State {
        /// Items by account, node, in the order published.
        var nodes: [JID: [String: [PubSubItem]]] = [:]
        var published: [Published] = []
        var configured: [Configured] = []
        /// Nodes whose next publish with options is refused as precondition-not-met.
        var refuseOnce: Set<String> = []
        var members: [JID: [MUCPresence.Affiliation: [JID]]] = [:]
        var itemRequests = 0
    }

    private let state = Mutex(State())

    var published: [Published] { state.withLock { $0.published } }
    var configured: [Configured] { state.withLock { $0.configured } }
    var itemRequests: Int { state.withLock { $0.itemRequests } }

    func refusePublishOnce(node: String) {
        state.withLock { _ = $0.refuseOnce.insert(node) }
    }

    /// Takes pre key `id` out of `account`'s published bundle of `deviceID`, as the account's
    /// next publish does once it has read the key exchange that used it (Task 17c). Two
    /// sessions built from one bundle that nobody published again in between pick the same
    /// pre key 1 time in `OMEMOEngine.preKeyCount`. False when the bundle did not have it.
    func withdraw(preKey id: UInt32, of account: JID, deviceID: UInt32, version: OMEMO.OMEMOVersion)
        -> Bool
    {
        let node = OMEMOBundle.node(version: version, deviceID: deviceID)
        let itemID = OMEMOBundle.itemID(version: version, deviceID: deviceID)
        guard var bundle = items(node, of: account).last(where: { $0.id == itemID })?.payload
        else { return false }
        let before = bundle.xml()
        bundle.children = bundle.children.map { node in
            guard case .element(var preKeys) = node, preKeys.name == "prekeys" else { return node }
            preKeys.children = preKeys.children.filter { child in
                guard case .element(let preKey) = child else { return true }
                return (preKey[attribute: "preKeyId"] ?? preKey[attribute: "id"]) != String(id)
            }
            return .element(preKeys)
        }
        put(bundle, id: itemID, node: node, of: account)
        return bundle.xml() != before
    }

    func setMembers(_ jids: [JID], affiliation: MUCPresence.Affiliation, of room: JID) {
        state.withLock { $0.members[room.bare, default: [:]][affiliation] = jids }
    }

    /// The payloads of `node` at `account`, oldest first.
    func items(_ node: String, of account: JID) -> [PubSubItem] {
        state.withLock { $0.nodes[account.bare]?[node] ?? [] }
    }

    /// Sets an item as if the account had published it.
    func put(_ payload: Element, id: String, node: String, of account: JID) {
        state.withLock { Self.store(&$0, payload, id: id, node: node, account: account.bare) }
    }

    func deviceIDs(of account: JID, version: OMEMO.OMEMOVersion) -> [UInt32] {
        let node = DeviceList.node(version: version)
        guard let list = items(node, of: account).last?.payload else { return [] }
        return DeviceList.deviceIDs(in: list, version: version) ?? []
    }

    private static func store(
        _ state: inout State, _ payload: Element, id: String?, node: String, account: JID
    ) {
        var items = state.nodes[account]?[node] ?? []
        items.removeAll { $0.id != nil && $0.id == id }
        items.append(PubSubItem(id: id, payload: payload))
        state.nodes[account, default: [:]][node] = items
    }

    /// The answer to an IQ `account` sent: a result, or an error; nil when it is no PubSub or
    /// room administration request.
    func answer(_ iq: Element, from account: JID) -> Element? {
        let account = account.bare
        guard let payload = iq.elements.first else { return nil }
        switch payload.namespace {
        case PubSub.namespace:
            if let items = payload.child("items", namespace: PubSub.namespace) {
                return answerItems(iq, items, service: iq.to?.bare ?? account)
            }
            if let publish = payload.child("publish", namespace: PubSub.namespace) {
                return answerPublish(iq, publish, payload: payload, account: account)
            }
            return nil
        case PubSub.ownerNamespace:
            guard let configure = payload.child("configure", namespace: PubSub.ownerNamespace),
                let node = configure[attribute: "node"]
            else { return nil }
            state.withLock {
                $0.configured.append(
                    Configured(account: account, node: node, options: Self.fields(in: configure)))
            }
            return iq.iqResult()
        case "http://jabber.org/protocol/muc#admin":
            guard let room = iq.to?.bare,
                let affiliation = payload.child("item")?[attribute: "affiliation"].flatMap(
                    MUCPresence.Affiliation.init(rawValue:))
            else { return nil }
            let jids = state.withLock { $0.members[room]?[affiliation] ?? [] }
            var query = Element("query", namespace: payload.namespace)
            for jid in jids {
                query.append(
                    Element(
                        "item", namespace: payload.namespace,
                        attributes: ["jid": jid.description, "affiliation": affiliation.rawValue]))
            }
            return iq.iqResult(payload: query)
        default:
            return nil
        }
    }

    private func answerItems(_ iq: Element, _ request: Element, service: JID) -> Element {
        guard let node = request[attribute: "node"] else {
            return iq.errorResponse(StanzaError(type: .modify, condition: .badRequest))
        }
        let stored: [PubSubItem]? = state.withLock {
            $0.itemRequests += 1
            return $0.nodes[service]?[node]
        }
        guard var found = stored else {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .itemNotFound))
        }
        let ids = request.children("item", namespace: PubSub.namespace).compactMap {
            $0[attribute: "id"]
        }
        if !ids.isEmpty { found = found.filter { $0.id.map(ids.contains) ?? false } }
        if let max = request[attribute: "max_items"].flatMap(Int.init) {
            found = Array(found.suffix(max))
        }
        var items = Element("items", namespace: PubSub.namespace, attributes: ["node": node])
        for item in found {
            var element = Element("item", namespace: PubSub.namespace)
            element[attribute: "id"] = item.id
            if let payload = item.payload { element.append(payload) }
            items.append(element)
        }
        return iq.iqResult(
            payload: Element("pubsub", namespace: PubSub.namespace, children: [.element(items)]))
    }

    private func answerPublish(
        _ iq: Element, _ publish: Element, payload: Element, account: JID
    ) -> Element {
        guard let node = publish[attribute: "node"],
            let item = publish.child("item", namespace: PubSub.namespace),
            let content = item.elements.first
        else { return iq.errorResponse(StanzaError(type: .modify, condition: .badRequest)) }
        let options =
            payload.child("publish-options", namespace: PubSub.namespace).map(
                Self.fields(in:)) ?? [:]
        let refused = state.withLock { state -> Bool in
            guard !options.isEmpty, state.refuseOnce.remove(node) != nil else { return false }
            return true
        }
        if refused {
            return iq.errorResponse(StanzaError(type: .cancel, condition: .conflict))
        }
        state.withLock {
            $0.published.append(
                Published(
                    account: account, node: node, itemID: item[attribute: "id"], options: options))
            Self.store(&$0, content, id: item[attribute: "id"], node: node, account: account)
        }
        return iq.iqResult()
    }

    /// The single values of a data form's fields, without the form type.
    static func fields(in parent: Element) -> [String: String] {
        guard let form = parent.child("x", namespace: "jabber:x:data") else { return [:] }
        var fields: [String: String] = [:]
        for field in form.children("field", namespace: "jabber:x:data") {
            guard let name = field[attribute: "var"], name != "FORM_TYPE" else { continue }
            fields[name] = field.child("value", namespace: "jabber:x:data")?.text
        }
        return fields
    }
}

/// One account's connection in OMEMO tests: requests are answered by the `FakePEP`, stanzas
/// are recorded.
final class OMEMOTestSender: StanzaSending {
    let account: JID
    let pep: FakePEP
    private let state = Mutex<(sent: [Element], timeouts: [Duration], offline: Bool)>(
        ([], [], false))

    init(account: JID, pep: FakePEP) {
        self.account = account
        self.pep = pep
    }

    var sent: [Element] { state.withLock { $0.sent } }
    var timeouts: [Duration] { state.withLock { $0.timeouts } }

    /// The messages sent, in order.
    var messages: [Element] { sent.filter { $0.name == "message" } }

    func setOffline(_ offline: Bool) {
        state.withLock { $0.offline = offline }
    }

    private let held = Mutex(false)
    private let maxBytes = Mutex<Int?>(nil)

    /// Stanzas longer than this are refused as `.tooLarge`, as by a connection whose server
    /// takes no more (R81).
    func setMaxBytes(_ limit: Int?) {
        maxBytes.withLock { $0 = limit }
    }

    /// While held, requests wait without an answer, as on a slow server.
    func hold(_ hold: Bool) {
        held.withLock { $0 = hold }
    }

    func send(_ stanza: Element) async throws(SendError) {
        if let limit = maxBytes.withLock({ $0 }), stanza.xml().utf8.count > limit {
            throw .tooLarge
        }
        try state.withLock { state throws(SendError) in
            if state.offline { throw .notConnected }
            state.sent.append(stanza)
        }
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        while held.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        var iq = iq
        if iq.id == nil { iq[attribute: "id"] = .stanzaID() }
        let request = iq
        state.withLock {
            $0.sent.append(request)
            $0.timeouts.append(timeout)
        }
        guard let answer = pep.answer(request, from: account) else {
            throw .error(StanzaError(type: .cancel, condition: .serviceUnavailable))
        }
        if answer.type == "error" {
            throw .error(
                answer.child("error").flatMap(StanzaError.init(element:))
                    ?? StanzaError(type: .cancel, condition: .undefinedCondition))
        }
        return answer
    }

    var boundJID: JID? {
        get async { try? account.withResource("test") }
    }
}

/// An OMEMO party for tests: a manager on its own database, talking to a shared `FakePEP`.
struct OMEMOParty {
    static let features: Set<String> = [PubSub.publishOptionsFeature]

    let jid: JID
    let database: AppDatabase
    let accountID: Int64
    let sender: OMEMOTestSender
    let manager: OMEMOManager

    init(_ jid: String, pep: FakePEP, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let jid = try JID(jid)
        self.jid = jid
        database = try AppDatabase.inMemory()
        let account = try database.addAccount(
            AccountRecord(
                jid: jid.description, enabled: true, resource: "test",
                clientID: UUID().uuidString, hostOverride: nil, portOverride: nil,
                directTLSOverride: nil, pinnedCertSHA256: [], rosterVersion: nil, smResume: nil,
                createdAt: Date()))
        accountID = try #require(account.id)
        sender = OMEMOTestSender(account: jid, pep: pep)
        manager = OMEMOManager(
            account: jid, store: OMEMOStoreAdapter(database: database, accountID: accountID),
            sender: sender, now: now)
    }

    /// Starts a session and waits until the own devices are published.
    func start(features: Set<String> = Self.features) async {
        await manager.sessionStarted(accountFeatures: features)
        await manager.settled()
    }

    func deviceID(_ version: OMEMO.OMEMOVersion) async throws -> UInt32 {
        try await manager.engine.ensureOwnDevice(version: version)
    }

    /// Sends a text and returns the stanza that went out.
    func send(
        _ body: String, to chat: OMEMOChat, id: String = .stanzaID(),
        occupants: @escaping @Sendable () async -> [JID] = { [] }
    ) async throws -> Element {
        let to: JID
        switch chat {
        case .direct(let jid): to = jid
        case .room(let room, _): to = room.jid
        }
        let isRoom = if case .room = chat { true } else { false }
        let plain = ChatMessage.text(body, to: to, type: isRoom ? .groupchat : .chat, id: id)
        let before = sender.messages.count
        _ = try await manager.send(plain, to: chat, occupants: occupants)
        return try #require(sender.messages.dropFirst(before).last)
    }

    /// Decrypts a stanza another party sent, as `from` sent it.
    func open(_ stanza: Element, from: JID, recipient: MessageRecipient? = nil) async throws
        -> DecryptedPayload
    {
        let encrypted = try #require(ChatMessage(element: stanza)?.encrypted)
        return try #require(
            await manager.decrypt(encrypted, from: from, recipient: recipient, known: true))
    }
}

extension DecryptedPayload {
    var body: String? {
        if case .message(let message) = content { return message.body }
        return nil
    }
}
