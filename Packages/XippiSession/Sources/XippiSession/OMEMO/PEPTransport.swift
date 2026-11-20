import OMEMO
import XMPPCore

/// Reads OMEMO device lists and bundles over PEP for the engine. Every request ends within
/// `timeout` (the engine's `bundleFetchTimeout`), with an answer or an error, and nothing here
/// calls back into the engine: the engine waits for these calls while it holds its queue.
struct PEPTransport: OMEMOTransport {
    let sender: BoundedSender

    init(sender: any StanzaSending, timeout: Duration) {
        self.sender = BoundedSender(base: sender, limit: timeout)
    }

    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element? {
        let items = try await PubSub.items(
            node: DeviceList.node(version: version), from: jid.bare, via: sender)
        // XEP-0384 names the item `current`; clients that published under another id still
        // have one list, the newest.
        return (items.first { $0.id == DeviceList.itemID } ?? items.last)?.payload
    }

    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
    {
        let node = OMEMOBundle.node(version: version, deviceID: deviceID)
        switch version {
        case .v03:
            // One bundle per node; older clients publish it under ids other than `current`.
            let items = try await PubSub.items(node: node, from: jid.bare, max: 1, via: sender)
            return items.last?.payload
        case .v2:
            let id = OMEMOBundle.itemID(version: version, deviceID: deviceID)
            let items = try await PubSub.items(node: node, from: jid.bare, ids: [id], via: sender)
            return items.first { $0.id == id }?.payload
        }
    }
}

/// A `StanzaSending` whose requests time out after `limit` at the latest, whatever the caller
/// asks for.
struct BoundedSender: StanzaSending {
    let base: any StanzaSending
    let limit: Duration

    func send(_ stanza: Element) async throws(SendError) {
        try await base.send(stanza)
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        try await base.request(iq, timeout: min(timeout, limit))
    }

    var boundJID: JID? {
        get async { await base.boundJID }
    }
}
