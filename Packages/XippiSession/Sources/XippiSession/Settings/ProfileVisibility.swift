import Foundation
import XMPPCore

/// Who can read the account's profile and picture (ruling R64): its contacts (those who see
/// its presence), or everyone. Contacts is the default. Only a profile saved for Everyone is
/// also written to vcard-temp (XEP-0054), which anyone can read; switching never writes it
/// (R70).
public enum ProfileVisibility: String, Sendable, CaseIterable {
    case contacts
    case everyone

    /// The access model of the profile's and the picture's nodes.
    public var access: PEPAccess {
        switch self {
        case .contacts: .presence
        case .everyone: .open
        }
    }
}

/// Who can read the profile and picture now, as the server holds them (R64, amended).
public enum ProfileAudience: Sendable, Equatable {
    case contacts
    case everyone
    /// Some of it for contacts, some of it for everyone.
    case mixed
    /// A read failed or was refused.
    case unknown
}

/// One field of a vcard-temp, which anyone can read, as the "Remove public copy" dialog
/// lists it: the element's name and a short value. Judged on the raw XML (R70): any element
/// with text other than blanks is one, whatever a parser makes of it.
public struct PublicField: Sendable, Hashable {
    public var name: String
    /// The element's texts, joined and shortened; empty for binary data (PHOTO, LOGO, SOUND,
    /// KEY), which is named only.
    public var value: String

    public static let maxValue = 40
    /// vcard-temp elements that carry binary data: named, never shown.
    static let binaryElements: Set<String> = ["PHOTO", "LOGO", "SOUND", "KEY"]

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// The fields of a vcard-temp `<vCard/>`, in its order.
    static func fields(in vcard: Element?) -> [PublicField] {
        (vcard?.elements ?? []).compactMap { element in
            let texts = Self.texts(in: element)
            guard !texts.isEmpty else { return nil }
            if binaryElements.contains(element.name) {
                return PublicField(name: element.name, value: "")
            }
            let joined = texts.joined(separator: " ")
            let value =
                joined.count > maxValue ? String(joined.prefix(maxValue)) + "…" : joined
            return PublicField(name: element.name, value: value)
        }
    }

    /// The texts in `element` and below, trimmed, without blanks.
    private static func texts(in element: Element) -> [String] {
        element.children.flatMap { node -> [String] in
            switch node {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            case .element(let child):
                return texts(in: child)
            }
        }
    }
}

/// The public copy as shown: its fields, and a digest of the raw `<vCard/>` they came from,
/// which "Remove public copy" compares (m26), so nothing unseen is deleted.
public struct PublicCopySnapshot: Sendable, Equatable {
    public var fields: [PublicField]
    /// SHA-1 of the raw `<vCard/>` as read.
    public var digest: String

    public init(fields: [PublicField], digest: String) {
        self.fields = fields
        self.digest = digest
    }

    static func of(_ vcard: Element?) -> PublicCopySnapshot {
        PublicCopySnapshot(
            fields: PublicField.fields(in: vcard),
            digest: Avatars.sha1(Data((vcard?.xml() ?? "").utf8)))
    }
}

/// How "Remove public copy" ended.
public enum PublicCopyRemoval: Sendable, Equatable {
    case removed
    /// The vcard-temp is no longer what was shown: nothing was deleted; ask again with this.
    case changed(PublicCopySnapshot)
}

/// The profile's audience as read.
public struct ProfileAudienceReading: Sendable, Equatable {
    /// Who can read the profile and picture in effect.
    public var audience: ProfileAudience
    /// What the nodes are set to, when one; nil when mixed or not known. What a publish takes.
    public var setting: ProfileVisibility?
    /// Our own vcard-temp on a server without XEP-0398: public, and "Remove public copy"
    /// can delete it.
    public var publicCopy: [PublicField]
    /// What a server that converts keeps in a public vcard-temp of its own (ejabberd's
    /// `mod_avatar` copies the picture there): this app cannot remove it.
    public var serverCopy: [PublicField]
    /// Whether the server is known to keep that copy (ejabberd); otherwise it only may.
    public var serverCopyCertain: Bool
    /// `publicCopy` with the digest of the vcard-temp it came from, for "Remove public copy".
    public var publicCopySnapshot: PublicCopySnapshot?

    public init(
        audience: ProfileAudience, setting: ProfileVisibility? = nil,
        publicCopy: [PublicField] = [], serverCopy: [PublicField] = [],
        serverCopyCertain: Bool = false, publicCopySnapshot: PublicCopySnapshot? = nil
    ) {
        self.audience = audience
        self.setting = setting
        self.publicCopy = publicCopy
        self.serverCopy = serverCopy
        self.serverCopyCertain = serverCopyCertain
        self.publicCopySnapshot = publicCopySnapshot
    }
}

/// The reads of the audience a view makes: each read and each switch takes a new generation,
/// and a read that finishes after a newer one began is dropped.
public struct ProfileAudienceTracker: Sendable {
    public private(set) var reading: ProfileAudienceReading?
    private var generation = 0

    public init() {}

    /// A read begins; what was read before is no longer shown.
    public mutating func beginRead() -> Int {
        generation += 1
        reading = nil
        return generation
    }

    /// A switch begins: reads under way are overtaken.
    public mutating func beginSwitch() {
        generation += 1
    }

    public func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Keeps `reading` when its read is the latest; returns whether it was kept.
    @discardableResult
    public mutating func finishRead(_ reading: ProfileAudienceReading, generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        self.reading = reading
        return true
    }
}
