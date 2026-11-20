import Foundation
import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite(.serialized) struct HTTPUploadTests {
    static let file = "xep-0363-1.1"
    static let server = try! JID("montague.tld")  // test constant

    @Test func findsServiceAndMaxSize() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "disco-items"),
            for: "http://jabber.org/protocol/disco#items")
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "disco-info-other"),
            for: "http://jabber.org/protocol/disco#info")
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "disco-info"),
            for: "http://jabber.org/protocol/disco#info")
        let found = try await HTTPUpload.findService(server: Self.server, via: sender)
        #expect(found?.0 == (try JID("upload.montague.tld")))
        #expect(found?.maxSize == 5_242_880)
    }

    @Test func noServiceIsNil() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "disco-items"),
            for: "http://jabber.org/protocol/disco#items")
        let found = try await HTTPUpload.findService(server: Self.server, via: sender)
        #expect(found == nil)
    }

    @Test func slotRequestSanitisesFilename() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "slot-result"), for: "request")
        let slot = try await HTTPUpload.requestSlot(
            service: try JID("upload.montague.tld"), filename: "../../etc/très cool.jpg",
            size: 23456,
            contentType: "image/jpeg", via: sender)
        let request = try #require(sender.sent.first?.child("request"))
        #expect(request[attribute: "filename"] == "très cool.jpg")
        #expect(request[attribute: "size"] == "23456")
        #expect(request[attribute: "content-type"] == "image/jpeg")
        #expect(
            slot.headers == [
                "Authorization": "Basic Base64String==", "Cookie": "foo=bar; user=romeo",
            ])
        #expect(slot.put.scheme == "https")
    }

    @Test func filenameEdgeCases() {
        #expect(HTTPUpload.sanitizedFilename("a\\b\\c.txt") == "c.txt")
        #expect(HTTPUpload.sanitizedFilename("..") == "file")
        #expect(HTTPUpload.sanitizedFilename("x\r\ny.txt") == "xy.txt")
        #expect(HTTPUpload.sanitizedFilename("") == "file")
    }

    @Test func headerValuesLoseLineBreaks() throws {
        var slot = Element("slot", namespace: HTTPUpload.namespace)
        var put = Element(
            "put", namespace: HTTPUpload.namespace, attributes: ["url": "https://u.example/a"])
        put.append(
            Element(
                "header", namespace: HTTPUpload.namespace, attributes: ["name": "authorization"],
                children: [.text("a\r\nInjected: 1")]))
        slot.append(put)
        slot.append(
            Element(
                "get", namespace: HTTPUpload.namespace, attributes: ["url": "https://d.example/a"]))
        #expect(try HTTPUpload.slot(from: slot).headers == ["Authorization": "aInjected: 1"])
    }

    @Test func httpURLsAreRefused() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            try ModuleFixtures.stanza(Self.file, "slot-insecure"), for: "request")
        await #expect(throws: HTTPUploadError.insecureURL) {
            _ = try await HTTPUpload.requestSlot(
                service: try JID("upload.montague.tld"), filename: "a", size: 1, contentType: nil,
                via: sender)
        }
        await #expect(throws: HTTPUploadError.invalidSize) {
            _ = try await HTTPUpload.requestSlot(
                service: try JID("upload.montague.tld"), filename: "a", size: 0, contentType: nil,
                via: sender)
        }
    }

    @Test func putRefusesPlainHTTP() async throws {
        let slot = UploadSlot(
            put: try #require(URL(string: "http://u.example/a")),
            get: try #require(URL(string: "https://d.example/a")))
        await #expect(throws: HTTPUploadError.insecureURL) {
            try await HTTPUpload.put(file: URL(fileURLWithPath: "/dev/null"), slot: slot) { _ in }
        }
    }

    @Test func putSendsBodyAndHeaders() async throws {
        let session = StubProtocol.session { request in
            (201, request)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let slot = UploadSlot(
            put: try #require(URL(string: "https://u.example/a")),
            get: try #require(URL(string: "https://d.example/a")),
            headers: ["Authorization": "Basic x", "X-Evil": "no"], contentType: "text/plain")
        let done = ProgressBox()
        try await HTTPUpload.put(
            file: file, slot: slot, contentType: "text/plain", session: session
        ) { done.set($0) }
        #expect(done.value == 1)
        let seen = try #require(StubProtocol.lastRequest())
        #expect(seen.httpMethod == "PUT")
        #expect(seen.value(forHTTPHeaderField: "Authorization") == "Basic x")
        #expect(seen.value(forHTTPHeaderField: "X-Evil") == nil)
        #expect(seen.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    }

    @Test func putRejectsErrorStatus() async throws {
        let session = StubProtocol.session { request in (403, request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let slot = UploadSlot(
            put: try #require(URL(string: "https://u.example/a")),
            get: try #require(URL(string: "https://d.example/a")))
        await #expect(throws: HTTPUploadError.status(403)) {
            try await HTTPUpload.put(file: file, slot: slot, session: session) { _ in }
        }
    }

    @Test func slotRemembersRequestedContentType() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "slot-result"), for: "request")
        let slot = try await HTTPUpload.requestSlot(
            service: try JID("upload.montague.tld"), filename: "a.jpg", size: 5,
            contentType: "image/jpeg", via: sender)
        #expect(slot.contentType == "image/jpeg")
        sender.enqueueResponse(try ModuleFixtures.stanza(Self.file, "slot-result"), for: "request")
        let plain = try await HTTPUpload.requestSlot(
            service: try JID("upload.montague.tld"), filename: "a.bin", size: 5, contentType: nil,
            via: sender)
        #expect(plain.contentType == nil)
    }

    @Test func putSendsTheRequestedContentType() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let put = try #require(URL(string: "https://u.example/a"))
        let get = try #require(URL(string: "https://d.example/a"))
        var slot = UploadSlot(put: put, get: get, contentType: "image/jpeg")
        var session = StubProtocol.session { ($0.url == nil ? 500 : 201, $0) }
        try await HTTPUpload.put(file: file, slot: slot, session: session) { _ in }
        #expect(
            StubProtocol.lastRequest()?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

        slot = UploadSlot(put: put, get: get)
        session = StubProtocol.session { ($0.url == nil ? 500 : 201, $0) }
        try await HTTPUpload.put(file: file, slot: slot, session: session) { _ in }
        #expect(
            StubProtocol.lastRequest()?.value(forHTTPHeaderField: "Content-Type")
                == "application/octet-stream")
    }
}

final class ProgressBox: @unchecked Sendable {  // guarded by the lock
    private let lock = NSLock()
    private var stored = 0.0
    func set(_ v: Double) { lock.withLock { stored = v } }
    var value: Double { lock.withLock { stored } }
}

/// A URLProtocol that answers every request with a status, recording the request.
final class StubProtocol: URLProtocol, @unchecked Sendable {  // static state guarded by the lock
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, URLRequest))?
    nonisolated(unsafe) static var last: URLRequest?
    static let lock = NSLock()

    static func session(_ handler: @escaping @Sendable (URLRequest) -> (Int, URLRequest))
        -> URLSession
    {
        lock.withLock {
            Self.handler = handler
            last = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func lastRequest() -> URLRequest? { lock.withLock { last } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.last = request
            return Self.handler
        }
        let status = handler?(request).0 ?? 500
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: nil,
            headerFields: nil)
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
