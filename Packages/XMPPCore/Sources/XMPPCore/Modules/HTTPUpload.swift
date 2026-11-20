import Foundation

/// The place to upload a file to and the address it can be fetched from afterwards.
public struct UploadSlot: Sendable, Equatable {
    public var put: URL
    public var get: URL
    /// Only `Authorization`, `Cookie` and `Expires`, with line breaks removed from the values.
    public var headers: [String: String]
    /// The Content-Type asked for with the slot; `put` sends it, as the service may reject
    /// another one (XEP-0363).
    public var contentType: String?

    public init(
        put: URL, get: URL, headers: [String: String] = [:], contentType: String? = nil
    ) {
        self.put = put
        self.get = get
        self.headers = headers
        self.contentType = contentType
    }
}

public enum HTTPUploadError: Error, Equatable {
    /// The size is zero or negative.
    case invalidSize
    /// The slot has a URL that is not `https`, or none.
    case insecureURL
    /// The upload server answered with this status.
    case status(Int)
}

/// XEP-0363 HTTP File Upload.
public enum HTTPUpload {
    public static let namespace = "urn:xmpp:http:upload:0"

    /// Headers a slot may set; anything else is dropped (XEP-0363 section 4.2).
    static let allowedHeaders = [
        "authorization": "Authorization", "cookie": "Cookie", "expires": "Expires",
    ]

    /// The upload service among the items of `server`, with the largest file it takes
    /// (`max-file-size` of its disco#info form). Items that do not answer are skipped.
    public static func findService(server: JID, via sender: any StanzaSending)
        async throws(IQError) -> (JID, maxSize: Int?)?
    {
        let items = try await Disco.items(server, via: sender)
        for item in items where item.node == nil {
            guard let info = try? await Disco.info(item.jid, via: sender),
                info.features.contains(namespace)
            else { continue }
            let form = info.forms.first { $0.formType == namespace }
            let size = form?.field("max-file-size")?.value.flatMap { Int($0) }
            return (item.jid, size.flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    /// The file name as sent: the last path component, without control characters, at most 200
    /// characters; "file" when nothing is left.
    public static func sanitizedFilename(_ name: String) -> String {
        let last =
            name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(
            String.UnicodeScalarView(
                last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        ).trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "file" }
        return String(cleaned.prefix(200))
    }

    public static func slotRequest(filename: String, size: Int, contentType: String?) -> Element {
        var request = Element(
            "request", namespace: namespace,
            attributes: ["filename": sanitizedFilename(filename), "size": String(size)])
        request[attribute: "content-type"] = contentType?.nonEmpty
        return request
    }

    /// Asks `service` for a slot. Throws `HTTPUploadError.insecureURL` when either URL of the
    /// answer is not `https`.
    public static func requestSlot(
        service: JID, filename: String, size: Int, contentType: String?,
        via sender: any StanzaSending
    ) async throws -> UploadSlot {
        guard size > 0 else { throw HTTPUploadError.invalidSize }
        let request = slotRequest(filename: filename, size: size, contentType: contentType)
        let result = try await sender.request(.iq(type: .get, to: service, payload: request))
        var uploaded = try slot(from: result.resultPayload("slot", namespace: namespace))
        uploaded.contentType = contentType?.nonEmpty
        return uploaded
    }

    /// Reads a `<slot/>`.
    public static func slot(from element: Element) throws -> UploadSlot {
        guard let put = element.child("put", namespace: namespace),
            let putURL = secureURL(put[attribute: "url"]),
            let getURL = secureURL(element.child("get", namespace: namespace)?[attribute: "url"])
        else { throw HTTPUploadError.insecureURL }
        var headers: [String: String] = [:]
        for header in put.children("header", namespace: namespace) {
            guard let name = header[attribute: "name"]?.lowercased(),
                let canonical = allowedHeaders[name]
            else { continue }
            headers[canonical] = withoutLineBreaks(header.text)
        }
        return UploadSlot(put: putURL, get: getURL, headers: headers)
    }

    /// Without CR and LF. Works on scalars: "\r\n" is one Character, so a Character filter keeps it.
    static func withoutLineBreaks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
    }

    static func secureURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Uploads `file` to the slot's PUT address. `progress` gets 0...1 as the body goes out.
    public static func put(
        file: URL, slot: UploadSlot, contentType: String? = nil,
        session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard slot.put.scheme?.lowercased() == "https", slot.get.scheme?.lowercased() == "https"
        else { throw HTTPUploadError.insecureURL }
        var request = URLRequest(url: slot.put)
        request.httpMethod = "PUT"
        request.setValue(
            contentType ?? slot.contentType ?? "application/octet-stream",
            forHTTPHeaderField: "Content-Type")
        for (name, value) in slot.headers where allowedHeaders[name.lowercased()] != nil {
            request.setValue(withoutLineBreaks(value), forHTTPHeaderField: name)
        }
        let delegate = ProgressDelegate(progress)
        let (_, response) = try await session.upload(
            for: request, fromFile: file, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HTTPUploadError.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        progress(1)
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64, totalBytesExpectedToSend: Int64
        ) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}
