import Foundation
import XMPPCore

/// What `OMEMOEngine.encrypt` encrypts.
public struct MessageContent: Sendable, Equatable {
    public var body: String?
    /// Further elements for an OMEMO 2 envelope's `<content/>` (a reply, a file link, ...), each
    /// in its own namespace. Legacy OMEMO encrypts the body only, so these must be empty there.
    public var elements: [Element]

    public init(body: String?, elements: [Element] = []) {
        self.body = body
        self.elements = elements
    }
}

/// A decrypted message.
public struct DecryptedMessage: Sendable, Equatable {
    public var body: String?
    /// OMEMO 2: the envelope's other content elements; legacy: none.
    public var elements: [Element]
    /// OMEMO 2: when the sender encrypted it, from the envelope's `<time/>`. Compare it with
    /// the stanza's delay (or the time of arrival) before trusting it; XEP-0420 leaves the
    /// margin to the client.
    public var sentAt: Date?

    public init(body: String?, elements: [Element] = [], sentAt: Date? = nil) {
        self.body = body
        self.elements = elements
        self.sentAt = sentAt
    }
}

/// Why a message could not be decrypted.
public enum DecryptionFailure: Error, Sendable, Equatable {
    /// The `<encrypted/>` element, a key or a protobuf message cannot be read.
    case malformed
    /// A message for a session this device does not have.
    case noSession
    /// A key exchange naming a one-time pre key this device no longer has.
    case unknownPreKey
    /// A key exchange naming a signed pre key this device no longer has.
    case unknownSignedPreKey
    /// A key exchange whose keys do not work.
    case invalidKeyExchange
    /// The key does not authenticate under the session: altered, or the session is broken.
    case authenticationFailed
    /// The message is too far ahead in its chain.
    case tooManySkippedMessages
    /// The payload does not decrypt or authenticate with the key, or is not UTF-8 (legacy).
    case invalidPayload
    /// OMEMO 2: the decrypted envelope is not valid, or its affixes do not match the stanza.
    case envelopeRejected
    /// A copy that is not live (`answering: false`) carries a key exchange under another
    /// identity key than the one known for the device: it is not opened as that device's.
    case identityChanged
    /// The engine could not read it: its own store failed before the device's record was
    /// written, or it has no device of the version, also after retries (m10). Reported by the caller, for
    /// live messages and archive copies alike; never the message's fault, so a later copy may
    /// still read it.
    case notReadable
}

/// An empty OMEMO message the engine wants sent: it carries no content, only keeps a session
/// working.
public struct KeyTransportMessage: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The answer to a key exchange, so the other side stops repeating it.
        case sessionCompletion
        /// The other side sent 53 or more messages on one ratchet key without hearing back
        /// (XEP-0384 heartbeat): the answer lets it move to a new key.
        case heartbeat
        /// A new session replacing a broken one: after a legacy message could not be decrypted,
        /// or on request (`OMEMOEngine.replaceSessions(with:version:)`).
        case sessionRepair
    }

    public var reason: Reason
    public var device: DeviceAddress
    /// The `<message/>` to send as it is: to the device's bare JID, type `chat`, with the
    /// `<encrypted/>` element and a store hint.
    public var stanza: Element

    public init(reason: Reason, device: DeviceAddress, stanza: Element) {
        self.reason = reason
        self.device = device
        self.stanza = stanza
    }
}

/// The result of `OMEMOEngine.decrypt`. Whatever the outcome, send `replies` and publish
/// `bundleToPublish` when set.
public struct DecryptedPayload: Sendable {
    public enum Content: Sendable, Equatable {
        case message(DecryptedMessage)
        /// An empty OMEMO message (key transport, heartbeat, session completion or repair), or
        /// one for another device: nothing to show.
        case empty
        /// The message has a payload but no key for this device: show that it could not be read
        /// here.
        case notForThisDevice
        /// This device's own message coming back (a room reflection, an archive copy): the
        /// sender never encrypts for itself, and already has the text.
        case sentByThisDevice
        /// Already decrypted once: ignore it without a warning (XEP-0384).
        case duplicate
        case failed(DecryptionFailure)
    }

    public var content: Content
    /// The sending device; nil when the element did not name one.
    public var sender: DeviceAddress?
    /// The sending device's trust, once the message decrypted. Show anything else than
    /// `.trusted` or `.verified` with the message.
    public var senderTrust: DeviceTrust?
    /// The sending device's fingerprint, once the message decrypted.
    public var fingerprint: String?
    /// The sending device came with another identity key than the one known for it.
    public var identityChanged = false
    /// Empty OMEMO messages to send now.
    public var replies: [KeyTransportMessage] = []
    /// Legacy OMEMO: the session with the sender looks broken. Run
    /// `OMEMOEngine.repairSession(with:version:)` for `sender` when that is wanted, off the
    /// path that handles messages: it fetches the device's bundle. `decrypt` itself never
    /// waits on the network.
    public var repairWanted = false
    /// The sending device was not known: its account's device list may be worth reading
    /// again, so the device gets keys. The message was decrypted without it.
    public var senderUnknown = false
    /// This device's bundle, to publish because a one-time pre key was used (and the bundle
    /// filled up again when it ran low). Several in a row: publishing the last is enough.
    public var bundleToPublish: Element?

    public init(content: Content, sender: DeviceAddress? = nil) {
        self.content = content
        self.sender = sender
    }
}

/// The conversation an encrypted message belongs to, to check an OMEMO 2 envelope against.
public enum MessageRecipient: Sendable, Hashable {
    /// A one-to-one message to this bare JID: the account itself for a message it received,
    /// the contact for its own message copied back (a sent carbon, an archive copy).
    case direct(JID)
    /// A message in the room with this bare JID.
    case room(JID)
}

/// A group chat to encrypt for. OMEMO needs the members' real JIDs, so only rooms that are
/// non-anonymous and members-only are allowed (XEP-0384).
public struct OMEMORoom: Sendable, Hashable {
    public var jid: JID
    public var isNonAnonymous: Bool
    public var isMembersOnly: Bool

    public init(jid: JID, isNonAnonymous: Bool, isMembersOnly: Bool) {
        self.jid = jid.bare
        self.isNonAnonymous = isNonAnonymous
        self.isMembersOnly = isMembersOnly
    }
}

/// A device and how current it is, for showing it.
public struct DeviceStatus: Sendable, Equatable {
    public var device: OMEMODevice
    /// No message from it for `OMEMOEngine.staleAfterSilence`, or
    /// `OMEMOEngine.staleAfterMessages` sent to it without an answer: it gets no keys while
    /// the contact has a device that is not stale and can be reached. Only a device with a
    /// session can be stale.
    public var isStale: Bool
    /// Messages encrypted for it since one from it last decrypted.
    public var messagesSinceLastReceived: Int
    /// A session with it exists: messages can reach it.
    public var hasSession: Bool
    /// Its bundle could not be had, and it is not asked for again yet: without a session, no
    /// message reaches it until it can be.
    public var isBundleUnavailable: Bool

    public init(
        device: OMEMODevice, isStale: Bool, messagesSinceLastReceived: Int, hasSession: Bool,
        isBundleUnavailable: Bool
    ) {
        self.device = device
        self.isStale = isStale
        self.messagesSinceLastReceived = messagesSinceLastReceived
        self.hasSession = hasSession
        self.isBundleUnavailable = isBundleUnavailable
    }
}

/// What a device list changed.
public struct DeviceListUpdate: Sendable, Equatable {
    /// Devices seen for the first time, with the trust they start with.
    public var added: [OMEMODevice] = []
    /// Devices no longer listed: they get no keys until they are listed again.
    public var deactivated: [UInt32] = []
    /// The account's own list without this device: publish this one, which has it (XEP-0384:
    /// a device missing from its own list announces itself again).
    public var listToPublish: Element?

    public init(
        added: [OMEMODevice] = [], deactivated: [UInt32] = [], listToPublish: Element? = nil
    ) {
        self.added = added
        self.deactivated = deactivated
        self.listToPublish = listToPublish
    }
}

/// Why the engine refused a request.
public enum OMEMOError: Error, Sendable, Equatable {
    /// `ensureOwnDevice(version:)` has not run for this version.
    case noOwnDevice
    /// The recipient publishes no device for this version.
    case noDevices(JID)
    /// The recipient has devices, but none listed that the user trusts.
    case noTrustedDevices(JID)
    /// The recipient's trusted devices have no session and no usable bundle.
    case sessionsUnavailable(JID)
    /// A room that is not both non-anonymous and members-only.
    case roomNotSuitable
    /// A message without a room must have exactly one recipient.
    case invalidRecipients
    /// Nothing to encrypt: no body (legacy), or no body and no elements.
    case nothingToEncrypt
    /// Legacy OMEMO encrypts the body only.
    case legacyEncryptsBodyOnly
    /// No such device is known.
    case unknownDevice(DeviceAddress)
    /// No device of the contact shows the identity key (`setTrust(_:forIdentity:of:)`).
    case unknownIdentity(JID)
    /// Not a device list of this version.
    case invalidDeviceList
}
