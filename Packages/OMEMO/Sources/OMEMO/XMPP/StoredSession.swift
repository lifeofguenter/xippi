import Foundation

/// What the engine stores per remote device: the current Double Ratchet session, the sessions
/// it replaced, and the XMPP-side state around them. All of it is key material.
struct StoredSession: Sendable, Codable {
    /// Our X3DH header, sent with every message until the first answer decrypts (XEP-0384:
    /// the key exchange is repeated until the other side confirms it).
    struct PendingKeyExchange: Sendable, Codable, Equatable {
        var preKeyID: UInt32
        var signedPreKeyID: UInt32
        var ephemeralKey: Data
    }

    /// One session with the device.
    struct State: Sendable, Codable {
        var ratchet: RatchetSession
        /// The identity key the session was built with.
        var remoteIdentityKey: Data
        var pendingKeyExchange: PendingKeyExchange?
        /// The ephemeral key of the other side's key exchange this session was built from: the
        /// same key exchange again (repeated until we answer) belongs to this session.
        var remoteEphemeralKey: Data?
        /// The remote ratchet key the last heartbeat answered, so each key gets one.
        var heartbeatRatchetKey: Data?
    }

    /// Raised when the encoding changes, so an old blob can be read or dropped on purpose.
    static let currentFormat = 1

    /// Replaced sessions kept per device. Two devices that start sessions with each other at
    /// the same time each replace their own (XEP-0384 5.6) and then send on the other's; the
    /// replaced ones decrypt what still comes on them. libsignal keeps such states too.
    static let maxPrevious = 5

    var format = Self.currentFormat
    var current: State
    /// Newest first, at most `maxPrevious`, all for the current identity key.
    var previous: [State] = []
    /// When this device last started a new session to repair a broken one.
    var lastRepairAt: Date?
    /// When the first session with the device was made.
    var createdAt: Date
    /// Messages encrypted for the device since one from it last decrypted.
    var sentSinceReceived = 0

    init(_ state: State, createdAt: Date, lastRepairAt: Date? = nil) {
        current = state
        self.createdAt = createdAt
        self.lastRepairAt = lastRepairAt
    }

    init(encoded: Data) throws {
        self = try PropertyListDecoder().decode(Self.self, from: encoded)
        guard format == Self.currentFormat, current.remoteIdentityKey.count == 32,
            previous.count <= Self.maxPrevious
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Unknown session format"))
        }
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    var ratchet: RatchetSession {
        get { current.ratchet }
        set { current.ratchet = newValue }
    }

    var remoteIdentityKey: Data { current.remoteIdentityKey }

    var pendingKeyExchange: PendingKeyExchange? {
        get { current.pendingKeyExchange }
        set { current.pendingKeyExchange = newValue }
    }

    var heartbeatRatchetKey: Data? {
        get { current.heartbeatRatchetKey }
        set { current.heartbeatRatchetKey = newValue }
    }

    /// `state` as the current session, the one it replaces kept first among the previous. A
    /// state for another identity key drops every earlier one: they belong to a key no longer
    /// in use.
    func replacing(with state: State) -> StoredSession {
        var session = self
        if state.remoteIdentityKey == current.remoteIdentityKey {
            session.previous = Array(([current] + previous).prefix(Self.maxPrevious))
        } else {
            session.previous = []
        }
        session.current = state
        return session
    }

    /// `state` kept among the previous sessions, behind the current one, which stays: an
    /// archived key exchange that must not displace the session that read newer messages. Nil
    /// for a state under another identity key: that is a new identity, never the device's
    /// known one, and the caller refuses it.
    func keeping(_ state: State) -> StoredSession? {
        guard state.remoteIdentityKey == current.remoteIdentityKey else { return nil }
        var session = self
        session.previous = Array(([state] + previous).prefix(Self.maxPrevious))
        return session
    }

    /// The previous session at `index` as the current one, the current one kept first among
    /// the previous.
    func promoting(_ index: Int, as state: State) -> StoredSession {
        var session = self
        var others = previous
        others.remove(at: index)
        session.previous = Array(([current] + others).prefix(Self.maxPrevious))
        session.current = state
        return session
    }
}

extension StoredSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "StoredSession(\(current.ratchet), \(previous.count) previous)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["ratchet": current.ratchet, "previous": previous.count])
    }
}
