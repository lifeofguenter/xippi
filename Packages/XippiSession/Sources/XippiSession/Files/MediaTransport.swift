import Foundation
import Synchronization
import XMPPCore

/// An HTTP answer whose body arrives in pieces.
public struct MediaResponse: Sendable {
    public var status: Int
    /// The `Content-Type` as the server sent it.
    public var contentType: String?
    /// The `Content-Length`: a hint, never a limit.
    public var announcedLength: Int64?
    /// Ends when the body is through; stopping to read it cancels the request.
    public var body: AsyncThrowingStream<Data, any Error>

    public init(
        status: Int, contentType: String?, announcedLength: Int64?,
        body: AsyncThrowingStream<Data, any Error>
    ) {
        self.status = status
        self.contentType = contentType
        self.announcedLength = announcedLength
        self.body = body
    }
}

public enum MediaTransportError: Error, Equatable {
    /// Not `https`, or redirected to something that is not.
    case insecure
    /// More bytes came than the limit allows.
    case tooLarge
}

/// HTTP for files: the upload of a XEP-0363 slot and downloads. Only `https`.
public protocol MediaTransport: Sendable {
    /// PUTs the file to the slot with the slot's headers. `progress` gets 0...1.
    func upload(file: URL, slot: UploadSlot, progress: @escaping @Sendable (Double) -> Void)
        async throws

    /// GETs `url`. The body stream fails with `.tooLarge` once more than `limit` bytes came,
    /// whatever the server announced.
    func download(_ url: URL, limit: Int64) async throws -> MediaResponse
}

/// `MediaTransport` on URLSession: no cookies, no cache, and redirects only to `https`.
public final class URLSessionMediaTransport: MediaTransport {
    private let session: URLSession
    private let uploads: URLSession
    private let delegate: StreamingDelegate

    /// - Parameter trust: decides on the HTTP servers' certificates for their host names; nil
    ///   leaves it to the system. The app passes nil; the integration tests pass an evaluator
    ///   that also trusts the test CA, as the XMPP stream's does.
    public init(trust: (any TrustEvaluator)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let delegate = StreamingDelegate(trust: trust)
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // A redirected PUT would carry the file and the slot's headers elsewhere: none.
        uploads = URLSession(
            configuration: configuration, delegate: NoRedirects(trust: trust), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        uploads.invalidateAndCancel()
    }

    public func upload(
        file: URL, slot: UploadSlot, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await HTTPUpload.put(file: file, slot: slot, session: uploads, progress: progress)
    }

    public func download(_ url: URL, limit: Int64) async throws -> MediaResponse {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw MediaTransportError.insecure
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        return try await delegate.start(task, limit: limit)
    }
}

/// Refuses every redirect: the 3xx answer itself comes back, and the upload fails with it.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let trust: (any TrustEvaluator)?

    init(trust: (any TrustEvaluator)?) {
        self.trust = trust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await serverTrustAnswer(to: challenge, trust: trust)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Streams data tasks' bodies as they arrive, one entry per task.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct Entry {
        var limit: Int64
        var received: Int64 = 0
        var response: CheckedContinuation<MediaResponse, any Error>?
        var body: AsyncThrowingStream<Data, any Error>.Continuation?
    }

    private let entries = Mutex<[Int: Entry]>([:])
    private let trust: (any TrustEvaluator)?

    init(trust: (any TrustEvaluator)?) {
        self.trust = trust
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await serverTrustAnswer(to: challenge, trust: trust)
    }

    func start(_ task: URLSessionDataTask, limit: Int64) async throws -> MediaResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entries.withLock {
                    $0[task.taskIdentifier] = Entry(limit: limit, response: continuation)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self, throwing: (any Error).self)
        let waiting = entries.withLock {
            entries -> CheckedContinuation<MediaResponse, any Error>? in
            guard var entry = entries[dataTask.taskIdentifier], let waiting = entry.response else {
                return nil
            }
            entry.body = continuation
            entry.response = nil
            entries[dataTask.taskIdentifier] = entry
            return waiting
        }
        guard let waiting else {
            completionHandler(.cancel)
            return
        }
        continuation.onTermination = { _ in dataTask.cancel() }
        let length = response.expectedContentLength
        waiting.resume(
            returning: MediaResponse(
                status: http?.statusCode ?? 0,
                contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                announcedLength: length >= 0 ? length : nil, body: stream))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (body, over) = entries.withLock {
            entries -> (AsyncThrowingStream<Data, any Error>.Continuation?, Bool) in
            guard var entry = entries[dataTask.taskIdentifier] else { return (nil, false) }
            entry.received += Int64(data.count)
            entries[dataTask.taskIdentifier] = entry
            return (entry.body, entry.received > entry.limit)
        }
        if over {
            body?.finish(throwing: MediaTransportError.tooLarge)
            dataTask.cancel()
        } else {
            body?.yield(data)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let entry = entries.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        if let response = entry?.response {
            response.resume(throwing: error ?? URLError(.badServerResponse))
        }
        if let error {
            entry?.body?.finish(throwing: error)
        } else {
            entry?.body?.finish()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }
}

/// The answer to a TLS server-trust challenge: `trust`'s decision on the certificate for the
/// URL's host, or the system's own handling without an evaluator (and for other challenges).
private func serverTrustAnswer(
    to challenge: URLAuthenticationChallenge, trust evaluator: (any TrustEvaluator)?
) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard let evaluator,
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
        let trust = challenge.protectionSpace.serverTrust
    else { return (.performDefaultHandling, nil) }
    switch await evaluator.evaluate(trust, host: challenge.protectionSpace.host) {
    case .trusted: return (.useCredential, URLCredential(trust: trust))
    case .rejected: return (.cancelAuthenticationChallenge, nil)
    }
}
