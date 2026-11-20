import Foundation
import XMPPCore
import os

extension OMEMOEngine {
    /// Decrypts the `<encrypted/>` element of a message from the bare JID `sender` (in a room,
    /// the occupant's real JID).
    ///
    /// Anything about the message itself is a result, never an error: a message without a key
    /// for this device, this device's own message, a duplicate, or a failure. Whatever the
    /// result, send `replies` and publish `bundleToPublish` when set:
    ///
    /// - a key exchange that started a new session is answered with an empty message, so the
    ///   sender stops repeating it; the one-time pre key it used is deleted with the session
    ///   saved, in one store call, and the bundle comes back to publish without it;
    /// - the first message with counter 53 or more on a ratchet key is answered with a heartbeat;
    /// - legacy OMEMO only: a message that cannot be decrypted for want of a working session
    ///   starts a new one, answered with an empty key exchange, at most once an hour per device.
    ///   OMEMO 2 forbids this (XEP-0384 0.9 security considerations: no new sessions in
    ///   reaction to decryption errors without user interaction); offer
    ///   `replaceSessions(with:version:)` to the user instead.
    ///
    /// Pass each message once: a message already stored (found by its stanza id) should not be
    /// decrypted again, since a repeat of an old message reads as a broken session.
    ///
    /// - Parameters:
    ///   - recipient: what the stanza is addressed to, which an OMEMO 2 envelope must match; nil
    ///     for a direct message to this account. A sent carbon or an archived copy of our own
    ///     message is `.direct(contact)`, a room message `.room(room)`.
    ///   - answering: false for a message that is not live (an archive copy, which may be old
    ///     or out of order): no replies are made, no session is repaired and no failure is
    ///     counted towards a repair, and no heartbeat is recorded. A message that decrypts is
    ///     still stored as any other (a pre key it used goes with the session save).
    ///   - promoting: whether a session this message decrypts on may become current again, or
    ///     its key exchange replace the current one; `answering` when nil. False for a live
    ///     message read late (kept while OMEMO could not read it, m11): newer messages may
    ///     have been read meanwhile, so it is answered but changes no current session. A key
    ///     exchange under a new identity key replaces the session all the same, unless the
    ///     device was heard from after `arrivedAt` (m18): then it is the device's older key,
    ///     and refused as `.identityChanged`.
    ///   - arrivedAt: when a message read late came.
    /// - Throws: `OMEMOError.noOwnDevice`, and the store's errors.
    public func decrypt(
        _ encrypted: Element, from sender: JID, version: OMEMOVersion,
        recipient: MessageRecipient? = nil, answering: Bool = true, promoting: Bool? = nil,
        arrivedAt: Date? = nil
    ) async throws -> DecryptedPayload {
        try await exclusively {
            try await open(
                encrypted, from: sender.bare, version: version,
                recipient: recipient ?? .direct(accountJID), answering: answering,
                promoting: promoting ?? answering, arrivedAt: arrivedAt)
        }
    }

    private struct OpenedKey {
        /// The session as it is to be stored: a new one, an earlier one now current again, or
        /// the current one moved on.
        var session: StoredSession
        /// The identity key of the session state that decrypted: the sender's, whatever
        /// `session` keeps as current.
        var identityKey: Data
        var keyMaterial: Data
        var header: RatchetHeader
        var isNewSession: Bool
        var consumedPreKeyID: UInt32?
    }

    private enum KeyOutcome {
        case opened(OpenedKey)
        case duplicate
        case failed(DecryptionFailure)
    }

    private func open(
        _ encrypted: Element, from sender: JID, version: OMEMOVersion,
        recipient: MessageRecipient, answering: Bool, promoting: Bool, arrivedAt: Date? = nil
    ) async throws -> DecryptedPayload {
        guard let own = try await store.ownIdentity(version: version) else {
            throw OMEMOError.noOwnDevice
        }
        guard let parsed = EncryptedElement(parsing: encrypted, version: version) else {
            return DecryptedPayload(content: .failed(.malformed))
        }
        let address = DeviceAddress(jid: sender, deviceID: parsed.senderDeviceID)
        let failureKey = RepairKey(device: address, version: version)
        var result = DecryptedPayload(content: .empty, sender: address)
        if sender == accountJID, parsed.senderDeviceID == own.deviceID {
            result.content = .sentByThisDevice
            return result
        }
        guard let key = parsed.key(for: accountJID, deviceID: own.deviceID) else {
            result.content = parsed.payload == nil ? .empty : .notForThisDevice
            return result
        }
        guard let keyData = key.data else {
            result.content = .failed(.malformed)
            return result
        }

        let stored = try await loadSession(address, version: version)
        let opened: OpenedKey
        switch try await openKey(
            keyData, isKeyExchange: key.isKeyExchange, from: address, stored: stored, own: own,
            version: version, answering: answering, promoting: promoting, arrivedAt: arrivedAt)
        {
        case .opened(let value):
            opened = value
        case .duplicate:
            result.content = .duplicate
            return result
        case .failed(let failure):
            result.content = .failed(failure)
            guard answering else { return result }
            if version == .v03,
                try await shouldRepair(after: failure, stored: stored, key: failureKey)
            {
                // The repair fetches a bundle: the caller runs it on its own (`repairSession`).
                result.repairWanted = true
            }
            return result
        }

        // The key authenticated. The payload is read before anything is stored: a message whose
        // payload or envelope fails leaves the session, the pre key and the device as they were,
        // so its intact copy still decrypts (spec 8.1).
        var content = DecryptedPayload.Content.empty
        if let payload = parsed.payload {
            content = Self.readPayload(
                payload, iv: parsed.iv, keyMaterial: opened.keyMaterial, sender: sender,
                recipient: recipient, version: version)
            if case .failed = content {
                result.content = content
                return result
            }
        }
        consecutiveFailures[failureKey] = nil

        // Record the device, answer if due, store the session. Until the device's record or the
        // session is written, a failure throws, and the caller's next try sees the message as
        // new (a changed key's old session may be gone, N7). Every write after it is logged,
        // and the message is still returned (m20): a try after a new key was recorded would
        // find it recorded and lose the identity-change flag.
        var session = opened.session
        session.sentSinceReceived = 0
        let origin = try await senderDevice(address, version: version)
        result.senderUnknown = !origin.known
        let recorded = try await recordIdentity(
            opened.identityKey, of: origin.device, version: version)
        let wrote = origin.device.identityKey != opened.identityKey
        var device = recorded.device

        var reason: KeyTransportMessage.Reason?
        if opened.isNewSession { reason = .sessionCompletion }
        let heartbeatDue =
            answering && opened.header.counter >= Self.heartbeatCounter
            && session.heartbeatRatchetKey != opened.header.ratchetKey
        if heartbeatDue { reason = reason ?? .heartbeat }
        if answering, let reason, device.trust != .distrusted {
            do {
                let stanza = try emptyMessage(
                    to: address, session: &session, own: own, version: version)
                result.replies = [
                    KeyTransportMessage(reason: reason, device: address, stanza: stanza)
                ]
                // Answered: recorded only now an answer exists. The caller says when it could
                // not send it (`heartbeatNotSent`).
                if heartbeatDue { session.heartbeatRatchetKey = opened.header.ratchetKey }
            } catch {
                Self.log.error(
                    "OMEMO empty message failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        var saved = true
        var consumed = false
        do {
            consumed = try await saveSession(
                try session.encoded(), with: address, consuming: opened.consumedPreKeyID,
                version: version)
        } catch {
            // Nothing recorded yet: the caller's next try starts clean.
            guard wrote else { throw error }
            Self.log.error(
                "OMEMO session not saved: \(error.localizedDescription, privacy: .public)")
            // An answer would complete on the other side a session this side does not keep:
            // without one, the device repeats its key exchange, and that one is read.
            result.replies = []
            saved = false
            // Kept for the device's repeat; deleted with its next session (m24).
            if let preKeyID = opened.consumedPreKeyID {
                unconsumedPreKeys[RepairKey(device: address, version: version)] = preKeyID
            }
        }
        if saved, consumed {
            do {
                var identity = own
                if try await refillPreKeys(&identity, version: version) {
                    try await store.saveOwnIdentity(identity, version: version)
                }
                result.bundleToPublish = try await bundleElement(version: version)
            } catch {
                // Filled up and published again by the next maintenance.
                Self.log.error(
                    "OMEMO pre keys not refilled: \(error.localizedDescription, privacy: .public)")
            }
        }
        device.lastSeen = now()
        do {
            try await store.saveDevice(device, version: version)
        } catch {
            Self.log.error(
                "OMEMO device not saved: \(error.localizedDescription, privacy: .public)")
        }

        result.senderTrust = device.trust
        result.fingerprint = Self.fingerprint(of: opened.identityKey, version: version)
        result.identityChanged = recorded.changed
        result.content = content
        return result
    }

    /// Decrypts the key: a ratchet message on the current session or, failing that, on one it
    /// replaced (which becomes current again, live only); a key exchange seen before on the
    /// session it built; or a new key exchange on a new session that replaces the current one
    /// (live) or is kept behind it (not live). Nothing is stored here.
    ///
    /// A copy that is not live never changes which session is current, and never opens a key
    /// exchange under another identity key than the one known for the device: an archived or
    /// repeated message must not pass for the device's under a key nobody checked.
    private func openKey(
        _ data: Data, isKeyExchange: Bool, from address: DeviceAddress, stored: StoredSession?,
        own: OwnIdentity, version: OMEMOVersion, answering: Bool, promoting: Bool,
        arrivedAt: Date? = nil
    ) async throws -> KeyOutcome {
        guard isKeyExchange else {
            guard let message = try? RatchetMessage(serialized: data, version: version) else {
                return .failed(.malformed)
            }
            guard let stored else { return .failed(.noSession) }
            return Self.open(message, on: stored, promoting: promoting)
        }
        guard let exchange = try? KeyExchangeMessage(serialized: data, version: version) else {
            return .failed(.malformed)
        }
        if let stored {
            let states = [stored.current] + stored.previous
            if let index = states.firstIndex(where: {
                $0.remoteEphemeralKey == exchange.ephemeralKey
                    && $0.remoteIdentityKey == exchange.identityKey
            }) {
                return Self.open(exchange.message, on: stored, only: index, promoting: promoting)
            }
        }
        if !answering {
            let recorded = try await store.devices(of: address.jid, version: version)
                .first { $0.deviceID == address.deviceID }?.identityKey
            if let known = recorded ?? stored?.remoteIdentityKey, known != exchange.identityKey {
                return .failed(.identityChanged)
            }
        }
        guard
            let signed = try await store.signedPreKeys(version: version).first(where: {
                $0.id == exchange.signedPreKeyID
            })
        else { return .failed(.unknownSignedPreKey) }
        guard let preKey = try await store.preKey(id: exchange.preKeyID, version: version) else {
            return .failed(.unknownPreKey)
        }
        var state: StoredSession.State
        do {
            let agreement = try X3DH.respond(
                own: own.identityKeyPair, signedPreKey: signed.keyPair, preKey: preKey.keyPair,
                remoteIdentityKey: exchange.identityKey, remoteEphemeral: exchange.ephemeralKey,
                version: version)
            let ratchet = try RatchetSession.responder(
                sharedSecret: agreement.sharedSecret, ownRatchetKeyPair: signed.keyPair,
                ad: agreement.associatedData, version: version)
            state = StoredSession.State(
                ratchet: ratchet, remoteIdentityKey: exchange.identityKey,
                remoteEphemeralKey: exchange.ephemeralKey)
        } catch {
            return .failed(.invalidKeyExchange)
        }
        switch Self.decrypt(exchange.message, on: &state) {
        case .success(let keyMaterial):
            // A live key exchange replaces the session (XEP-0384). An archived one may be
            // older than the session that read newer messages: it is only kept beside it.
            let session: StoredSession
            if let stored, answering,
                promoting || state.remoteIdentityKey != stored.remoteIdentityKey
            {
                // Read late under another key: the device's older one when it was heard
                // from after this message came (m18).
                if !promoting, let arrivedAt,
                    let seen = try await store.devices(of: address.jid, version: version)
                        .first(where: { $0.deviceID == address.deviceID })?.lastSeen,
                    seen > arrivedAt
                {
                    return .failed(.identityChanged)
                }
                session = stored.replacing(with: state)
            } else if let stored {
                guard let kept = stored.keeping(state) else { return .failed(.identityChanged) }
                session = kept
            } else {
                session = StoredSession(state, createdAt: now())
            }
            return .opened(
                OpenedKey(
                    session: session, identityKey: state.remoteIdentityKey,
                    keyMaterial: keyMaterial, header: exchange.message.header,
                    isNewSession: true, consumedPreKeyID: preKey.id))
        case .failure(let refused):
            return refused.outcome
        }
    }

    /// Tries the current session, then each replaced one, newest first.
    private static func open(
        _ message: RatchetMessage, on stored: StoredSession, promoting: Bool
    ) -> KeyOutcome {
        var firstFailure: KeyOutcome?
        for index in 0...stored.previous.count {
            let outcome = open(message, on: stored, only: index, promoting: promoting)
            switch outcome {
            case .opened, .duplicate:
                return outcome
            case .failed:
                firstFailure = firstFailure ?? outcome
            }
        }
        return firstFailure ?? .failed(.authenticationFailed)
    }

    /// Decrypts on one state of `stored` (0 the current one, then the replaced ones), working on
    /// a copy. A replaced state that decrypts becomes current again when `promoting` (a live
    /// message); otherwise it moves on in its own place. A message decrypted on a session this
    /// device started confirms the key exchange, which is then no longer sent.
    private static func open(
        _ message: RatchetMessage, on stored: StoredSession, only index: Int, promoting: Bool
    ) -> KeyOutcome {
        var state = index == 0 ? stored.current : stored.previous[index - 1]
        switch decrypt(message, on: &state) {
        case .success(let keyMaterial):
            var session = stored
            if index == 0 {
                session.current = state
            } else if promoting {
                session = stored.promoting(index - 1, as: state)
            } else {
                session.previous[index - 1] = state
            }
            return .opened(
                OpenedKey(
                    session: session, identityKey: state.remoteIdentityKey,
                    keyMaterial: keyMaterial, header: message.header, isNewSession: false,
                    consumedPreKeyID: nil))
        case .failure(let refused):
            return refused.outcome
        }
    }

    private struct Refused: Error {
        let outcome: KeyOutcome
    }

    private static func decrypt(
        _ message: RatchetMessage, on state: inout StoredSession.State
    ) -> Result<Data, Refused> {
        do {
            let keyMaterial = try state.ratchet.decrypt(message)
            state.pendingKeyExchange = nil
            return .success(keyMaterial)
        } catch .duplicateMessage {
            return .failure(Refused(outcome: .duplicate))
        } catch .tooManySkippedMessages {
            return .failure(Refused(outcome: .failed(.tooManySkippedMessages)))
        } catch {
            return .failure(Refused(outcome: .failed(.authenticationFailed)))
        }
    }

    /// The heartbeat or other empty message made for `device` was not sent: a later message
    /// on the same ratchet key asks for a heartbeat again.
    public func heartbeatNotSent(to device: DeviceAddress, version: OMEMOVersion) async throws {
        try await exclusively {
            guard var session = try await loadSession(device, version: version),
                session.heartbeatRatchetKey != nil
            else { return }
            session.heartbeatRatchetKey = nil
            try await store.saveSession(try session.encoded(), with: device, version: version)
        }
    }

    /// Whether a legacy failure calls for a new session.
    ///
    /// - Never for what says nothing about the session: a malformed element, a bad payload or
    ///   envelope.
    /// - A key exchange this device cannot take (its pre keys are gone, its keys are bad) only
    ///   when there is no session: it may be an old copy of the one that built the working
    ///   session.
    /// - A message that does not authenticate on any kept session only after
    ///   `brokenSessionFailures` such messages in a row: one alone may be corrupted or forged,
    ///   and must leave the session as it is.
    private func shouldRepair(
        after failure: DecryptionFailure, stored: StoredSession?, key: RepairKey
    ) async throws -> Bool {
        switch failure {
        case .noSession:
            return true
        case .unknownPreKey, .unknownSignedPreKey, .invalidKeyExchange:
            return stored == nil
        case .authenticationFailed, .tooManySkippedMessages:
            guard stored != nil else { return true }
            let failures = (consecutiveFailures[key] ?? 0) + 1
            consecutiveFailures[key] = failures
            return failures >= Self.brokenSessionFailures
        case .malformed, .invalidPayload, .envelopeRejected, .identityChanged, .notReadable:
            return false
        }
    }

    /// Whether an automatic repair of the device's session may run: not when one was tried
    /// within `repairInterval`.
    private func repairDue(_ address: DeviceAddress, stored: StoredSession?, version: OMEMOVersion)
        -> Bool
    {
        let key = RepairKey(device: address, version: version)
        if let last = [repairAttempts[key], stored?.lastRepairAt].compactMap({ $0 }).max(),
            now().timeIntervalSince(last) < Self.repairInterval
        {
            return false
        }
        return true
    }

    /// The automatic repair `decrypt` asked for (`DecryptedPayload.repairWanted`): a new
    /// session with the device from its bundle, stored in place of the broken one, and the
    /// empty key exchange that hands it over. Nil when a repair of the device was tried within
    /// `repairInterval`, when it is distrusted, when its bundle cannot be had, or when a
    /// message from it decrypted after `failedAt` (the session works after all).
    ///
    /// The bundle is fetched outside the engine's queue, so decryption and encryption go on
    /// meanwhile; only the decision and the new session are made in it.
    public func repairSession(
        with address: DeviceAddress, version: OMEMOVersion, failedAt: Date? = nil
    ) async throws -> KeyTransportMessage? {
        let device: OMEMODevice? = try await exclusively {
            guard try await store.ownIdentity(version: version) != nil else {
                throw OMEMOError.noOwnDevice
            }
            let stored = try await loadSession(address, version: version)
            guard repairDue(address, stored: stored, version: version) else { return nil }
            let device = try await senderDevice(address, version: version).device
            if let failedAt, let heard = device.lastSeen, heard > failedAt { return nil }
            guard device.trust != .distrusted else { return nil }
            let key = RepairKey(device: address, version: version)
            repairAttempts[key] = now()
            consecutiveFailures[key] = nil
            return device
        }
        guard device != nil else { return nil }
        let fetched = await fetchBundles([address], version: version)
        defer { used(fetched) }
        let bundle = fetched[address]
        return try await exclusively {
            guard let own = try await store.ownIdentity(version: version) else {
                throw OMEMOError.noOwnDevice
            }
            // Read again: the user may have refused the device, or it was heard from, while
            // the bundle was on its way.
            let device = try await senderDevice(address, version: version).device
            if let failedAt, let heard = device.lastSeen, heard > failedAt { return nil }
            return try await replaceSession(
                with: device, own: own, version: version, bundle: bundle)
        }
    }

    /// Reads the device list of the bare JID `jid` again, then replaces the session with every
    /// listed device that is not distrusted (for the account's own JID, its other devices) by a
    /// new one, and returns the empty key exchanges that hand the new sessions over. This is the
    /// manual replacement of broken sessions XEP-0384 requires clients to offer, per chat.
    /// Devices whose bundle cannot be fetched or used are left out.
    ///
    /// The list and the bundles are fetched outside the engine's queue, and the sessions are
    /// made a few devices at a time, so other work goes on between them (final review I-3).
    public func replaceSessions(
        with jid: JID, version: OMEMOVersion
    ) async throws -> [KeyTransportMessage] {
        let jid = jid.bare
        let ownDeviceID: UInt32 = try await exclusively {
            guard let own = try await store.ownIdentity(version: version) else {
                throw OMEMOError.noOwnDevice
            }
            return own.deviceID
        }
        // The current list first: the known one may be stale, or never read.
        if let element = try? await transport.fetchDeviceList(of: jid, version: version),
            let ids = DeviceList.deviceIDs(in: element, version: version)
        {
            _ = try await exclusively {
                try await applyDeviceList(
                    ids, of: jid, version: version,
                    ownDeviceID: jid == accountJID ? ownDeviceID : nil)
            }
        }
        let devices: [OMEMODevice] = try await exclusively {
            try await store.devices(of: jid, version: version).filter {
                $0.active && !(jid == accountJID && $0.deviceID == ownDeviceID)
            }
        }
        let bundles = await fetchBundles(devices.map(\.address), version: version)
        defer { used(bundles) }
        var replies: [KeyTransportMessage] = []
        var next = 0
        while next < devices.count {
            let batch = devices[next..<min(next + Self.replacementsPerTurn, devices.count)]
            next += batch.count
            replies += try await exclusively {
                guard let own = try await store.ownIdentity(version: version) else {
                    throw OMEMOError.noOwnDevice
                }
                var made: [KeyTransportMessage] = []
                for device in batch {
                    // Read again: the user may have refused it, or it left the list, meanwhile.
                    guard
                        let current = try await store.devices(of: jid, version: version)
                            .first(where: { $0.deviceID == device.deviceID }),
                        current.active
                    else { continue }
                    if let reply = try await replaceSession(
                        with: current, own: own, version: version,
                        bundle: bundles[device.address])
                    {
                        made.append(reply)
                    }
                }
                return made
            }
        }
        return replies
    }

    /// Sessions `replaceSessions(with:version:)` makes in one job of the engine's queue.
    static let replacementsPerTurn = 8

    /// Starts a new session with `device` from its bundle (fetched by the caller), stores it in
    /// place of the current one (which is kept among the replaced ones), and returns the empty
    /// key exchange that hands it over. Nil when the device is distrusted or the bundle is
    /// missing or cannot be used.
    private func replaceSession(
        with device: OMEMODevice, own: OwnIdentity, version: OMEMOVersion, bundle: Element?
    ) async throws -> KeyTransportMessage? {
        guard device.trust != .distrusted else { return nil }
        let now = now()
        repairAttempts[RepairKey(device: device.address, version: version)] = now
        guard
            let built = try await newSession(
                with: device, bundle: bundle, own: own, version: version)
        else { return nil }
        let stored = try await loadSession(device.address, version: version)
        var session =
            stored?.replacing(with: built.state) ?? StoredSession(built.state, createdAt: now)
        session.lastRepairAt = now
        let stanza = try emptyMessage(
            to: device.address, session: &session, own: own, version: version)
        try await saveSession(try session.encoded(), with: device.address, version: version)
        Self.log.notice(
            "OMEMO session replaced with a device of \(device.jid.description, privacy: .private)")
        return KeyTransportMessage(reason: .sessionRepair, device: device.address, stanza: stanza)
    }

    /// The sending device as stored; else a new, unlisted device with the trust `TrustPolicy`
    /// gives it, not yet stored (`known` false). Nothing is fetched: the caller reads the
    /// sender's list again on its own when it wants to (`DecryptedPayload.senderUnknown`).
    private func senderDevice(
        _ address: DeviceAddress, version: OMEMOVersion
    ) async throws -> (device: OMEMODevice, known: Bool) {
        let devices = try await store.devices(of: address.jid, version: version)
        if let known = devices.first(where: { $0.deviceID == address.deviceID }) {
            return (known, true)
        }
        // BTBV over both versions (R60).
        let elsewhere = try await store.devices(of: address.jid, version: version.other)
        return (
            OMEMODevice(
                jid: address.jid, deviceID: address.deviceID, active: false,
                trust: TrustPolicy.trustForNewDevice(among: devices + elsewhere)), false
        )
    }

    /// The payload with the key material: the body (legacy, UTF-8), or the checked envelope's
    /// content (OMEMO 2).
    private static func readPayload(
        _ payload: Data, iv: Data?, keyMaterial: Data, sender: JID, recipient: MessageRecipient,
        version: OMEMOVersion
    ) -> DecryptedPayload.Content {
        let plaintext: Data
        do {
            plaintext = try PayloadCipher.decrypt(
                payload, iv: iv, keyMaterial: keyMaterial, version: version)
        } catch {
            return .failed(.invalidPayload)
        }
        switch version {
        case .v03:
            guard let body = String(data: plaintext, encoding: .utf8) else {
                return .failed(.invalidPayload)
            }
            return .message(DecryptedMessage(body: body))
        case .v2:
            let envelope: SCE.Envelope
            do {
                envelope = try SCE.Envelope(parsing: plaintext)
                try envelope.verify(sender: sender, recipient: recipient)
            } catch {
                return .failed(.envelopeRejected)
            }
            let isBody = { (element: Element) in
                element.name == "body" && element.namespace == "jabber:client"
            }
            let bodies = envelope.content.filter(isBody)
            let body = bodies.first { $0[attribute: "xml:lang"] == nil } ?? bodies.first
            return .message(
                DecryptedMessage(
                    body: body?.text, elements: envelope.content.filter { !isBody($0) },
                    sentAt: envelope.time))
        }
    }
}
