import Foundation
import Testing

@testable import XippiCalls

/// The fake engine the CallManager tests use does what the real one does in the cases the
/// CallManager relies on: the same scenario runs against both.
@Suite(.timeLimit(.minutes(1))) struct FakeMediaEngineTests {
    enum Kind: CaseIterable, Sendable {
        case fake, real

        /// Receive-only audio on both, and video without a camera.
        func make() -> any MediaEngine {
            switch self {
            case .fake: FakeMediaEngine(audioSender: false)
            case .real: WebRTCMediaEngine(audioInput: .receiveOnly, videoInput: .noCapture)
            }
        }
    }

    static let candidate = "candidate:1 1 udp 2122260223 192.0.2.1 50000 typ host generation 0"

    @Test(arguments: Kind.allCases)
    func earlyCandidatesWaitForTheDescription(_ kind: Kind) async throws {
        let engine = kind.make()
        let peer = kind.make()
        defer {
            engine.close()
            peer.close()
        }
        try await engine.prepare(iceServers: [], audio: true, video: false)
        try await peer.prepare(iceServers: [], audio: true, video: false)
        let waiting = Task {
            try await engine.addRemoteCandidate(sdpLine: Self.candidate, mid: "0")
        }
        let dropped = Task {
            try await engine.addRemoteCandidate(sdpLine: Self.candidate, mid: "0")
        }
        try await Task.sleep(for: .milliseconds(100))
        dropped.cancel()
        await #expect(throws: CancellationError.self) { try await dropped.value }

        try await engine.setRemoteDescription(try await peer.createOffer(), isOffer: true)
        try await waiting.value
        // A mid without a section is refused.
        await #expect(throws: MediaEngineError.candidate("no media section with that mid")) {
            try await engine.addRemoteCandidate(sdpLine: Self.candidate, mid: "9")
        }
    }

    @Test(arguments: Kind.allCases)
    func closeFailsWaitingAndLaterCalls(_ kind: Kind) async throws {
        let engine = kind.make()
        try await engine.prepare(iceServers: [], audio: true, video: false)
        let waiting = Task {
            try await engine.addRemoteCandidate(sdpLine: Self.candidate, mid: "0")
        }
        try await Task.sleep(for: .milliseconds(50))
        engine.close()
        await #expect(throws: MediaEngineError.closed) { try await waiting.value }
        await #expect(throws: MediaEngineError.closed) { try await engine.createOffer() }
        for await _ in engine.state {}
        for await _ in engine.localCandidates {}
        for await _ in engine.screenShare {}
    }

    @Test(arguments: Kind.allCases)
    func cancelledCallsChangeNothing(_ kind: Kind) async throws {
        let engine = kind.make()
        defer { engine.close() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.prepare(iceServers: [], audio: true, video: false)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        // Still unprepared, so it can be prepared now.
        try await engine.prepare(iceServers: [], audio: true, video: false)
        await #expect(throws: MediaEngineError.sessionDescription("no offer to take back")) {
            try await engine.rollback()
        }
        _ = try await engine.createOffer()
        try await engine.rollback()
        _ = try await engine.createOffer()
    }

    // MARK: Renegotiation

    /// Two prepared engines with one negotiation behind them.
    static func negotiated(
        _ kind: Kind, video: Bool = false
    ) async throws -> (any MediaEngine, any MediaEngine) {
        let offerer = kind.make()
        let answerer = kind.make()
        try await offerer.prepare(iceServers: [], audio: true, video: video)
        try await answerer.prepare(iceServers: [], audio: true, video: video)
        try await negotiate(offerer, answerer)
        return (offerer, answerer)
    }

    @discardableResult
    static func negotiate(
        _ offerer: any MediaEngine, _ answerer: any MediaEngine
    ) async throws -> (offer: String, answer: String) {
        let offer = try await offerer.createOffer()
        try await answerer.setRemoteDescription(offer, isOffer: true)
        let answer = try await answerer.createAnswer()
        try await offerer.setRemoteDescription(answer, isOffer: false)
        return (offer, answer)
    }

    @Test(arguments: Kind.allCases)
    func callerAddsVideo(_ kind: Kind) async throws {
        let (caller, callee) = try await Self.negotiated(kind)
        defer {
            caller.close()
            callee.close()
        }
        #expect(try await caller.addVideo())
        let offer = try await caller.createOffer()
        // The new section comes after the ones already negotiated.
        #expect(FakeMediaEngine.sections(of: offer).map(\.mid) == ["0", "1"])
        #expect(FakeMediaEngine.sections(of: offer).map(\.media) == ["audio", "video"])
        try await callee.setRemoteDescription(offer, isOffer: true)
        let answer = try await callee.createAnswer()
        // Without a video sender of its own the callee only receives.
        #expect(Self.direction(of: "1", in: answer) == "recvonly")
        try await caller.setRemoteDescription(answer, isOffer: false)
    }

    @Test(arguments: Kind.allCases)
    func calleeAddsVideo(_ kind: Kind) async throws {
        let (caller, callee) = try await Self.negotiated(kind)
        defer {
            caller.close()
            callee.close()
        }
        #expect(try await callee.addVideo())
        let (offer, answer) = try await Self.negotiate(callee, caller)
        #expect(FakeMediaEngine.sections(of: offer).map(\.media) == ["audio", "video"])
        #expect(Self.direction(of: "1", in: answer) == "recvonly")
    }

    @Test(arguments: Kind.allCases)
    func remoteOfferWhileOurOfferIsOpenIsRefused(_ kind: Kind) async throws {
        let (caller, callee) = try await Self.negotiated(kind)
        defer {
            caller.close()
            callee.close()
        }
        _ = try await caller.createOffer()
        let crossing = try await callee.createOffer()
        await #expect(throws: MediaEngineError.self) {
            try await caller.setRemoteDescription(crossing, isOffer: true)
        }
    }

    /// An offer that only wants to receive video is answered send-only.
    @Test(arguments: Kind.allCases)
    func receiveOnlyOfferIsAnsweredSendOnly(_ kind: Kind) async throws {
        let caller = kind.make()
        let callee = kind.make()
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: true)
        try await callee.prepare(iceServers: [], audio: true, video: true)
        let offer = try await caller.createOffer()
        let video = try #require(FakeMediaEngine.sections(of: offer).first { $0.media == "video" })
        try await callee.setRemoteDescription(
            Self.munge(offer, mid: video.mid, direction: "recvonly"), isOffer: true)
        let answer = try await callee.createAnswer()
        #expect(Self.direction(of: video.mid, in: answer) == "sendonly")
    }

    /// The bug the loopback test found: an answer in a direction the offer does not allow.
    @Test(arguments: Kind.allCases)
    func incompatibleAnswerDirectionIsRefused(_ kind: Kind) async throws {
        let caller = kind.make()
        let callee = kind.make()
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let offer = try await caller.createOffer()
        let audio = try #require(FakeMediaEngine.sections(of: offer).first)
        // Receive-only audio: the caller offers to receive and nothing else.
        #expect(audio.direction == "recvonly")
        try await callee.setRemoteDescription(offer, isOffer: true)
        let answer = try await callee.createAnswer()
        let refused = Self.munge(answer, mid: audio.mid, direction: "recvonly")
        await #expect {
            try await caller.setRemoteDescription(refused, isOffer: false)
        } throws: { error in
            guard case MediaEngineError.sessionDescription(let text) = error else { return false }
            return text.contains("Incompatible send direction")
        }
        // The real answer still fits.
        try await caller.setRemoteDescription(answer, isOffer: false)
    }

    @Test(arguments: Kind.allCases)
    func answerWithActpassIsRefused(_ kind: Kind) async throws {
        let caller = kind.make()
        let callee = kind.make()
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        try await callee.setRemoteDescription(try await caller.createOffer(), isOffer: true)
        let answer = try await callee.createAnswer()
        #expect(answer.contains("a=setup:active"))
        let refused = answer.replacingOccurrences(of: "a=setup:active", with: "a=setup:actpass")
        await #expect(throws: MediaEngineError.self) {
            try await caller.setRemoteDescription(refused, isOffer: false)
        }
    }

    @Test(arguments: Kind.allCases)
    func rollbackTakesBackEitherOffer(_ kind: Kind) async throws {
        let (caller, callee) = try await Self.negotiated(kind)
        defer {
            caller.close()
            callee.close()
        }
        // Ours.
        try await caller.addVideo()
        _ = try await caller.createOffer()
        try await caller.rollback()
        // Theirs.
        try await callee.addVideo()
        try await caller.setRemoteDescription(try await callee.createOffer(), isOffer: true)
        try await caller.rollback()
        await #expect(throws: MediaEngineError.self) { try await caller.createAnswer() }
        // Both can negotiate again, with video now.
        try await callee.rollback()
        let (offer, _) = try await Self.negotiate(caller, callee)
        #expect(FakeMediaEngine.sections(of: offer).map(\.media) == ["audio", "video"])
    }

    /// The direction line of the section `mid`.
    static func direction(of mid: String, in sdp: String) -> String? {
        FakeMediaEngine.sections(of: sdp).first { $0.mid == mid }?.direction
    }

    /// `sdp` with the section `mid` in `direction`.
    static func munge(_ sdp: String, mid: String, direction: String) -> String {
        var lines = sdp.components(separatedBy: "\r\n")
        var start: Int?
        for index in lines.indices {
            if lines[index].hasPrefix("m=") { start = index }
            if lines[index] == "a=mid:\(mid)", let start {
                var end = start + 1
                while end < lines.count, !lines[end].hasPrefix("m=") { end += 1 }
                for line in start..<end
                where ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(lines[line])
                {
                    lines[line] = "a=" + direction
                }
                break
            }
        }
        return lines.joined(separator: "\r\n")
    }
}
