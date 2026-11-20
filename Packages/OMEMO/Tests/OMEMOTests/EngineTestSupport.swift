import Foundation
import Synchronization
import Testing
import XMPPCore

@testable import OMEMO

// MARK: - Clock

/// A clock the tests move by hand.
final class TestClock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { time.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        time.withLock { $0 += seconds }
    }
}

// MARK: - Store

/// `OMEMOStoreProtocol` in memory, one account.
actor MemoryStore: OMEMOStoreProtocol {
    private var identities: [OMEMOVersion: OwnIdentity] = [:]
    private var signed: [OMEMOVersion: [UInt32: SignedPreKey]] = [:]
    private var pre: [OMEMOVersion: [UInt32: OneTimePreKey]] = [:]
    private var deviceRecords: [OMEMOVersion: [JID: [UInt32: OMEMODevice]]] = [:]
    private var sessionStates: [OMEMOVersion: [DeviceAddress: Data]] = [:]

    func ownIdentity(version: OMEMOVersion) -> OwnIdentity? { identities[version] }

    func saveOwnIdentity(_ identity: OwnIdentity, version: OMEMOVersion) {
        identities[version] = identity
    }

    func signedPreKeys(version: OMEMOVersion) -> [SignedPreKey] {
        (signed[version] ?? [:]).values.sorted { $0.id < $1.id }
    }

    func saveSignedPreKey(_ key: SignedPreKey, version: OMEMOVersion) {
        signed[version, default: [:]][key.id] = key
    }

    func deleteSignedPreKey(id: UInt32, version: OMEMOVersion) {
        signed[version]?[id] = nil
    }

    func preKeys(version: OMEMOVersion) -> [OneTimePreKey] {
        (pre[version] ?? [:]).values.sorted { $0.id < $1.id }
    }

    func preKey(id: UInt32, version: OMEMOVersion) -> OneTimePreKey? { pre[version]?[id] }

    func savePreKeys(_ keys: [OneTimePreKey], version: OMEMOVersion) {
        for key in keys {
            pre[version, default: [:]][key.id] = key
        }
    }

    func devices(of jid: JID, version: OMEMOVersion) -> [OMEMODevice] {
        (deviceRecords[version]?[jid] ?? [:]).values.sorted { $0.deviceID < $1.deviceID }
    }

    func saveDevice(_ device: OMEMODevice, version: OMEMOVersion) {
        deviceRecords[version, default: [:]][device.jid, default: [:]][device.deviceID] = device
    }

    func session(with device: DeviceAddress, version: OMEMOVersion) -> Data? {
        sessionStates[version]?[device]
    }

    func saveSession(_ state: Data, with device: DeviceAddress, version: OMEMOVersion) {
        sessionStates[version, default: [:]][device] = state
    }

    func saveSession(
        _ state: Data, with device: DeviceAddress, consumingPreKey preKeyID: UInt32,
        version: OMEMOVersion
    ) {
        sessionStates[version, default: [:]][device] = state
        pre[version]?[preKeyID] = nil
    }

    func deleteSession(with device: DeviceAddress, version: OMEMOVersion) {
        sessionStates[version]?[device] = nil
    }

    // Test helpers

    /// Everything stored, as text: equal snapshots mean byte-identical state.
    func snapshot() -> String {
        var lines: [String] = []
        for version in OMEMOVersion.allCases {
            if let identity = identities[version] {
                lines.append(
                    "identity \(version) \(identity.deviceID) "
                        + "\(identity.identityKeyPair.privateKey.hex) \(identity.signedPreKeyID) "
                        + "\(identity.nextPreKeyID)")
            }
            for key in signedPreKeys(version: version) {
                lines.append(
                    "signed \(version) \(key.id) \(key.keyPair.privateKey.hex) "
                        + "\(key.signature.hex) \(key.createdAt.timeIntervalSince1970)")
            }
            for key in preKeys(version: version) {
                lines.append("pre \(version) \(key.id) \(key.keyPair.privateKey.hex)")
            }
            let jids = (deviceRecords[version] ?? [:]).keys.sorted {
                $0.description < $1.description
            }
            for jid in jids {
                for device in devices(of: jid, version: version) {
                    lines.append(
                        "device \(version) \(device.address) \(device.label ?? "-") "
                            + "\(device.active) \(device.lastSeen?.timeIntervalSince1970 ?? -1) "
                            + "\(device.identityKey?.hex ?? "-") \(device.trust)")
                }
            }
            let sessions = (sessionStates[version] ?? [:]).sorted {
                $0.key.description < $1.key.description
            }
            for (address, state) in sessions {
                lines.append("session \(version) \(address) \(state.hex)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func preKeyIDs(version: OMEMOVersion) -> [UInt32] { preKeys(version: version).map(\.id) }

    func signedPreKeyIDs(version: OMEMOVersion) -> [UInt32] {
        signedPreKeys(version: version).map(\.id)
    }

    func storedSession(with device: DeviceAddress, version: OMEMOVersion) throws -> StoredSession? {
        try sessionStates[version]?[device].map { try StoredSession(encoded: $0) }
    }

    func deviceJIDs(version: OMEMOVersion) -> [JID] {
        (deviceRecords[version] ?? [:]).keys.sorted { $0.description < $1.description }
    }

    func device(_ address: DeviceAddress, version: OMEMOVersion) -> OMEMODevice? {
        deviceRecords[version]?[address.jid]?[address.deviceID]
    }
}

// MARK: - PEP

/// Every account's device lists and bundles, as their PEP services would hold them.
actor FakePEP {
    private struct ListKey: Hashable {
        let jid: JID
        let version: OMEMOVersion
    }

    private struct BundleKey: Hashable {
        let jid: JID
        let deviceID: UInt32
        let version: OMEMOVersion
    }

    private var lists: [ListKey: Element] = [:]
    private var bundles: [BundleKey: Element] = [:]
    private(set) var bundleFetches = 0

    func list(of jid: JID, version: OMEMOVersion) -> Element? {
        lists[ListKey(jid: jid.bare, version: version)]
    }

    func setList(_ list: Element, of jid: JID, version: OMEMOVersion) {
        lists[ListKey(jid: jid.bare, version: version)] = list
    }

    func bundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) -> Element? {
        bundleFetches += 1
        return bundles[BundleKey(jid: jid.bare, deviceID: deviceID, version: version)]
    }

    func setBundle(_ bundle: Element, of jid: JID, deviceID: UInt32, version: OMEMOVersion) {
        bundles[BundleKey(jid: jid.bare, deviceID: deviceID, version: version)] = bundle
    }

    /// Takes pre key `id` out of the device's published bundle, as the device's next publish
    /// does once it has read the key exchange that used it. False when the bundle did not
    /// have it.
    func withdraw(preKey id: UInt32, of jid: JID, deviceID: UInt32, version: OMEMOVersion)
        -> Bool
    {
        let key = BundleKey(jid: jid.bare, deviceID: deviceID, version: version)
        guard var bundle = bundles[key] else { return false }
        let before = bundle.xml()
        bundle.children = bundle.children.map { node in
            guard case .element(var preKeys) = node, preKeys.name == "prekeys" else { return node }
            preKeys.children = preKeys.children.filter { child in
                guard case .element(let preKey) = child else { return true }
                return (preKey[attribute: "preKeyId"] ?? preKey[attribute: "id"]) != String(id)
            }
            return .element(preKeys)
        }
        bundles[key] = bundle
        return bundle.xml() != before
    }
}

/// Takes out of `receiver`'s published bundle the pre key that `sender`'s current session
/// with it was built from (Task 17c). Two sessions built from one bundle that nobody
/// published again in between pick the same pre key 1 time in `OMEMOEngine.preKeyCount`, and
/// the key exchange read second then finds it gone: a test that builds a second session from
/// the bundle, or lets another device build one, takes the first one's pre key out between
/// the two, as the receiver's own publish would.
func withdrawUsedPreKey(
    of sender: TestDevice, toward receiver: TestDevice, version: OMEMOVersion, on pep: FakePEP
) async throws {
    let state = try #require(await sender.store.session(with: receiver.address, version: version))
    let used = try #require(try StoredSession(encoded: state).pendingKeyExchange?.preKeyID)
    #expect(
        await pep.withdraw(
            preKey: used, of: receiver.jid, deviceID: receiver.id, version: version))
}

/// A transport whose bundle fetches for some devices never answer (until cancelled), and that
/// records how many fetches ran at once.
actor SlowTransport: OMEMOTransport {
    let pep: FakePEP
    let hanging: Set<UInt32>
    let delay: Duration
    private(set) var running = 0
    private(set) var mostAtOnce = 0

    init(pep: FakePEP, hanging: Set<UInt32> = [], delay: Duration = .zero) {
        self.pep = pep
        self.hanging = hanging
        self.delay = delay
    }

    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element? {
        await pep.list(of: jid, version: version)
    }

    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
    {
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        if hanging.contains(deviceID) {
            try await Task.sleep(for: .seconds(30))
        } else if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return await pep.bundle(of: jid, deviceID: deviceID, version: version)
    }
}

/// A transport that fails the fetches it is told to fail.
actor FailingTransport: OMEMOTransport {
    struct Failure: Error {}

    let pep: FakePEP
    var failingLists: Set<JID> = []
    var failingBundles: Set<UInt32> = []

    init(pep: FakePEP) {
        self.pep = pep
    }

    func fail(listOf jid: JID) { failingLists.insert(jid.bare) }
    func fail(bundleOf deviceID: UInt32) { failingBundles.insert(deviceID) }

    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element? {
        if failingLists.contains(jid.bare) { throw Failure() }
        return await pep.list(of: jid, version: version)
    }

    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
    {
        if failingBundles.contains(deviceID) { throw Failure() }
        return await pep.bundle(of: jid, deviceID: deviceID, version: version)
    }
}

/// An element from XML text, read by XMPPCore's stream parser as a stanza of a client stream.
func element(_ xml: String) throws -> Element {
    var parser = XMLStreamParser()
    var events = parser.feed(
        Array(
            "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"
                .utf8))
    events += parser.feed(Array(xml.utf8))
    guard events.count == 2, case .stanza(let element) = events[1] else {
        throw TestInputError.missingValue("one element in \(xml.prefix(80))")
    }
    return element
}

/// A copy of an `<encrypted/>` element with one bit of its payload flipped.
func flippingPayload(_ encrypted: Element, version: OMEMOVersion) throws -> Element {
    var copy = encrypted
    let ns = version.rawValue
    copy.children = try encrypted.children.map { node in
        guard case .element(var child) = node, child.name == "payload", child.namespace == ns
        else { return node }
        let payload = try #require(Data(base64Encoded: child.text))
        child.children = [.text(flipping(bit: 3, of: payload).base64EncodedString())]
        return .element(child)
    }
    return copy
}

/// A copy of an `<encrypted/>` element whose key for `deviceID` has its last byte changed: the
/// legacy MAC, or the end of the OMEMO 2 message the MAC covers.
func flippingKey(_ encrypted: Element, for deviceID: UInt32, version: OMEMOVersion) throws
    -> Element
{
    func flip(_ element: Element) throws -> Element {
        guard element.name == "key", element[attribute: "rid"] == String(deviceID) else {
            var copy = element
            copy.children = try element.children.map { node in
                guard case .element(let child) = node else { return node }
                return .element(try flip(child))
            }
            return copy
        }
        let key = try #require(Data(base64Encoded: element.text))
        var copy = element
        copy.children = [.text(flipping(bit: key.count * 8 - 1, of: key).base64EncodedString())]
        return copy
    }
    return try flip(encrypted)
}

struct PEPTransport: OMEMOTransport {
    let pep: FakePEP

    func fetchDeviceList(of jid: JID, version: OMEMOVersion) async throws -> Element? {
        await pep.list(of: jid, version: version)
    }

    func fetchBundle(of jid: JID, deviceID: UInt32, version: OMEMOVersion) async throws -> Element?
    {
        await pep.bundle(of: jid, deviceID: deviceID, version: version)
    }
}

// MARK: - Accounts and devices

/// One device of one account: its engine, its store, its id.
struct TestDevice: Sendable {
    let jid: JID
    let engine: OMEMOEngine
    let store: MemoryStore
    let id: UInt32

    var address: DeviceAddress { DeviceAddress(jid: jid, deviceID: id) }
}

/// Several in-process devices that publish to one fake PEP and pass stanzas by hand.
struct TestNetwork: Sendable {
    let version: OMEMOVersion
    let pep = FakePEP()
    let clock = TestClock()

    /// A new device for `jid`: own device set up, bundle published, id added to the list.
    func device(_ jid: String) async throws -> TestDevice {
        let jid = try JID(jid)
        let store = MemoryStore()
        let clock = self.clock
        let engine = OMEMOEngine(
            store: store, transport: PEPTransport(pep: pep), accountJID: jid,
            now: { clock.now })
        let id = try await engine.ensureOwnDevice(version: version)
        try await publishBundle(of: TestDevice(jid: jid, engine: engine, store: store, id: id))
        let listed = await listedIDs(of: jid)
        await pep.setList(
            engine.deviceListElement(version: version, devices: listed + [id]), of: jid,
            version: version)
        return TestDevice(jid: jid, engine: engine, store: store, id: id)
    }

    func publishBundle(of device: TestDevice) async throws {
        let bundle = try await device.engine.ownBundle(version: version)
        await pep.setBundle(bundle, of: device.jid, deviceID: device.id, version: version)
    }

    func listedIDs(of jid: JID) async -> [UInt32] {
        guard let list = await pep.list(of: jid, version: version) else { return [] }
        return list.elements.compactMap { $0[attribute: "id"].flatMap { UInt32($0) } }
    }

    /// Drops `device` from its account's published list.
    func unlist(_ device: TestDevice) async {
        let remaining = await listedIDs(of: device.jid).filter { $0 != device.id }
        await pep.setList(
            DeviceList.element(version: version, devices: remaining), of: device.jid,
            version: version)
    }

    /// `observer` reads the current device list of `jid`, as a PEP notification delivers it.
    @discardableResult
    func notify(_ observer: TestDevice, about jid: JID) async throws -> DeviceListUpdate {
        let list = try #require(await pep.list(of: jid, version: version))
        return try await observer.engine.processDeviceList(list, from: jid, version: version)
    }

    /// Every device reads every account's list.
    func syncLists(_ devices: [TestDevice]) async throws {
        let jids = Set(devices.map(\.jid))
        for device in devices {
            for jid in jids {
                try await notify(device, about: jid)
            }
        }
    }

    func send(
        _ body: String, from sender: TestDevice, to recipients: [JID], room: OMEMORoom? = nil
    ) async throws -> Element {
        try await sender.engine.encrypt(
            MessageContent(body: body), to: recipients, version: version, room: room)
    }

    /// `receiver` decrypts; a bundle it has to republish is published.
    func deliver(
        _ encrypted: Element, from sender: TestDevice, to receiver: TestDevice,
        recipient: MessageRecipient? = nil
    ) async throws -> DecryptedPayload {
        var result = try await receiver.engine.decrypt(
            encrypted, from: sender.jid, version: version, recipient: recipient)
        // What the session's manager does: the repair the engine asks for, run on its own.
        if result.repairWanted, let device = result.sender,
            let repair = try await receiver.engine.repairSession(with: device, version: version)
        {
            result.replies.append(repair)
        }
        if let bundle = result.bundleToPublish {
            await pep.setBundle(bundle, of: receiver.jid, deviceID: receiver.id, version: version)
        }
        return result
    }

    /// Delivers an empty OMEMO message the engine asked to send.
    func deliver(
        _ reply: KeyTransportMessage, from sender: TestDevice, to receiver: TestDevice
    ) async throws -> DecryptedPayload {
        #expect(reply.stanza.name == "message")
        #expect(reply.stanza[attribute: "to"] == receiver.jid.description)
        let encrypted = try #require(reply.stanza.child("encrypted", namespace: version.rawValue))
        return try await deliver(encrypted, from: sender, to: receiver)
    }
}

// MARK: - Reading what was sent, independently of the engine

/// The `<key>` elements of an `<encrypted>` element by the device id they are for, with the
/// JID of the `<keys>` group they are in (OMEMO 2) or nil (legacy).
func keyRecipients(_ encrypted: Element, version: OMEMOVersion) -> [String?: Set<UInt32>] {
    var result: [String?: Set<UInt32>] = [:]
    guard let header = encrypted.child("header", namespace: version.rawValue) else {
        return result
    }
    switch version {
    case .v03:
        for key in header.children("key", namespace: version.rawValue) {
            if let id = key[attribute: "rid"].flatMap({ UInt32($0) }) {
                result[nil, default: []].insert(id)
            }
        }
    case .v2:
        for keys in header.children("keys", namespace: version.rawValue) {
            for key in keys.children("key", namespace: version.rawValue) {
                if let id = key[attribute: "rid"].flatMap({ UInt32($0) }) {
                    result[keys[attribute: "jid"], default: []].insert(id)
                }
            }
        }
    }
    return result
}

/// Every device id that got a key, whatever its group.
func keyedDevices(_ encrypted: Element, version: OMEMOVersion) -> Set<UInt32> {
    keyRecipients(encrypted, version: version).values.reduce(into: Set()) { $0.formUnion($1) }
}

/// Whether the key for `deviceID` is marked as a key exchange.
func isKeyExchange(_ encrypted: Element, for deviceID: UInt32, version: OMEMOVersion) -> Bool? {
    guard let header = encrypted.child("header", namespace: version.rawValue) else { return nil }
    let keys: [Element]
    switch version {
    case .v03: keys = header.children("key", namespace: version.rawValue)
    case .v2:
        keys = header.children("keys", namespace: version.rawValue).flatMap {
            $0.children("key", namespace: version.rawValue)
        }
    }
    guard let key = keys.first(where: { $0[attribute: "rid"] == String(deviceID) }) else {
        return nil
    }
    let flag = key[attribute: version == .v03 ? "prekey" : "kex"]
    return flag == "true" || flag == "1"
}

extension DecryptedPayload {
    /// The body of a decrypted message; nil for anything else.
    var body: String? {
        if case .message(let message) = content { return message.body }
        return nil
    }
}
