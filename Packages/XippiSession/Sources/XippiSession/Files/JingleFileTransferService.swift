import CryptoKit
import Foundation
import Network
import Synchronization
import XMPPCore
import XippiCalls
import os

/// A file a contact offers over Jingle.
public struct FileOffer: Sendable, Equatable {
    public var id: UUID
    public var peer: JID
    /// The name made safe (XEP-0446 rules); "file" when it had none.
    public var name: String
    public var size: Int64
    /// As declared: a hint, not what the file is.
    public var mediaType: String?
}

/// What happens to the account's Jingle file transfers, in order.
public enum FileTransferEvent: Sendable, Equatable {
    /// A contact offers a file: `accept` or `decline` it.
    case offered(FileOffer)
    /// 0...1, at most once per percent.
    case progress(UUID, Double)
    /// Through and checked: the file received (in the media library), or the file sent.
    case completed(UUID, URL)
    /// With a terse reason.
    case failed(UUID, String)
}

public enum FileTransferError: Error, Equatable {
    /// The file cannot be read, or is empty.
    case unreadable
    case tooLarge
    case notConnected
    /// Offers go to a full JID (a device), not to a bare one.
    case needsDevice
    case refused
    case unknownTransfer
}

/// XEP-0234 Jingle file transfer: sending and receiving one file per session, over SOCKS5
/// bytestreams (XEP-0260, direct host candidates only, no proxies) where both sides can reach
/// each other, and In-Band Bytestreams (XEP-0261) otherwise.
///
/// - Sending: the file is copied into the media library and hashed, then offered with its name,
///   size, type and SHA-256. With a listener on this Mac the offer carries SOCKS5 candidates;
///   without one it is IBB from the start.
/// - Receiving: offers only from roster contacts that may see the account's presence (as with
///   calls); others get `service-unavailable` and nothing else. Offers above the largest size,
///   without a size, or more than `maxTransfers` at once are refused. The user accepts or
///   declines each one (`FileTransferEvent.offered`).
/// - SOCKS5: each side connects to the other's candidates for at most 5 s and reports the one
///   it reached (`candidate-used`) or that none worked (`candidate-error`); the higher-priority
///   success wins, on a tie the initiator's choice. When both fail, or no answer comes within
///   15 s, the initiator replaces the transport with IBB (`transport-replace`).
/// - The receiver counts the bytes against the offered size and checks the SHA-256 (from the
///   offer, or a `checksum` that follows within 10 s) before the file is complete; then it
///   ends the session with `success`, otherwise with `media-error`.
public actor JingleFileTransferService {
    static let contentName = "a-file-offer"
    static let blockSize = 4096
    static let chunkSize = 1 << 16
    static let connectTimeout: Duration = .seconds(5)
    static let negotiationTimeout: Duration = .seconds(15)
    static let checksumTimeout: Duration = .seconds(10)
    /// How long a sender waits for the receiver to end the session after the last byte.
    static let answerTimeout: Duration = .seconds(60)
    static let maxTransfers = 16
    /// Connections to our listener that may be in their SOCKS5 handshake at once. A new one
    /// past this closes the oldest of the host that holds the most, so a flood from one host
    /// only ever pushes out its own.
    static let maxPendingHandshakes = 16
    static let directPreference = 126

    let sender: any StanzaSending
    let library: MediaLibrary
    /// The size limit for new offers, sent and received; a transfer under way keeps going.
    private(set) var policy: MediaPolicy
    let network: (any BytestreamNetwork)?
    let clock: any Clock<Duration>
    let isTrustedContact: @Sendable (JID) -> Bool

    /// Every event of every transfer, in order. One consumer.
    public nonisolated let events: AsyncStream<FileTransferEvent>
    private let continuation: AsyncStream<FileTransferEvent>.Continuation

    /// By Jingle session id.
    private var transfers: [String: Transfer] = [:]

    static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    public init(
        sender: any StanzaSending, library: MediaLibrary, policy: MediaPolicy,
        network: (any BytestreamNetwork)?, clock: any Clock<Duration>,
        isTrustedContact: @escaping @Sendable (JID) -> Bool
    ) {
        self.sender = sender
        self.library = library
        self.policy = policy
        self.network = network
        self.clock = clock
        self.isTrustedContact = isTrustedContact
        (events, continuation) = AsyncStream.makeStream(of: FileTransferEvent.self)
    }

    // MARK: State

    enum Phase: Equatable {
        /// Ours: waiting for the peer to accept.
        case initiating
        /// Theirs: waiting for the user.
        case offered
        /// Choosing the transport.
        case negotiating
        case transferring
        /// The bytes are through: checking them, or (sending) waiting for the receiver's end.
        case finishing
    }

    enum Mode: Equatable {
        case socks
        case ibb(blockSize: Int)
    }

    enum CandidateResult: Equatable {
        case used(cid: String)
        case error
    }

    /// One session. Lives on the actor only.
    final class Transfer {
        let id: UUID
        let sid: String
        let peer: JID
        let own: JID
        /// This side sends the file (and initiated the session).
        let sending: Bool
        let file: JingleFileTransferDescription
        let size: Int64
        /// The current transport's sid: a `transport-replace` may bring a new one.
        var transportSID: String
        var phase: Phase
        var mode: Mode
        /// Sending: a private copy of the file, removed when the transfer ends.
        var source: URL?
        /// Sending: the file the user picked, named in `completed`.
        var original: URL?
        /// Receiving: every byte offered is in.
        var bytesComplete = false
        /// The peer ended the session with success after its last byte: nothing more to say.
        var peerEnded = false
        /// Receiving.
        var expectedSHA256: Data?
        var sink: Sink?
        var ibb: IBB.Receiver?
        var checksumWaiter: CheckedContinuation<Data?, Never>?
        var socks: Socks?
        var lastPercent = -1
        var tasks: [Task<Void, Never>] = []

        init(
            id: UUID = UUID(), sid: String, peer: JID, own: JID, sending: Bool,
            file: JingleFileTransferDescription, size: Int64, transportSID: String, phase: Phase,
            mode: Mode
        ) {
            self.id = id
            self.sid = sid
            self.peer = peer
            self.own = own
            self.sending = sending
            self.file = file
            self.size = size
            self.transportSID = transportSID
            self.phase = phase
            self.mode = mode
        }

        var initiator: JID { sending ? own : peer }
    }

    /// The SOCKS5 side of a session.
    final class Socks {
        var listener: (any BytestreamListener)?
        var ours: [SOCKS5Bytestreams.Candidate] = []
        var theirs: [SOCKS5Bytestreams.Candidate] = []
        /// Ours: the peer connected to one of our candidates.
        var incoming: [any ByteChannel] = []
        /// Connections to our listener still in their handshake, and their order of arrival.
        var pending: [UUID: any ByteChannel] = [:]
        var pendingOrder: [UUID] = []

        /// The waiting connection to close for a new one: the oldest of the host that has
        /// the most waiting (on a tie, the host whose oldest came first).
        func evictionVictim() -> UUID? {
            var counts: [String: Int] = [:]
            for key in pendingOrder {
                counts[pending[key]?.remoteHost ?? "", default: 0] += 1
            }
            guard let most = counts.values.max() else { return nil }
            return pendingOrder.first { counts[pending[$0]?.remoteHost ?? ""] == most }
        }
        /// We connected to one of theirs.
        var outgoing: (cid: String, channel: any ByteChannel)?
        var ourResult: CandidateResult?
        var theirResult: CandidateResult?
        var selected: (any ByteChannel)?

        func closeAll() {
            listener?.close()
            for channel in incoming { channel.close() }
            for channel in pending.values { channel.close() }
            pending = [:]
            pendingOrder = []
            outgoing?.channel.close()
            selected?.close()
        }
    }

    /// Where a received file goes while it arrives.
    final class Sink {
        let url: URL
        let handle: FileHandle
        var hasher = SHA256()
        var count: Int64 = 0
        var adopted = false

        init(url: URL) throws {
            self.url = url
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ data: Data) throws {
            hasher.update(data: data)
            try handle.write(contentsOf: data)
            count += Int64(data.count)
        }

        func discard() {
            try? handle.close()
            if !adopted { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Sending

    /// Offers `file` to the device `peer`. Returns the transfer's id once the peer has the
    /// offer; what follows comes as events.
    @discardableResult
    public func send(file: URL, to peer: JID) async throws(FileTransferError) -> UUID {
        guard !peer.isBare else { throw .needsDevice }
        guard let own = await sender.boundJID else { throw .notConnected }
        let imported: (url: URL, sha256: Data, size: Int64)
        do {
            imported = try library.copyToTemporary(file)
        } catch {
            throw .unreadable
        }
        guard imported.size > 0, imported.size <= policy.maximumSize else {
            try? FileManager.default.removeItem(at: imported.url)
            throw imported.size > 0 ? .tooLarge : .unreadable
        }
        let name = HTTPUpload.sanitizedFilename(file.lastPathComponent)
        let description = JingleFileTransferDescription(
            name: name, mediaType: MediaLibrary.mediaType(forExtension: file.pathExtension),
            size: UInt64(imported.size),
            hashes: [.init(algorithm: "sha-256", value: imported.sha256)])
        let sid = String.stanzaID()
        let transportSID = String.stanzaID()
        var transportElement = IBB.Transport(sid: transportSID, blockSize: Self.blockSize).element
        var mode = Mode.ibb(blockSize: Self.blockSize)
        var socks: Socks?
        if let network, let listener = await network.listen(), !listener.addresses.isEmpty {
            let state = Socks()
            state.listener = listener
            state.ours = Self.candidates(for: listener, own: own)
            transportElement =
                SOCKS5Bytestreams.Transport(
                    sid: transportSID,
                    dstaddr: SOCKS5Bytestreams.destinationAddress(
                        sid: transportSID, candidateOwner: own, peer: peer),
                    candidates: state.ours
                ).element
            mode = .socks
            socks = state
        }
        let transfer = Transfer(
            sid: sid, peer: peer, own: own, sending: true, file: description,
            size: imported.size, transportSID: transportSID, phase: .initiating, mode: mode)
        transfer.source = imported.url
        transfer.original = file
        transfer.socks = socks
        transfers[sid] = transfer
        if let socks, let listener = socks.listener { listen(sid, listener) }
        let initiate = JingleIQ(
            action: .sessionInitiate, sid: sid, initiator: own,
            contents: [
                JingleContent(
                    creator: JingleRole.initiator.rawValue, name: Self.contentName,
                    senders: JingleRole.initiator.rawValue, description: description.element,
                    transport: transportElement)
            ])
        do {
            _ = try await sender.request(.iq(type: .set, to: peer, payload: initiate.element))
        } catch {
            end(sid)
            throw error == .notConnected || error == .sessionEnded ? .notConnected : .refused
        }
        return transfer.id
    }

    /// Accepts an offer: the file starts to come.
    public func accept(_ id: UUID) async throws(FileTransferError) {
        guard let transfer = transfer(id), !transfer.sending, transfer.phase == .offered else {
            throw .unknownTransfer
        }
        let temporary: URL
        do {
            temporary = try library.temporaryFile()
            transfer.sink = try Sink(url: temporary)
        } catch {
            fail(transfer.sid, "Cannot store the file", condition: "general-error")
            throw .unreadable
        }
        transfer.phase = .negotiating
        let transportElement: Element
        switch transfer.mode {
        case .ibb(let blockSize):
            transportElement =
                IBB.Transport(sid: transfer.transportSID, blockSize: blockSize)
                .element
        case .socks:
            let socks = transfer.socks ?? Socks()
            transfer.socks = socks
            if let network, let listener = await network.listen() {
                // The transfer may have ended while the listener started.
                guard transfers[transfer.sid] === transfer else {
                    listener.close()
                    throw .unknownTransfer
                }
                socks.listener = listener
                socks.ours = Self.candidates(for: listener, own: transfer.own)
                listen(transfer.sid, listener)
            }
            transportElement =
                SOCKS5Bytestreams.Transport(
                    sid: transfer.transportSID,
                    dstaddr: SOCKS5Bytestreams.destinationAddress(
                        sid: transfer.transportSID, candidateOwner: transfer.own,
                        peer: transfer.peer),
                    candidates: socks.ours
                ).element
        }
        let accept = JingleIQ(
            action: .sessionAccept, sid: transfer.sid, initiator: transfer.peer,
            responder: transfer.own,
            contents: [
                JingleContent(
                    creator: JingleRole.initiator.rawValue, name: Self.contentName,
                    senders: JingleRole.initiator.rawValue, description: transfer.file.element,
                    transport: transportElement)
            ])
        do {
            _ = try await sender.request(
                .iq(type: .set, to: transfer.peer, payload: accept.element))
        } catch {
            fail(transfer.sid, "No answer", condition: nil)
            throw .refused
        }
        if case .socks = transfer.mode { connectToTheirs(transfer.sid) }
    }

    /// Declines an offer, with the reason `condition` (XEP-0166: `decline`, or `timeout` for
    /// one nobody answered). It ends here at once; the peer is told without waiting for it.
    public func decline(_ id: UUID, condition: String = "decline") {
        guard let transfer = transfer(id), transfer.phase == .offered else { return }
        notify(transfer, condition: condition)
        end(transfer.sid)
    }

    /// Stops a transfer in either direction. It stops here at once (nothing more is read,
    /// written or kept); the peer is told without waiting for it.
    public func cancel(_ id: UUID) {
        guard let transfer = transfer(id) else { return }
        continuation.yield(.failed(transfer.id, "Cancelled"))
        notify(transfer, condition: "cancel")
        end(transfer.sid)
    }

    /// A changed size limit: it applies from the next offer on.
    func setPolicy(_ policy: MediaPolicy) {
        self.policy = policy
    }

    /// The session is gone: every transfer ends.
    func sessionEnded() {
        for transfer in transfers.values {
            continuation.yield(.failed(transfer.id, "Disconnected"))
            end(transfer.sid)
        }
    }

    private func transfer(_ id: UUID) -> Transfer? {
        transfers.values.first { $0.id == id }
    }

    // MARK: Jingle

    /// A Jingle IQ: the reply for this service's sessions and for file offers; nil for
    /// anything else (calls), which the router hands on.
    public func handle(jingle iq: Element) async -> Element? {
        guard iq.name == "iq", iq.type == IQType.set.rawValue,
            let jingle = JingleIQ(element: iq), let from = iq.from
        else { return nil }
        guard let transfer = transfers[jingle.sid] else {
            guard jingle.action == .sessionInitiate,
                jingle.contents.contains(where: {
                    $0.description?.namespace == JingleNamespace.fileTransfer
                })
            else { return nil }
            return offered(iq, jingle, from: from)
        }
        guard transfer.peer == from else { return nil }
        switch jingle.action {
        case .sessionAccept:
            return accepted(iq, jingle, transfer)
        case .sessionTerminate:
            terminated(jingle, transfer)
            return iq.iqResult()
        case .sessionInfo:
            return info(iq, jingle, transfer)
        case .transportInfo:
            return transportInfo(iq, jingle, transfer)
        case .transportReplace:
            return replaced(iq, jingle, transfer)
        case .transportAccept:
            guard transfer.sending, case .ibb = transfer.mode, transfer.phase == .negotiating
            else { return Self.outOfOrder(iq) }
            startIBB(transfer.sid)
            return iq.iqResult()
        case .transportReject:
            fail(transfer.sid, "No transport", condition: "failed-transport")
            return iq.iqResult()
        default:
            return Self.error(iq, .cancel, .featureNotImplemented)
        }
    }

    private func offered(_ iq: Element, _ jingle: JingleIQ, from: JID) -> Element {
        // Strangers learn nothing from an answer: they get what any unhandled request gets.
        guard !from.isBare, isTrustedContact(from.bare) else {
            Self.log.info("File offer refused: not a contact")
            return Self.error(iq, .cancel, .serviceUnavailable)
        }
        guard transfers.count < Self.maxTransfers else {
            return Self.error(iq, .wait, .resourceConstraint)
        }
        guard jingle.contents.count == 1, let content = jingle.contents.first,
            content.senders == nil || content.senders == JingleRole.initiator.rawValue,
            let description = content.description.flatMap(
                JingleFileTransferDescription.init(element:)),
            let transport = content.transport
        else { return Self.error(iq, .modify, .badRequest) }
        guard let size = description.size, size > 0, size <= UInt64(policy.maximumSize) else {
            return Self.error(iq, .modify, .notAcceptable)
        }
        let mode: Mode
        let transportSID: String
        var socks: Socks?
        if let ibb = IBB.Transport(element: transport) {
            mode = .ibb(blockSize: min(ibb.blockSize, Self.blockSize))
            transportSID = ibb.sid
        } else if let offer = SOCKS5Bytestreams.Transport(element: transport), offer.mode == .tcp {
            mode = .socks
            transportSID = offer.sid
            let state = Socks()
            state.theirs = offer.candidates.filter { $0.type == .direct }
            socks = state
        } else {
            return Self.error(iq, .cancel, .featureNotImplemented)
        }
        guard let own = iq.to, !own.isBare else { return Self.error(iq, .modify, .badRequest) }
        let transfer = Transfer(
            sid: jingle.sid, peer: from, own: own, sending: false, file: description,
            size: Int64(size), transportSID: transportSID, phase: .offered, mode: mode)
        transfer.expectedSHA256 = Self.sha256(in: description)
        transfer.socks = socks
        transfers[jingle.sid] = transfer
        continuation.yield(
            .offered(
                FileOffer(
                    id: transfer.id, peer: from,
                    name: MediaLibrary.safeName(description.name) ?? "file", size: Int64(size),
                    mediaType: MediaLibrary.mediaType(description.mediaType))))
        return iq.iqResult()
    }

    private func accepted(_ iq: Element, _ jingle: JingleIQ, _ transfer: Transfer) -> Element {
        guard transfer.sending, transfer.phase == .initiating,
            let transport = jingle.contents.first?.transport
        else { return Self.outOfOrder(iq) }
        transfer.phase = .negotiating
        switch transfer.mode {
        case .ibb:
            guard let answer = IBB.Transport(element: transport),
                answer.sid == transfer.transportSID
            else {
                fail(transfer.sid, "No transport", condition: "failed-transport")
                return iq.iqResult()
            }
            transfer.mode = .ibb(blockSize: min(answer.blockSize, Self.blockSize))
            startIBB(transfer.sid)
        case .socks:
            guard let answer = SOCKS5Bytestreams.Transport(element: transport),
                answer.sid == transfer.transportSID, let socks = transfer.socks
            else {
                fail(transfer.sid, "No transport", condition: "failed-transport")
                return iq.iqResult()
            }
            socks.theirs = answer.candidates.filter { $0.type == .direct }
            connectToTheirs(transfer.sid)
            let sid = transfer.sid
            transfer.tasks.append(
                Task { [clock] in
                    try? await sleep(on: clock, for: Self.negotiationTimeout)
                    self.negotiationTimedOut(sid)
                })
        }
        return iq.iqResult()
    }

    private func terminated(_ jingle: JingleIQ, _ transfer: Transfer) {
        let condition = jingle.reason?.condition ?? "success"
        if !transfer.sending, condition == "success",
            transfer.phase == .transferring || transfer.phase == .finishing
                || transfer.bytesComplete
        {
            // Some senders end the session after their last byte: the file is still checked
            // here, and the session needs no other end.
            transfer.peerEnded = true
            if case .ibb = transfer.mode, transfer.phase == .transferring {
                let sid = transfer.sid
                if transfer.sink?.count == transfer.size {
                    transfer.tasks.append(Task { await self.bytesReceived(sid) })
                } else {
                    continuation.yield(.failed(transfer.id, "Incomplete"))
                    end(sid)
                }
            }
            return
        }
        // A receiver that ends with success has the file checked; before any byte moved, a
        // success says nothing.
        if transfer.sending, condition == "success", let original = transfer.original,
            transfer.phase == .transferring || transfer.phase == .finishing
        {
            continuation.yield(.completed(transfer.id, original))
        } else {
            continuation.yield(.failed(transfer.id, Self.text(for: condition)))
        }
        end(transfer.sid)
    }

    private func info(_ iq: Element, _ jingle: JingleIQ, _ transfer: Transfer) -> Element {
        if let checksum = jingle.info.first(where: {
            $0.name == "checksum" && $0.namespace == JingleNamespace.fileTransfer
        }) {
            guard !transfer.sending,
                let file = checksum.child("file", namespace: JingleNamespace.fileTransfer)
                    .flatMap(JingleFileTransferDescription.init(file:))
            else { return Self.error(iq, .modify, .badRequest) }
            if transfer.expectedSHA256 == nil, let hash = Self.sha256(in: file) {
                transfer.expectedSHA256 = hash
                transfer.checksumWaiter?.resume(returning: hash)
                transfer.checksumWaiter = nil
            }
            return iq.iqResult()
        }
        if jingle.info.isEmpty
            || jingle.info.contains(where: {
                $0.name == "received" && $0.namespace == JingleNamespace.fileTransfer
            })
        {
            return iq.iqResult()
        }
        return Self.error(iq, .modify, .featureNotImplemented, jingle: "unsupported-info")
    }

    // MARK: SOCKS5

    static func candidates(for listener: any BytestreamListener, own: JID)
        -> [SOCKS5Bytestreams.Candidate]
    {
        listener.addresses.enumerated().map { index, address in
            SOCKS5Bytestreams.Candidate(
                cid: String.stanzaID(), jid: own, host: address.host, port: address.port,
                priority: (directPreference << 16) + max(0, 65_535 - index), type: .direct)
        }
    }

    /// Takes the peer's connections to our candidates: a connection must name this transfer's
    /// destination address within 5 s, before anything else is done for it. One that names
    /// another is closed at once; one that says nothing is closed after 5 s; with
    /// `maxPendingHandshakes` waiting, a new one closes the oldest of the host holding the
    /// most; a closed (evicted) one is never taken afterwards; every one still waiting is
    /// closed when the transfer ends.
    private func listen(_ sid: String, _ listener: any BytestreamListener) {
        guard let transfer = transfers[sid] else { return }
        let destination = SOCKS5Bytestreams.destinationAddress(
            sid: transfer.transportSID, candidateOwner: transfer.own, peer: transfer.peer)
        let clock = self.clock
        transfer.tasks.append(
            Task {
                for await channel in listener.connections {
                    guard let socks = self.transfers[sid]?.socks else {
                        channel.close()
                        continue
                    }
                    if socks.pending.count >= Self.maxPendingHandshakes,
                        let victim = socks.evictionVictim()
                    {
                        socks.pendingOrder.removeAll { $0 == victim }
                        socks.pending.removeValue(forKey: victim)?.close()
                    }
                    let key = UUID()
                    socks.pending[key] = channel
                    socks.pendingOrder.append(key)
                    Task {
                        // What it asks for first, within 5 s.
                        let named = await Self.first(within: Self.connectTimeout, on: clock) {
                            () async -> String? in
                            try? await SOCKS5Handshake.request(from: channel)
                        }
                        await self.handshakeEnded(
                            sid, key: key, channel: channel, named: named, expected: destination)
                    }
                }
            })
    }

    private func handshakeEnded(
        _ sid: String, key: UUID, channel: any ByteChannel, named: String?, expected: String
    ) async {
        // One closed meanwhile (evicted, or the transfer ended) is never taken.
        guard let socks = transfers[sid]?.socks, socks.pending.removeValue(forKey: key) != nil
        else {
            channel.close()
            return
        }
        socks.pendingOrder.removeAll { $0 == key }
        guard let named, named == expected else {
            channel.close()
            return
        }
        do {
            try await SOCKS5Handshake.confirm(channel, destination: named)
        } catch {
            channel.close()
            return
        }
        incoming(sid, channel)
    }

    private func incoming(_ sid: String, _ channel: any ByteChannel) {
        guard let socks = transfers[sid]?.socks, socks.selected == nil else {
            channel.close()
            return
        }
        socks.incoming.append(channel)
        decide(sid)
    }

    /// Tries the peer's candidates, best first, each for at most 5 s (connection and SOCKS5
    /// handshake, a candidate that accepts and then says nothing included), and says which one
    /// worked. Only IP addresses outside loopback, link-local and multicast are dialled.
    private func connectToTheirs(_ sid: String) {
        guard let transfer = transfers[sid], let socks = transfer.socks else { return }
        let candidates = socks.theirs.sorted { $0.priority > $1.priority }
            .filter { Self.isDialable($0.host) }
        let destination = SOCKS5Bytestreams.destinationAddress(
            sid: transfer.transportSID, candidateOwner: transfer.peer, peer: transfer.own)
        let network = self.network
        let clock = self.clock
        transfer.tasks.append(
            Task {
                var reached: Reached?
                if let network {
                    for candidate in candidates where !Task.isCancelled {
                        reached = await Self.first(
                            within: Self.connectTimeout, on: clock,
                            discard: { $0.channel.close() }
                        ) { () async -> Reached? in
                            guard
                                let channel = try? await network.connect(
                                    to: HostPort(host: candidate.host, port: candidate.port))
                            else { return nil }
                            do {
                                try await SOCKS5Handshake.connect(channel, destination: destination)
                            } catch {
                                channel.close()
                                return nil
                            }
                            guard !Task.isCancelled else {
                                channel.close()
                                return nil
                            }
                            return Reached(cid: candidate.cid, channel: channel)
                        }
                        if reached != nil { break }
                    }
                }
                await self.connected(sid, reached)
            })
    }

    /// An address a peer may make us dial: an IP literal (no name to look up on the peer's
    /// behalf), not loopback, unspecified, link-local, multicast or broadcast.
    static func isDialable(_ host: String) -> Bool {
        // A zone or scope names one of our interfaces: no candidate of the peer's has one.
        guard !host.contains("%") else { return false }
        if let address = IPv4Address(host), address.interface == nil {
            return isDialable(ipv4: [UInt8](address.rawValue))
        }
        if let address = IPv6Address(host), address.interface == nil {
            return isDialable(ipv6: [UInt8](address.rawValue))
        }
        return false
    }

    /// By the bytes: not 0/8 (this network), 127/8 (loopback), 169.254/16 (link-local), nor
    /// 224/4 and above (multicast, reserved, broadcast).
    static func isDialable(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        if bytes[0] == 0 || bytes[0] == 127 { return false }
        if bytes[0] == 169 && bytes[1] == 254 { return false }
        return bytes[0] < 224
    }

    /// By the bytes: not ::/96 (unspecified, loopback, IPv4-compatible), ::ffff:0:0/96
    /// (IPv4-mapped), ::ffff:0:0:0/96 (IPv4-translated), fe80::/10 (link-local) nor ff00::/8
    /// (multicast). An IPv4 peer gives its IPv4 address.
    static func isDialable(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return false
        }
        if bytes[0..<8].allSatisfy({ $0 == 0 }), bytes[8] == 0xFF, bytes[9] == 0xFF,
            bytes[10] == 0, bytes[11] == 0
        {
            return false
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
        return bytes[0] != 0xFF
    }

    struct Reached: Sendable {
        var cid: String
        var channel: any ByteChannel
    }

    /// The value of `work`, or nil when it takes longer than `limit` (then `work` is
    /// cancelled, and a value it still produces goes to `discard`).
    static func first<T: Sendable>(
        within limit: Duration, on clock: any Clock<Duration>,
        discard: @escaping @Sendable (T) -> Void = { _ in },
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        let race = Race<T>()
        let worker = Task {
            let value = await work()
            if !race.finish(value), let value { discard(value) }
        }
        let timer = Task {
            try? await sleep(on: clock, for: limit)
            if race.finish(nil) { worker.cancel() }
        }
        // The deadline does not wait for `work` to notice its cancellation.
        let result = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            if race.finish(nil) { worker.cancel() }
        }
        timer.cancel()
        return result
    }

    /// The first of a value and a deadline, taken once.
    final class Race<T: Sendable>: Sendable {
        private struct State {
            var result: T??
            var waiter: CheckedContinuation<T?, Never>?
        }

        private let state = Mutex(State())

        /// Settles the race with `value`; false when it was settled already.
        func finish(_ value: T?) -> Bool {
            let (won, waiter) = state.withLock { state -> (Bool, CheckedContinuation<T?, Never>?) in
                guard state.result == nil else { return (false, nil) }
                state.result = .some(value)
                defer { state.waiter = nil }
                return (true, state.waiter)
            }
            waiter?.resume(returning: value)
            return won
        }

        func value() async -> T? {
            await withCheckedContinuation { continuation in
                let settled = state.withLock { state -> T?? in
                    if let result = state.result { return .some(result) }
                    state.waiter = continuation
                    return nil
                }
                if let settled { continuation.resume(returning: settled) }
            }
        }
    }

    private func connected(_ sid: String, _ reached: Reached?) async {
        guard let transfer = transfers[sid], let socks = transfer.socks, case .socks = transfer.mode
        else {
            reached?.channel.close()
            return
        }
        let info: SOCKS5Bytestreams.Transport.Info
        if let reached {
            socks.outgoing = (reached.cid, reached.channel)
            socks.ourResult = .used(cid: reached.cid)
            info = .candidateUsed(cid: reached.cid)
        } else {
            socks.ourResult = .error
            info = .candidateError
        }
        let message = JingleIQ(
            action: .transportInfo, sid: sid, initiator: transfer.initiator,
            contents: [
                JingleContent(
                    creator: JingleRole.initiator.rawValue, name: Self.contentName,
                    transport: SOCKS5Bytestreams.Transport(sid: transfer.transportSID, info: info)
                        .element)
            ])
        decide(sid)
        do {
            _ = try await sender.request(
                .iq(type: .set, to: transfer.peer, payload: message.element))
        } catch {
            fail(sid, "No answer", condition: nil)
        }
    }

    private func transportInfo(_ iq: Element, _ jingle: JingleIQ, _ transfer: Transfer) -> Element {
        guard let socks = transfer.socks, case .socks = transfer.mode,
            let element = jingle.contents.first?.transport,
            let transport = SOCKS5Bytestreams.Transport(element: element),
            transport.sid == transfer.transportSID
        else { return Self.outOfOrder(iq) }
        switch transport.info {
        case .candidateUsed(let cid):
            // Only one of our own candidates can have been used.
            socks.theirResult =
                socks.ours.contains(where: { $0.cid == cid }) ? .used(cid: cid) : .error
        case .candidateError:
            socks.theirResult = .error
        case .activated, .proxyError, nil:
            return iq.iqResult()
        }
        decide(transfer.sid)
        return iq.iqResult()
    }

    /// Once both sides said what they reached: the bytestream to use, or IBB.
    private func decide(_ sid: String) {
        guard let transfer = transfers[sid], let socks = transfer.socks,
            case .socks = transfer.mode,
            socks.selected == nil, let ours = socks.ourResult, let theirs = socks.theirResult
        else { return }
        let useOutgoing: Bool
        switch (ours, theirs) {
        case (.error, .error):
            fallBack(sid)
            return
        case (.used, .error):
            useOutgoing = true
        case (.error, .used):
            useOutgoing = false
        case (.used(let reached), .used(let used)):
            let outgoingPriority = socks.theirs.first { $0.cid == reached }?.priority ?? 0
            let incomingPriority = socks.ours.first { $0.cid == used }?.priority ?? 0
            if outgoingPriority != incomingPriority {
                useOutgoing = outgoingPriority > incomingPriority
            } else {
                // A tie goes to the initiator's choice: the candidate it reached.
                useOutgoing = transfer.sending
            }
        }
        let channel: any ByteChannel
        if useOutgoing {
            guard let outgoing = socks.outgoing?.channel else { return }
            channel = outgoing
            for other in socks.incoming { other.close() }
        } else {
            // The peer's connection may still be in its handshake: wait for it.
            guard let incoming = socks.incoming.first else { return }
            channel = incoming
            for other in socks.incoming.dropFirst() { other.close() }
            socks.outgoing?.channel.close()
        }
        socks.incoming = []
        socks.outgoing = nil
        socks.selected = channel
        socks.listener?.close()
        socks.listener = nil
        transfer.phase = .transferring
        if transfer.sending {
            sendBytes(sid, over: channel)
        } else {
            receiveBytes(sid, from: channel)
        }
    }

    private func negotiationTimedOut(_ sid: String) {
        guard let transfer = transfers[sid], transfer.phase == .negotiating,
            case .socks = transfer.mode
        else { return }
        fallBack(sid)
    }

    /// No direct connection: the initiator switches to IBB (XEP-0260 section 2.6).
    private func fallBack(_ sid: String) {
        guard let transfer = transfers[sid], transfer.sending else { return }
        transfer.socks?.closeAll()
        transfer.socks = nil
        transfer.mode = .ibb(blockSize: Self.blockSize)
        transfer.phase = .negotiating
        let replace = JingleIQ(
            action: .transportReplace, sid: sid, initiator: transfer.own,
            contents: [
                JingleContent(
                    creator: JingleRole.initiator.rawValue, name: Self.contentName,
                    transport: IBB.Transport(sid: transfer.transportSID, blockSize: Self.blockSize)
                        .element)
            ])
        let peer = transfer.peer
        let sender = self.sender
        transfer.tasks.append(
            Task {
                do {
                    _ = try await sender.request(
                        .iq(type: .set, to: peer, payload: replace.element))
                } catch {
                    self.fail(sid, "No transport", condition: "failed-transport")
                }
            })
    }

    /// The initiator switched to IBB: the responder takes it.
    private func replaced(_ iq: Element, _ jingle: JingleIQ, _ transfer: Transfer) -> Element {
        guard !transfer.sending, let element = jingle.contents.first?.transport,
            let ibb = IBB.Transport(element: element)
        else { return Self.error(iq, .modify, .badRequest) }
        transfer.socks?.closeAll()
        transfer.socks = nil
        let blockSize = min(ibb.blockSize, Self.blockSize)
        transfer.mode = .ibb(blockSize: blockSize)
        transfer.phase = .negotiating
        // The replacing transport may bring its own sid (XEP-0260 2.6, XEP-0261).
        transfer.transportSID = ibb.sid
        let answer = JingleIQ(
            action: .transportAccept, sid: transfer.sid, initiator: transfer.peer,
            responder: transfer.own,
            contents: [
                JingleContent(
                    creator: JingleRole.initiator.rawValue, name: Self.contentName,
                    transport: IBB.Transport(sid: ibb.sid, blockSize: blockSize).element)
            ])
        let peer = transfer.peer
        let sender = self.sender
        let sid = transfer.sid
        transfer.tasks.append(
            Task {
                do {
                    _ = try await sender.request(.iq(type: .set, to: peer, payload: answer.element))
                } catch {
                    self.fail(sid, "No answer", condition: nil)
                }
            })
        return iq.iqResult()
    }

    // MARK: Moving bytes

    private func sendBytes(_ sid: String, over channel: any ByteChannel) {
        guard let transfer = transfers[sid], let source = transfer.source else { return }
        let id = transfer.id
        let size = transfer.size
        transfer.tasks.append(
            Task {
                do {
                    let input = try FileHandle(forReadingFrom: source)
                    defer { try? input.close() }
                    var sent: Int64 = 0
                    while let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                        try Task.checkCancellation()
                        try await channel.send(chunk)
                        sent += Int64(chunk.count)
                        self.progress(id: id, sid: sid, done: sent, of: size)
                    }
                    self.bytesSent(sid)
                } catch {
                    self.fail(sid, "Transfer failed", condition: "failed-transport")
                }
            })
    }

    private func receiveBytes(_ sid: String, from channel: any ByteChannel) {
        guard let transfer = transfers[sid] else { return }
        let size = transfer.size
        transfer.tasks.append(
            Task {
                var received: Int64 = 0
                do {
                    while received < size {
                        try Task.checkCancellation()
                        let chunk = try await channel.receive(
                            maximum: Int(min(Int64(Self.chunkSize), size - received)))
                        guard !chunk.isEmpty else { break }
                        received += Int64(chunk.count)
                        guard self.store(sid, chunk) else { return }
                    }
                } catch {
                    self.fail(sid, "Transfer failed", condition: "failed-transport")
                    return
                }
                await self.bytesReceived(sid)
            })
    }

    private func bytesSent(_ sid: String) {
        guard let transfer = transfers[sid] else { return }
        // The receiver checks the file and ends the session; one that never does fails it.
        transfer.phase = .finishing
        let clock = self.clock
        transfer.tasks.append(
            Task {
                try? await sleep(on: clock, for: Self.answerTimeout)
                self.unanswered(sid)
            })
    }

    private func unanswered(_ sid: String) {
        guard let transfer = transfers[sid], transfer.sending, transfer.phase == .finishing else {
            return
        }
        fail(sid, "No answer", condition: "timeout")
    }

    /// Writes received bytes; false when they are more than offered (the transfer then fails).
    private func store(_ sid: String, _ data: Data) -> Bool {
        guard let transfer = transfers[sid], let sink = transfer.sink else { return false }
        guard sink.count + Int64(data.count) <= transfer.size else {
            fail(sid, "More data than offered", condition: "media-error")
            return false
        }
        do {
            try sink.append(data)
        } catch {
            fail(sid, "Cannot store the file", condition: "general-error")
            return false
        }
        progress(id: transfer.id, sid: sid, done: sink.count, of: transfer.size)
        return true
    }

    private func progress(id: UUID, sid: String, done: Int64, of size: Int64) {
        guard let transfer = transfers[sid], size > 0 else { return }
        let percent = Int(done * 100 / size)
        guard percent != transfer.lastPercent else { return }
        transfer.lastPercent = percent
        continuation.yield(.progress(id, Double(done) / Double(size)))
    }

    /// Every byte is in: checks size and SHA-256, then keeps the file and ends the session.
    private func bytesReceived(_ sid: String) async {
        guard let transfer = transfers[sid], let sink = transfer.sink,
            transfer.phase != .finishing
        else { return }
        transfer.phase = .finishing
        transfer.bytesComplete = true
        guard sink.count == transfer.size else {
            await finish(sid, failure: "Incomplete", condition: "media-error")
            return
        }
        let computed = Data(sink.hasher.finalize())
        var expected = transfer.expectedSHA256
        if expected == nil {
            expected = await checksum(sid)
        }
        guard transfers[sid] != nil else { return }
        guard let expected else {
            await finish(sid, failure: "Not verified", condition: "media-error")
            return
        }
        guard expected == computed else {
            await finish(sid, failure: "Checksum mismatch", condition: "media-error")
            return
        }
        do {
            try sink.handle.close()
            let url = try library.adopt(sink.url, sha256: computed)
            sink.adopted = true
            continuation.yield(.completed(transfer.id, url))
        } catch {
            await finish(sid, failure: "Cannot store the file", condition: "general-error")
            return
        }
        if !transfer.peerEnded { await terminate(transfer, condition: "success") }
        end(sid)
    }

    /// A checksum the sender sends after the bytes, for at most 10 s.
    private func checksum(_ sid: String) async -> Data? {
        guard let transfer = transfers[sid] else { return nil }
        let clock = self.clock
        let timer = Task {
            try? await sleep(on: clock, for: Self.checksumTimeout)
            self.checksumTimedOut(sid)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if let hash = transfer.expectedSHA256 {
                continuation.resume(returning: hash)
            } else {
                transfer.checksumWaiter = continuation
            }
        }
    }

    private func checksumTimedOut(_ sid: String) {
        guard let transfer = transfers[sid] else { return }
        transfer.checksumWaiter?.resume(returning: nil)
        transfer.checksumWaiter = nil
    }

    private func finish(_ sid: String, failure: String, condition: String) async {
        guard let transfer = transfers[sid] else { return }
        continuation.yield(.failed(transfer.id, failure))
        if !transfer.peerEnded { await terminate(transfer, condition: condition) }
        end(sid)
    }

    // MARK: IBB

    private func startIBB(_ sid: String) {
        guard let transfer = transfers[sid], transfer.sending, let source = transfer.source,
            case .ibb(let blockSize) = transfer.mode
        else { return }
        transfer.phase = .transferring
        let peer = transfer.peer
        let transportSID = transfer.transportSID
        let id = transfer.id
        let size = transfer.size
        let sender = self.sender
        transfer.tasks.append(
            Task {
                do {
                    try await IBB.open(
                        to: peer, sid: transportSID, blockSize: blockSize, via: sender)
                    let input = try FileHandle(forReadingFrom: source)
                    defer { try? input.close() }
                    var sequence: UInt16 = 0
                    var sent: Int64 = 0
                    while let block = try input.read(upToCount: blockSize), !block.isEmpty {
                        try Task.checkCancellation()
                        _ = try await sender.request(
                            .iq(
                                type: .set, to: peer,
                                payload: IBB.data(
                                    sid: transportSID, sequence: sequence, bytes: block)))
                        sequence = IBB.next(after: sequence)
                        sent += Int64(block.count)
                        self.progress(id: id, sid: sid, done: sent, of: size)
                    }
                    try await IBB.close(to: peer, sid: transportSID, via: sender)
                    self.bytesSent(sid)
                } catch {
                    self.fail(sid, "Transfer failed", condition: "failed-transport")
                }
            })
    }

    /// An IBB request (XEP-0047): only for a transfer of the sender's that was accepted.
    public func handle(ibb iq: Element) async -> Element? {
        guard iq.name == "iq", iq.type == IQType.set.rawValue, let from = iq.from,
            let payload = iq.elements.first
        else { return nil }
        switch payload.name {
        case "open":
            guard let open = IBB.parseOpen(payload),
                let transfer = receiving(transportSID: open.sid, from: from)
            else { return Self.error(iq, .cancel, .notAcceptable) }
            guard case .ibb(let blockSize) = transfer.mode, !open.usesMessages,
                open.blockSize <= blockSize, transfer.ibb == nil
            else { return Self.error(iq, .modify, .resourceConstraint) }
            transfer.ibb = IBB.Receiver(sid: open.sid, blockSize: open.blockSize)
            transfer.phase = .transferring
            return iq.iqResult()
        case "data":
            guard let sid = payload[attribute: "sid"],
                let transfer = receiving(transportSID: sid, from: from),
                var receiver = transfer.ibb
            else { return Self.error(iq, .cancel, .itemNotFound) }
            guard let bytes = receiver.accept(payload) else {
                // Out of order, too large or unreadable: the stream is closed (XEP-0047 2.2).
                fail(transfer.sid, "Transfer failed", condition: "failed-transport")
                return Self.error(iq, .cancel, .unexpectedRequest)
            }
            transfer.ibb = receiver
            guard store(transfer.sid, bytes) else {
                return Self.error(iq, .cancel, .notAcceptable)
            }
            return iq.iqResult()
        case "close":
            guard let sid = IBB.parseClose(payload),
                let transfer = receiving(transportSID: sid, from: from), transfer.ibb != nil
            else { return Self.error(iq, .cancel, .itemNotFound) }
            transfer.ibb = nil
            transfer.bytesComplete = true
            let session = transfer.sid
            transfer.tasks.append(Task { await self.bytesReceived(session) })
            return iq.iqResult()
        default:
            return Self.error(iq, .modify, .badRequest)
        }
    }

    private func receiving(transportSID: String, from: JID) -> Transfer? {
        transfers.values.first {
            !$0.sending && $0.transportSID == transportSID && $0.peer == from && $0.sink != nil
        }
    }

    // MARK: Ending

    /// Ends the transfer with a failure: tells the peer, then forgets it.
    private func fail(_ sid: String, _ reason: String, condition: String?) {
        guard let transfer = transfers[sid] else { return }
        continuation.yield(.failed(transfer.id, reason))
        if let condition { notify(transfer, condition: condition) }
        end(sid)
    }

    /// Ends the session at the peer without waiting for its answer.
    private func notify(_ transfer: Transfer, condition: String) {
        let sender = self.sender
        let message = Self.terminate(transfer, condition: condition)
        let peer = transfer.peer
        Task { _ = try? await sender.request(.iq(type: .set, to: peer, payload: message)) }
    }

    private func terminate(_ transfer: Transfer, condition: String) async {
        _ = try? await sender.request(
            .iq(
                type: .set, to: transfer.peer,
                payload: Self.terminate(transfer, condition: condition)))
    }

    static func terminate(_ transfer: Transfer, condition: String) -> Element {
        JingleIQ(
            action: .sessionTerminate, sid: transfer.sid, initiator: transfer.initiator,
            reason: JingleReason(condition: condition)
        ).element
    }

    /// Forgets the transfer and frees what it held.
    private func end(_ sid: String) {
        guard let transfer = transfers.removeValue(forKey: sid) else { return }
        for task in transfer.tasks { task.cancel() }
        transfer.socks?.closeAll()
        transfer.sink?.discard()
        transfer.checksumWaiter?.resume(returning: nil)
        transfer.checksumWaiter = nil
        if let source = transfer.source { try? FileManager.default.removeItem(at: source) }
    }

    // MARK: Helpers

    static func sha256(in file: JingleFileTransferDescription) -> Data? {
        (file.hashes + (file.range?.hashes ?? [])).first { $0.algorithm == "sha-256" }?.value
    }

    static func text(for condition: String) -> String {
        switch condition {
        case "decline": "Declined"
        case "cancel": "Cancelled"
        case "media-error": "Checksum mismatch"
        case "connectivity-error", "failed-transport": "Transfer failed"
        case "timeout", "expired": "Timed out"
        default: "Transfer failed"
        }
    }

    static func outOfOrder(_ iq: Element) -> Element {
        error(iq, .wait, .unexpectedRequest, jingle: "out-of-order")
    }

    static func error(
        _ iq: Element, _ type: StanzaError.ErrorType, _ condition: StanzaError.Condition,
        jingle: String? = nil
    ) -> Element {
        var reply = iq.iqResult()
        reply[attribute: "type"] = IQType.error.rawValue
        var error = StanzaError(type: type, condition: condition).element
        if let jingle {
            error.append(Element(jingle, namespace: JingleNamespace.errors))
        }
        reply.append(error)
        return reply
    }
}

extension MediaLibrary {
    /// A private copy of a file the user picked, under a temporary name in the library, with
    /// its SHA-256: what a Jingle transfer sends, so the file cannot change under it. The
    /// caller removes it.
    func copyToTemporary(_ source: URL) throws -> (url: URL, sha256: Data, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let temporary = try temporaryFile()
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 16), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                size += Int64(chunk.count)
            }
            return (temporary, Data(hasher.finalize()), size)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
