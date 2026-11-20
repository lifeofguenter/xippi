import Foundation
import dnssd
import os

/// Looks up `_xmpps-client._tcp` (direct TLS) and `_xmpp-client._tcp` (STARTTLS) for a domain
/// with DNS-SD, both at once, and orders the answers with `EndpointOrdering`.
///
/// A lookup that fails or takes longer than `timeout` counts as "no records", so the domain
/// itself on port 5222 is tried.
public struct DNSSRVResolver: EndpointResolver {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    public func endpoints(for domain: String) async -> [ServerEndpoint] {
        guard Self.isQueryable(domain) else {
            return EndpointOrdering.order(directTLS: [], startTLS: [], domain: domain)
        }
        async let directTLS = Self.lookup("_xmpps-client._tcp.\(domain)", timeout: timeout)
        async let startTLS = Self.lookup("_xmpp-client._tcp.\(domain)", timeout: timeout)
        return EndpointOrdering.order(
            directTLS: await directTLS, startTLS: await startTLS, domain: domain)
    }

    /// A domain that is an ASCII host name: not empty, not an address literal, nothing DNS-SD
    /// would read as an escape. A Unicode domain is not looked up until it is converted to its
    /// A-label form.
    static func isQueryable(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.utf8.count <= 253, domain.unicodeScalars.allSatisfy(\.isASCII)
        else { return false }
        guard
            !domain.unicodeScalars.contains(where: {
                $0 == "[" || $0 == ":" || $0 == "\\" || $0.value <= 0x20
            })
        else { return false }
        return !domain.unicodeScalars.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
    }

    static func lookup(_ name: String, timeout: Duration) async -> [SRVRecord] {
        let query = SRVQuery(name: name, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { query.start($0) }
        } onCancel: {
            query.cancel()
        }
    }
}

/// One DNS-SD query for SRV records, answered once: with every record received, when the answer
/// is complete, negative, failed or late.
///
/// `@unchecked Sendable`: every mutable property is read and written only on `queue`, a serial
/// queue that is also where DNS-SD delivers its callbacks (`DNSServiceSetDispatchQueue`).
private final class SRVQuery: @unchecked Sendable {
    /// More records than any real service publishes; the rest are ignored.
    static let maxRecords = 64

    private let name: String
    private let timeout: Duration
    private let queue = DispatchQueue(label: "eu.xippi.Xippi.srv")
    private var service: DNSServiceRef?
    private var records: [SRVRecord] = []
    private var answered = false
    private var finished = false
    private var continuation: CheckedContinuation<[SRVRecord], Never>?
    /// Keeps the query alive while DNS-SD holds its address as the callback context.
    private var retainedForCallback: Unmanaged<SRVQuery>?

    init(name: String, timeout: Duration) {
        self.name = name
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<[SRVRecord], Never>) {
        queue.async { [self] in
            guard !finished else {
                continuation.resume(returning: [])
                return
            }
            self.continuation = continuation
            let context = Unmanaged.passRetained(self)
            retainedForCallback = context
            var service: DNSServiceRef?
            let status = DNSServiceQueryRecord(
                &service,
                DNSServiceFlags(kDNSServiceFlagsReturnIntermediates),
                0,
                name,
                UInt16(kDNSServiceType_SRV),
                UInt16(kDNSServiceClass_IN),
                { _, flags, _, errorCode, _, rrtype, _, rdlen, rdata, _, context in
                    guard let context else { return }
                    let query = Unmanaged<SRVQuery>.fromOpaque(context).takeUnretainedValue()
                    let data = rdata.map { Data(bytes: $0, count: Int(rdlen)) }
                    query.handle(flags: flags, errorCode: errorCode, rrtype: rrtype, rdata: data)
                },
                context.toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let service else {
                Logger.xmppCore.debug("SRV query not started: \(status)")
                finish()
                return
            }
            self.service = service
            guard DNSServiceSetDispatchQueue(service, queue) == kDNSServiceErr_NoError else {
                finish()
                return
            }
            let (seconds, attoseconds) = timeout.components
            let delay = Double(seconds) + Double(attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            finish()
        }
    }

    private func handle(
        flags: DNSServiceFlags, errorCode: DNSServiceErrorType, rrtype: UInt16, rdata: Data?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        guard errorCode == kDNSServiceErr_NoError else {
            // kDNSServiceErr_NoSuchRecord is the negative answer; anything else is a failure.
            finish()
            return
        }
        if rrtype == UInt16(kDNSServiceType_SRV) {
            answered = true
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata,
                let record = SRVRecord(rdata: rdata),
                records.count < Self.maxRecords
            {
                records.append(record)
            }
        }
        if answered && flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            finish()
        }
    }

    private func finish() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished else { return }
        finished = true
        if let service {
            DNSServiceRefDeallocate(service)
            self.service = nil
        }
        let continuation = continuation
        self.continuation = nil
        retainedForCallback?.release()
        retainedForCallback = nil
        continuation?.resume(returning: records)
    }
}

extension SRVRecord {
    /// Reads SRV record data (RFC 2782): priority, weight and port, then the target as an
    /// uncompressed domain name. Nil when it is malformed, uses compression (RFC 2782 forbids it
    /// for the target), or has a label that is not host name syntax: letters, digits, "-" and
    /// "_" only, so a target can never read as an address literal.
    init?(rdata: Data) {
        let bytes = [UInt8](rdata)
        guard bytes.count >= 7 else { return nil }
        let priority = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let weight = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let port = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        var index = 6
        var labels: [String] = []
        var nameLength = 1
        while true {
            guard index < bytes.count else { return nil }
            let length = Int(bytes[index])
            index += 1
            if length == 0 { break }
            // 64 and above are compression pointers and reserved label types.
            guard length <= 63, index + length <= bytes.count else { return nil }
            nameLength += length + 1
            guard nameLength <= 255 else { return nil }
            let label = bytes[index..<(index + length)]
            guard label.allSatisfy(Self.isHostNameByte) else { return nil }
            labels.append(String(decoding: label, as: UTF8.self))
            index += length
        }
        guard index == bytes.count else { return nil }
        self.init(
            priority: priority, weight: weight, port: port,
            target: labels.isEmpty ? "." : labels.joined(separator: "."))
    }

    private static func isHostNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }
}
