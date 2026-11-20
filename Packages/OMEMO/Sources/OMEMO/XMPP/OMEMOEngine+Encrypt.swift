import Foundation
import XMPPCore
import os

extension OMEMOEngine {
    /// The `<encrypted/>` element of a message, to send with a store hint (and, for legacy
    /// clients, a fallback body).
    ///
    /// - Legacy OMEMO encrypts the body. OMEMO 2 encrypts an XEP-0420 envelope with the body and
    ///   `content.elements`, random padding, the time, the recipient (the room in a room
    ///   message) and this account as sender.
    /// - Keys go to every listed device of every recipient that `TrustPolicy` lets have them,
    ///   and to the account's own other listed devices allowed the same way, so they can read
    ///   what this device sent. Sessions are started from bundles as needed, fetched side by
    ///   side; a device whose bundle cannot be had is left out, and asked again only after a
    ///   back-off. Stale devices are left out while the same account has a device that is not
    ///   stale and can be reached; when every reachable device is stale, all of them get keys.
    /// - One message reads at most `newDevicesPerMessage` bundles per recipient (new sessions,
    ///   and keys waiting for the user's decision), devices heard from most recently first; the
    ///   rest are read with later messages.
    /// - Device lists and bundles are fetched outside the engine's queue, so decryption goes
    ///   on meanwhile; the sessions are then made and the message sealed from the state as it
    ///   is once they are in (final review I-3).
    /// - Nothing is stored unless the element is made: a refusal leaves every session as it was.
    /// - A room message goes to the members' real JIDs (`recipients`), and only in a room that
    ///   is non-anonymous and members-only. Without a room there must be exactly one recipient.
    ///
    /// - Throws: `OMEMOError`: `.noDevices`, `.noTrustedDevices` or `.sessionsUnavailable` for
    ///   a recipient that gets no key at all, `.roomNotSuitable`, `.invalidRecipients`,
    ///   `.nothingToEncrypt`, `.legacyEncryptsBodyOnly`, `.noOwnDevice`; and the transport's
    ///   error when a recipient's device list cannot be fetched.
    public func encrypt(
        _ content: MessageContent, to recipients: [JID], version: OMEMOVersion,
        room: OMEMORoom? = nil
    ) async throws -> Element {
        let jids = recipients.map(\.bare).uniquedInOrder()
        if let room {
            guard room.isNonAnonymous, room.isMembersOnly else { throw OMEMOError.roomNotSuitable }
            guard !jids.isEmpty else { throw OMEMOError.invalidRecipients }
        } else {
            guard jids.count == 1 else { throw OMEMOError.invalidRecipients }
        }
        let plaintext: Data
        switch version {
        case .v03:
            guard content.elements.isEmpty else { throw OMEMOError.legacyEncryptsBodyOnly }
            guard let body = content.body else { throw OMEMOError.nothingToEncrypt }
            plaintext = Data(body.utf8)
        case .v2:
            guard content.body != nil || !content.elements.isEmpty else {
                throw OMEMOError.nothingToEncrypt
            }
            let envelope = Self.envelope(
                for: content, to: room?.jid ?? jids[0], from: accountJID, time: now())
            plaintext = Data(envelope.xml().utf8)
        }
        return try await seal(plaintext, to: jids, version: version)
    }

    /// The OMEMO 2 envelope of a message.
    static func envelope(for content: MessageContent, to: JID, from: JID, time: Date) -> Element {
        var elements: [Element] = []
        if let body = content.body {
            elements.append(Element("body", namespace: "jabber:client", children: [.text(body)]))
        }
        // XEP-0420: elements a server acts on never go inside <content/>.
        elements += content.elements.filter {
            !SCE.serverProcessedNamespaces.contains($0.namespace ?? "")
        }
        let unpadded = SCE.Envelope(content: elements, padding: nil, time: nil, to: nil, from: nil)
        return SCE.Envelope(
            content: elements,
            padding: SCE.randomPadding(contentLength: unpadded.element.xml().utf8.count),
            time: time, to: to.bare, from: from.bare
        ).element
    }

    /// Encrypts `plaintext` as the payload, as it is: the envelope (OMEMO 2) is the caller's.
    func encryptPayload(
        _ plaintext: Data, to recipients: [JID], version: OMEMOVersion
    ) async throws -> Element {
        try await seal(plaintext, to: recipients.map(\.bare).uniquedInOrder(), version: version)
    }

    /// A message in three steps, each job in the engine's queue short: the device lists not
    /// known yet, fetched outside the queue; the bundles the message needs, settled in the
    /// queue and fetched outside it; then, in the queue again, the keys the bundles show, the
    /// new sessions, and the sealed message.
    private func seal(_ plaintext: Data, to recipients: [JID], version: OMEMOVersion)
        async throws -> Element
    {
        let everyone = (recipients + [accountJID]).uniquedInOrder()
        let unlisted: [JID] = try await exclusively {
            guard try await store.ownIdentity(version: version) != nil else {
                throw OMEMOError.noOwnDevice
            }
            return try await listsToRead(everyone, version: version)
        }
        let lists = await fetchLists(unlisted, version: version)
        let wanted: [DeviceAddress] = try await exclusively {
            guard let own = try await store.ownIdentity(version: version) else {
                throw OMEMOError.noOwnDevice
            }
            for jid in unlisted {
                switch lists[jid] {
                case .success(let element):
                    let ids = element.flatMap { DeviceList.deviceIDs(in: $0, version: version) }
                    _ = try await applyDeviceList(
                        ids ?? [], of: jid, version: version,
                        ownDeviceID: jid == accountJID ? own.deviceID : nil)
                case .failure(let error):
                    // A recipient's list is needed; the account's own only for a message to
                    // itself alone.
                    if jid != accountJID || recipients == [accountJID] { throw error }
                    Self.log.error("Own OMEMO device list fetch failed")
                case nil:
                    break
                }
            }
            return try await bundlesToRead(for: everyone, own: own, version: version)
        }
        let fetched = await fetchBundles(wanted, version: version)
        defer { used(fetched) }
        return try await exclusively {
            try await sealPayload(
                plaintext, to: recipients, version: version, read: wanted,
                bundles: fetched.bundles)
        }
    }

    /// The JIDs of `jids` with no listed device known whose list was not read since the engine
    /// started: a contact without OMEMO is not asked again on every message.
    private func listsToRead(_ jids: [JID], version: OMEMOVersion) async throws -> [JID] {
        var unread: [JID] = []
        for jid in jids
        where !fetchedLists.contains(ListKey(jid: jid, version: version)) {
            let devices = try await store.devices(of: jid, version: version)
            if !devices.contains(where: \.active) { unread.append(jid) }
        }
        return unread
    }

    /// The device lists of `jids`, fetched side by side, each read or failed.
    private func fetchLists(_ jids: [JID], version: OMEMOVersion) async
        -> [JID: Result<Element?, any Error>]
    {
        let transport = self.transport
        var lists: [JID: Result<Element?, any Error>] = [:]
        await withTaskGroup(of: (JID, Result<Element?, any Error>).self) { group in
            var next = 0
            func add() {
                let jid = jids[next]
                next += 1
                group.addTask {
                    do {
                        let list = try await transport.fetchDeviceList(of: jid, version: version)
                        return (jid, .success(list))
                    } catch {
                        return (jid, .failure(error))
                    }
                }
            }
            while next < min(jids.count, Self.maxConcurrentBundleFetches) { add() }
            while let (jid, list) = await group.next() {
                lists[jid] = list
                if next < jids.count { add() }
            }
        }
        return lists
    }

    /// The bundles a message to `jids` reads, at most `newDevicesPerMessage` per JID, devices
    /// heard from most recently first: listed devices that get keys without a session to seal
    /// to, and listed devices waiting for the user's decision whose key no bundle has shown
    /// yet (R60: the user sees which key they decide on). Never this device, and never one in
    /// the bundle back-off.
    private func bundlesToRead(for jids: [JID], own: OwnIdentity, version: OMEMOVersion)
        async throws -> [DeviceAddress]
    {
        var wanted: [DeviceAddress] = []
        for jid in jids {
            var picked: [OMEMODevice] = []
            for device in try await store.devices(of: jid, version: version)
            where device.active && !(jid == accountJID && device.deviceID == own.deviceID)
                && mayFetchBundle(device.address, version: version)
            {
                if device.identityKey == nil {
                    // Its key to learn (R60), or a first session to start.
                    if device.trust == .undecided || TrustPolicy.receivesKeys(device) {
                        picked.append(device)
                    }
                } else if TrustPolicy.receivesKeys(device) {
                    let session = try await loadSession(device.address, version: version)
                    if !Self.canSeal(on: session, to: device) { picked.append(device) }
                }
            }
            picked.sort { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            wanted += picked.prefix(Self.newDevicesPerMessage).map(\.address)
        }
        return wanted
    }

    /// Whether a message can be sealed to `device` on `session`: one that encrypts, under the
    /// key the device's record has. A session under another key is never sealed to: the
    /// device gets a new one from its bundle (Task 17c N7).
    private static func canSeal(on session: StoredSession?, to device: OMEMODevice) -> Bool {
        guard let session else { return false }
        return session.ratchet.canEncrypt && session.remoteIdentityKey == device.identityKey
    }

    /// Reads the bundles of `jid`'s listed devices in `version` whose identity key no bundle
    /// has shown yet, within the bundle back-off, and records the keys (Task 24, R60): at most
    /// `newDevicesPerMessage` a call, the rest on the next. Returns how many keys were learnt.
    /// The bundles are fetched outside the engine's queue, as a repair's are: decryption and
    /// encryption go on meanwhile.
    public func refreshIdentities(of jid: JID, version: OMEMOVersion) async throws -> Int {
        let unknown: [OMEMODevice] = try await exclusively {
            let own = try await store.ownIdentity(version: version)
            return Array(
                try await store.devices(of: jid.bare, version: version).filter { device in
                    device.active && device.identityKey == nil && device.trust != .distrusted
                        && !(jid.bare == accountJID && device.deviceID == own?.deviceID)
                        && mayFetchBundle(device.address, version: version)
                }
                .prefix(Self.newDevicesPerMessage))
        }
        guard !unknown.isEmpty else { return 0 }
        let bundles = await fetchBundles(unknown.map(\.address), version: version)
        defer { used(bundles) }
        return try await exclusively {
            var learnt = 0
            for device in unknown {
                guard let element = bundles[device.address],
                    let bundle = OMEMOBundle.parse(element, version: version),
                    bundle.hasValidSignature(version: version)
                else {
                    recordBundleFailure(device.address, version: version)
                    continue
                }
                // Read again: a message may have shown the key meanwhile.
                guard
                    let current = try await store.devices(of: device.jid, version: version)
                        .first(where: { $0.deviceID == device.deviceID }),
                    current.identityKey == nil
                else { continue }
                _ = try await recordIdentity(bundle.identityKey, of: current, version: version)
                learnt += 1
            }
            return learnt
        }
    }

    /// The devices of one recipient that get keys.
    private struct Recipient {
        let jid: JID
        /// No key for this recipient is an error (every recipient but the account's own list).
        let required: Bool
        var devices: [OMEMODevice]
    }

    /// The message sealed in the engine's queue, from the state as it is now. `read` are the
    /// bundles asked for (`bundlesToRead`), `bundles` those that came. Nothing is fetched.
    private func sealPayload(
        _ plaintext: Data, to recipients: [JID], version: OMEMOVersion, read: [DeviceAddress],
        bundles: [DeviceAddress: Element]
    ) async throws -> Element {
        guard let own = try await store.ownIdentity(version: version) else {
            throw OMEMOError.noOwnDevice
        }
        try await learnIdentities(from: read, bundles: bundles, version: version)
        // Who gets keys, settled for every recipient before anything changes.
        var groups: [Recipient] = []
        for jid in recipients where jid != accountJID {
            groups.append(
                Recipient(
                    jid: jid, required: true,
                    devices: try await trustedDevices(
                        of: jid, own: own, version: version, required: true)))
        }
        let ownRequired = recipients == [accountJID]
        groups.append(
            Recipient(
                jid: accountJID, required: ownRequired,
                devices: try await trustedDevices(
                    of: accountJID, own: own, version: version, required: ownRequired)))

        // Sessions: the stored ones, the rest from the bundles read for this message. A device
        // whose bundle was not read this time gets its session with a later message.
        let asked = Set(read)
        var stored: [DeviceAddress: StoredSession] = [:]
        for group in groups {
            for device in group.devices {
                stored[device.address] = try await loadSession(device.address, version: version)
            }
        }
        var sessions: [DeviceAddress: StoredSession] = [:]
        for device in groups.flatMap(\.devices) {
            if Self.canSeal(on: stored[device.address], to: device) {
                sessions[device.address] = stored[device.address]
                continue
            }
            guard asked.contains(device.address) else { continue }
            guard
                let built = try await newSession(
                    with: device, bundle: bundles[device.address], own: own, version: version)
            else {
                recordBundleFailure(device.address, version: version)
                continue
            }
            bundleFailures[RepairKey(device: device.address, version: version)] = nil
            guard TrustPolicy.receivesKeys(built.device) else { continue }
            sessions[device.address] =
                stored[device.address]?.replacing(with: built.state)
                ?? StoredSession(built.state, createdAt: now())
        }

        // Stale devices are left out only while the recipient has a device that is not stale
        // and can be reached now. Devices without a session (no bundle, or in back-off) count
        // for nothing, and a recipient whose reachable devices are all stale gets them all.
        for index in groups.indices {
            let reachable = groups[index].devices.filter { sessions[$0.address] != nil }
            let current = reachable.filter { !isStale($0, session: sessions[$0.address]) }
            groups[index].devices = current.isEmpty ? reachable : current
        }

        // Seal, then store the sessions once the whole element is made.
        let payload = try PayloadCipher.encrypt(plaintext, version: version)
        var keys: [EncryptedElement.Key] = []
        var sealedSessions: [(DeviceAddress, StoredSession)] = []
        for group in groups {
            var sealedAny = false
            for device in group.devices {
                guard var session = sessions[device.address] else { continue }
                let sealed: (data: Data, isKeyExchange: Bool)
                do {
                    sealed = try seal(
                        payload.keyMaterial, session: &session, own: own, version: version)
                } catch {
                    Self.log.error(
                        "OMEMO session cannot encrypt: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                session.sentSinceReceived += 1
                sealedSessions.append((device.address, session))
                keys.append(
                    EncryptedElement.Key(
                        jid: group.jid, deviceID: device.deviceID,
                        isKeyExchange: sealed.isKeyExchange, data: sealed.data))
                sealedAny = true
            }
            if group.required, !sealedAny { throw OMEMOError.sessionsUnavailable(group.jid) }
        }
        let element = EncryptedElement(
            version: version, senderDeviceID: own.deviceID, keys: keys, iv: payload.iv,
            payload: payload.ciphertext
        ).element
        for (address, session) in sealedSessions {
            try await saveSession(try session.encoded(), with: address, version: version)
        }
        return element
    }

    /// Records the keys the bundles read for this message show of listed devices that wait for
    /// the user's decision and whose key no bundle had shown (R60): the user sees which key
    /// they decide on, and a key the contact shows on a device decided on already (its twin
    /// in the other version) keeps that decision. Only a bundle whose signature holds counts.
    /// No session is made, and nothing is encrypted for them here.
    private func learnIdentities(
        from read: [DeviceAddress], bundles: [DeviceAddress: Element], version: OMEMOVersion
    ) async throws {
        var listed: [JID: [OMEMODevice]] = [:]
        for address in read {
            if listed[address.jid] == nil {
                listed[address.jid] = try await store.devices(of: address.jid, version: version)
            }
            // Read again: a message may have shown the key, or the user decided, meanwhile.
            guard
                let device = listed[address.jid]?.first(where: {
                    $0.deviceID == address.deviceID
                }),
                device.active, device.identityKey == nil, device.trust == .undecided
            else { continue }
            guard let element = bundles[address],
                let bundle = OMEMOBundle.parse(element, version: version),
                bundle.hasValidSignature(version: version)
            else {
                recordBundleFailure(address, version: version)
                continue
            }
            _ = try await recordIdentity(bundle.identityKey, of: device, version: version)
        }
    }

    /// The listed devices of `jid` that `TrustPolicy` lets have keys (never this device), as
    /// stored. With `required`, none listed or none trusted is an error.
    private func trustedDevices(
        of jid: JID, own: OwnIdentity, version: OMEMOVersion, required: Bool
    ) async throws -> [OMEMODevice] {
        let listed = try await store.devices(of: jid, version: version)
            .filter { $0.active && !(jid == accountJID && $0.deviceID == own.deviceID) }
        if required, listed.isEmpty { throw OMEMOError.noDevices(jid) }
        let trusted = listed.filter(TrustPolicy.receivesKeys)
        if required, trusted.isEmpty { throw OMEMOError.noTrustedDevices(jid) }
        return trusted
    }
}
