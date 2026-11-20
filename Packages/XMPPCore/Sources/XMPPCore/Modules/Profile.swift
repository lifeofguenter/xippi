import Foundation

/// The parts of a vCard (XEP-0292 vCard4 or XEP-0054 vcard-temp) the client shows and edits.
///
/// `source` keeps the vCard the profile was read from. Publishing an edited profile writes its
/// fields into that vCard and keeps every other property (addresses, birthday, organisation),
/// and the parameters of the emails and numbers that stay, as they were.
public struct Profile: Sendable, Hashable {
    public enum Photo: Sendable, Hashable {
        /// The image itself, with its MIME type: at most `Avatars.maxBytes` when read, at most
        /// `Avatars.maxPublishBytes` when it is new to the published vCard (use
        /// `Avatars.prepareForPublishing`).
        case data(Data, type: String?)
        /// Where the image is (`http` or `https` only).
        case url(URL)
    }

    public var fullName: String?
    public var nickname: String?
    public var emails: [String]
    public var phones: [String]
    /// The user's web page (`http` or `https` only).
    public var url: URL?
    public var note: String?
    public var avatar: Photo?
    /// The vCard this profile was read from; nil for a new one.
    public var source: Element?

    public init(
        fullName: String? = nil, nickname: String? = nil, emails: [String] = [],
        phones: [String] = [], url: URL? = nil, note: String? = nil, avatar: Photo? = nil
    ) {
        self.fullName = fullName
        self.nickname = nickname
        self.emails = emails
        self.phones = phones
        self.url = url
        self.note = note
        self.avatar = avatar
    }

    /// A web address shown as a link: `http` or `https` with a host, nothing else.
    static func webURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
            url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Base64 image data of at most `Avatars.maxBytes`; nil when it is longer or not base64.
    static func imageData(base64 text: String) -> Data? {
        guard case .data(let data) = Avatars.base64Data(text, maxBytes: Avatars.maxBytes) else {
            return nil
        }
        return data
    }

    /// Whether the profile can be published: a new embedded photo must fit
    /// `Avatars.maxPublishBytes` (ruling R36), or the stanza would exceed the server's limit.
    /// A photo the source vCard already had (read back by `read`) is kept as it was.
    func photoFits(readingSourceWith read: (Element) -> Profile?) -> Bool {
        guard case .data(let data, _) = avatar, data.count > Avatars.maxPublishBytes else {
            return true
        }
        return source.flatMap(read)?.avatar == avatar
    }
}

/// Writes a profile's fields into the vCard it came from, keeping everything else.
///
/// A property the profile shows (`kind`) is read with `value`. Single properties stay as they
/// were when the profile's value is unchanged and are replaced in place otherwise. For lists,
/// the elements whose value is still listed stay, those whose value is gone are dropped, and
/// new values are added at the end. Elements of a kind whose value cannot be read (an empty
/// fax number) are not part of the profile and stay.
struct VCardMerge {
    var children: [XMLNode]

    init(source: Element?) {
        children = source?.children ?? []
    }

    /// Sets the single property `kind` to `element` (nil removes it).
    mutating func setSingle(
        _ kind: (Element) -> Bool, value: (Element) -> String?, to newValue: String?,
        element: () -> Element?
    ) {
        func isKind(_ node: XMLNode, readable: Bool) -> Bool {
            guard case .element(let e) = node, kind(e) else { return false }
            return !readable || value(e) != nil
        }
        // The property in use; an empty one only when it is to get a value.
        let index =
            children.firstIndex { isKind($0, readable: true) }
            ?? (newValue == nil ? nil : children.firstIndex { isKind($0, readable: false) })
        if let index, case .element(let current) = children[index],
            value(current) == newValue
        {
            return
        }
        let replacement = newValue == nil ? nil : element()
        if let index {
            if let replacement {
                children[index] = .element(replacement)
            } else {
                children.remove(at: index)
            }
        } else if let replacement {
            children.append(.element(replacement))
        }
    }

    /// Sets the list property `kind` to `values`.
    mutating func setList(
        _ kind: (Element) -> Bool, value: (Element) -> String?, to values: [String],
        element: (String) -> Element
    ) {
        var remaining = values
        children = children.filter { node in
            guard case .element(let e) = node, kind(e), let current = value(e) else { return true }
            guard let index = remaining.firstIndex(of: current) else { return false }
            remaining.remove(at: index)
            return true
        }
        children += remaining.map { .element(element($0)) }
    }
}
