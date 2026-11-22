import GRDB

public enum ChatKind: String, Codable, Sendable, DatabaseValueConvertible {
    case direct, room, channel
    /// Private messages with one occupant of a room (XEP-0045 7.5, ruling R80), keyed by the
    /// occupant's address (`room@service/nick`). They go through the room, in the clear.
    case roomPrivate
}
public enum NotifyLevel: String, Codable, Sendable, DatabaseValueConvertible {
    case all, mentions, none
}
public enum EncryptionMode: String, Codable, Sendable, DatabaseValueConvertible { case none, omemo }
/// What shows behind a chat's messages. Nil on a chat: the app's default.
public enum ChatBackground: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case confetti, plain
}
public enum MessageDirection: String, Codable, Sendable, DatabaseValueConvertible {
    case incoming, outgoing
}
public enum MessageState: String, Codable, Sendable, DatabaseValueConvertible {
    case pending, sent, delivered, displayed, failed
}
public enum MessageKind: String, Codable, Sendable, DatabaseValueConvertible {
    case text, file, location, system, callLog
}
public enum AttachmentState: String, Codable, Sendable, DatabaseValueConvertible {
    case remote, downloading, local, failed, uploading
    /// A file a contact offers over Jingle (XEP-0234, ruling R79), not accepted or declined
    /// yet. Accepting it makes it `downloading`.
    case offered
}
public enum OMEMOVersion: String, Codable, Sendable, DatabaseValueConvertible { case v03, v2 }
public enum OMEMOTrust: String, Codable, Sendable, DatabaseValueConvertible {
    case undecided, trusted, verified, distrusted
}
