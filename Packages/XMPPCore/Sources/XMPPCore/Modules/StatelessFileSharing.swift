import Foundation

/// XEP-0446 file metadata, as carried by XEP-0447 and XEP-0234.
public struct FileMetadata: Sendable, Equatable {
    public struct Hash: Sendable, Equatable {
        /// XEP-0300 algorithm name, such as "sha-256".
        public var algorithm: String
        public var value: Data

        public init(algorithm: String, value: Data) {
            self.algorithm = algorithm
            self.value = value
        }
    }

    public struct Thumbnail: Sendable, Equatable {
        /// An `https` address or a `cid:` reference (XEP-0231); other schemes are dropped on parse.
        public var uri: String
        public var mediaType: String?
        public var width: Int?
        public var height: Int?

        public init(uri: String, mediaType: String? = nil, width: Int? = nil, height: Int? = nil) {
            self.uri = uri
            self.mediaType = mediaType
            self.width = width
            self.height = height
        }
    }

    public var mediaType: String?
    public var name: String?
    public var size: Int64?
    public var date: Date?
    public var description: String?
    public var hashes: [Hash]
    public var width: Int?
    public var height: Int?
    /// Of audio and video.
    public var duration: Duration?
    public var thumbnails: [Thumbnail]

    public init(
        mediaType: String? = nil, name: String? = nil, size: Int64? = nil, date: Date? = nil,
        description: String? = nil, hashes: [Hash] = [], width: Int? = nil, height: Int? = nil,
        duration: Duration? = nil, thumbnails: [Thumbnail] = []
    ) {
        self.mediaType = mediaType
        self.name = name
        self.size = size
        self.date = date
        self.description = description
        self.hashes = hashes
        self.width = width
        self.height = height
        self.duration = duration
        self.thumbnails = thumbnails
    }

    public static let namespace = "urn:xmpp:file:metadata:0"
    public static let hashNamespace = "urn:xmpp:hashes:2"
    public static let thumbnailNamespace = "urn:xmpp:thumbs:1"

    /// Reads a `<file/>`; nil for another element. Children that cannot be read are left out.
    public init?(element: Element) {
        guard element.name == "file", element.namespace == Self.namespace else { return nil }
        func text(_ name: String) -> String? {
            element.child(name, namespace: Self.namespace)?.trimmedText
        }
        func positive(_ name: String) -> Int64? {
            text(name).flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil }
        }
        mediaType = text("media-type")
        name = text("name")
        size = positive("size")
        date = text("date").flatMap(XMPPDateTime.parse)
        description = text("desc")
        width = positive("width").flatMap { Int(exactly: $0) }
        height = positive("height").flatMap { Int(exactly: $0) }
        duration = positive("length").map { .milliseconds($0) }
        hashes = element.children("hash", namespace: Self.hashNamespace).compactMap { hash in
            guard let algorithm = hash[attribute: "algo"]?.nonEmpty,
                let value = Data(
                    base64Encoded: hash.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                !value.isEmpty
            else { return nil }
            return Hash(algorithm: algorithm, value: value)
        }
        thumbnails = element.children("thumbnail", namespace: Self.thumbnailNamespace).compactMap {
            thumb in
            guard let uri = thumb[attribute: "uri"]?.nonEmpty, Self.isAllowedThumbnail(uri) else {
                return nil
            }
            return Thumbnail(
                uri: uri, mediaType: thumb[attribute: "media-type"],
                width: thumb[attribute: "width"].flatMap { Int($0) },
                height: thumb[attribute: "height"].flatMap { Int($0) })
        }
    }

    static func isAllowedThumbnail(_ uri: String) -> Bool {
        if uri.lowercased().hasPrefix("cid:") { return uri.count > 4 }
        guard let url = URL(string: uri), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// The name a peer sent, made safe to use as a file name (XEP-0446 security): the part after
    /// the last `/` or `\`, without control and format characters (including bidi overrides) or
    /// leading dots, at most 200 characters; "file" when nothing is left. Nil without a name.
    /// Only this, never `name`, may reach the file system.
    public var safeName: String? {
        guard let name else { return nil }
        let base =
            name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let scalars = base.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && $0.properties.generalCategory != .format
                && $0.properties.generalCategory != .lineSeparator
                && $0.properties.generalCategory != .paragraphSeparator
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmed = Substring(cleaned)
        while trimmed.first == "." { trimmed = trimmed.dropFirst() }
        let result = String(trimmed.prefix(200)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "file" : result
    }

    public var element: Element {
        var file = Element("file", namespace: Self.namespace)
        func add(_ name: String, _ value: String?) {
            if let value {
                file.append(Element(name, namespace: Self.namespace, children: [.text(value)]))
            }
        }
        add("media-type", mediaType)
        add("name", name)
        add("date", date.map(XMPPDateTime.string(from:)))
        add("size", size.map(String.init))
        add("width", width.map(String.init))
        add("height", height.map(String.init))
        add(
            "length",
            duration.map {
                String(
                    $0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000
                )
            })
        add("desc", description)
        for hash in hashes {
            file.append(
                Element(
                    "hash", namespace: Self.hashNamespace, attributes: ["algo": hash.algorithm],
                    children: [.text(hash.value.base64EncodedString())]))
        }
        for thumb in thumbnails {
            var element = Element(
                "thumbnail", namespace: Self.thumbnailNamespace, attributes: ["uri": thumb.uri])
            element[attribute: "media-type"] = thumb.mediaType
            element[attribute: "width"] = thumb.width.map(String.init)
            element[attribute: "height"] = thumb.height.map(String.init)
            file.append(element)
        }
        return file
    }
}

/// A XEP-0447 `<file-sharing/>`: a file's metadata and where to get it.
public struct FileSharing: Sendable, Equatable {
    public enum Disposition: String, Sendable {
        case inline, attachment
    }

    public var disposition: Disposition?
    public var id: String?
    public var file: FileMetadata
    /// `https` and `aesgcm` addresses (`url-data`), in the order given.
    public var urls: [URL]

    public init(
        file: FileMetadata, urls: [URL], disposition: Disposition? = nil, id: String? = nil
    ) {
        self.file = file
        self.urls = urls
        self.disposition = disposition
        self.id = id
    }
}

/// XEP-0447 Stateless File Sharing.
public enum StatelessFileSharing {
    public static let namespace = "urn:xmpp:sfs:0"
    public static let urlDataNamespace = "http://jabber.org/protocol/url-data"
    /// Schemes a source may use; others (`file:`, `javascript:`) are dropped.
    static let allowedSchemes: Set<String> = ["https", "aesgcm"]

    /// Reads a `<file-sharing/>` (`ChatMessage.sfs`). Nil without `<file/>`. Sources that are not
    /// `https` or `aesgcm` addresses are left out.
    public static func parse(_ element: Element) -> FileSharing? {
        guard element.name == "file-sharing", element.namespace == namespace,
            let file = element.child("file", namespace: FileMetadata.namespace)
                .flatMap(FileMetadata.init(element:))
        else { return nil }
        let urls =
            (element.child("sources", namespace: namespace)?
            .children("url-data", namespace: urlDataNamespace) ?? []).compactMap { data -> URL? in
                guard let text = data[attribute: "target"], let url = URL(string: text),
                    let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme)
                else { return nil }
                return url
            }
        return FileSharing(
            file: file, urls: urls,
            disposition: element[attribute: "disposition"].flatMap(FileSharing.Disposition.init),
            id: element[attribute: "id"])
    }

    public static func element(_ sharing: FileSharing) -> Element {
        var element = Element("file-sharing", namespace: namespace)
        element[attribute: "disposition"] = sharing.disposition?.rawValue
        element[attribute: "id"] = sharing.id
        element.append(sharing.file.element)
        var sources = Element("sources", namespace: namespace)
        for url in sharing.urls {
            sources.append(
                Element(
                    "url-data", namespace: urlDataNamespace,
                    attributes: ["target": url.absoluteString]))
        }
        element.append(sources)
        return element
    }
}
