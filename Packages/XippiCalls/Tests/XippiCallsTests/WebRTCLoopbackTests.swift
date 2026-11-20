import AVFoundation
import Foundation
import Testing
import WebRTC
import XMPPCore

@testable import XippiCalls

/// Two `WebRTCMediaEngine`s in one process, connected to each other the way the CallManager
/// connects one to a peer: the offer and answer go through Jingle and back (`SDPMapper`), and
/// every local candidate goes out as a Jingle `<candidate/>` and comes back as the line
/// `SDPMapper.sdpLine(from:)` writes, with its `id` extension pair. No ICE servers, so only
/// host candidates.
@Suite struct WebRTCLoopbackTests {
    /// The factory these tests use. Setting options replaces libwebrtc's default ignore list,
    /// which has only loopback, so this one gathers on loopback as well, where no firewall
    /// drops a first packet, and leaves VPN interfaces out: on a Mac with a VPN, a socket bound
    /// to another interface fails sending to the VPN address (EAGAIN) and then stays stuck.
    /// The real interfaces are still used.
    static let factory: SharedPeerConnectionFactory = {
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreVPNNetworkAdapter = true
        return SharedPeerConnectionFactory(options: options)
    }()

    static func engine(_ audioInput: WebRTCMediaEngine.AudioInput) -> WebRTCMediaEngine {
        WebRTCMediaEngine(audioInput: audioInput, factory: factory.factory)
    }

    /// macOS WebRTC takes no fake audio device, so the audio is receive-only on both sides:
    /// the audio section is negotiated, ICE and DTLS run on it, and no audio device opens.
    @Test(.timeLimit(.minutes(1))) func audioConnectsLocally() async throws {
        let caller = Self.engine(.receiveOnly)
        let callee = Self.engine(.receiveOnly)
        try await connect(caller, callee)
    }

    /// The same with the microphone, muted on both sides so nothing is played. Skipped when
    /// there is no microphone or this process may not use it (it never asks).
    @Test(
        .enabled(if: microphoneAllowed, "no microphone, or no permission to use it"),
        .timeLimit(.minutes(1)))
    func microphoneAudioConnectsLocally() async throws {
        let caller = Self.engine(.microphone)
        let callee = Self.engine(.microphone)
        caller.setAudioMuted(true)
        callee.setAudioMuted(true)
        try await connect(caller, callee)
    }

    /// Every candidate of the caller reaches the callee before the callee has the offer, as
    /// transport-info does while a call rings, and none goes the other way. Without candidates
    /// on either side nothing connects, so the two connect only if the callee kept the early
    /// candidates and applied them with the offer (the caller learns the callee's address from
    /// its checks).
    @Test(.timeLimit(.minutes(1))) func earlyCandidatesConnect() async throws {
        let caller = Self.engine(.receiveOnly)
        let callee = Self.engine(.receiveOnly)
        defer {
            caller.close()
            callee.close()
        }
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let offer = try await caller.createOffer()
        let lines = await gathered(caller.localCandidates)
        try #require(!lines.isEmpty)
        let early = lines.map { candidate in
            Task {
                let element = try #require(
                    SDPMapper.candidate(fromSDPLine: candidate.line, mid: candidate.mid))
                let line = try #require(SDPMapper.sdpLine(from: element))
                try await callee.addRemoteCandidate(sdpLine: line, mid: candidate.mid)
            }
        }
        let waiting = await WebRTCMediaEngineTests.eventually {
            await callee.snapshot().pendingCandidates == lines.count
        }
        #expect(waiting)

        try await callee.setRemoteDescription(offer, isOffer: true)
        try await caller.setRemoteDescription(try await callee.createAnswer(), isOffer: false)
        async let callerState = settledState(of: caller, within: .seconds(10))
        async let calleeState = settledState(of: callee, within: .seconds(10))
        let states = await (callerState, calleeState)
        #expect(states.0 == .connected, "caller")
        #expect(states.1 == .connected, "callee")
        caller.close()
        callee.close()
        for task in early { try await task.value }
    }

    /// The candidates on `stream` until none came for 300 ms (5 s at most).
    func gathered(
        _ stream: AsyncStream<(line: String, mid: String)>
    ) async -> [(line: String, mid: String)] {
        await withTaskGroup(of: [(line: String, mid: String)]?.self) { group in
            let collected = Collected()
            group.addTask {
                for await candidate in stream { await collected.add(candidate) }
                return nil
            }
            group.addTask {
                let deadline = ContinuousClock.now + .seconds(5)
                var seen = -1
                while ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(300))
                    let count = await collected.items.count
                    if count > 0, count == seen { break }
                    seen = count
                }
                return await collected.items
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? []
        }
    }

    actor Collected {
        var items: [(line: String, mid: String)] = []
        func add(_ item: (line: String, mid: String)) { items.append(item) }
    }

    static var microphoneAllowed: Bool {
        AVCaptureDevice.default(for: .audio) != nil
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func connect(_ caller: WebRTCMediaEngine, _ callee: WebRTCMediaEngine) async throws {
        try await caller.prepare(iceServers: [], audio: true, video: false)
        try await callee.prepare(iceServers: [], audio: true, video: false)
        let toCallee = Task { await relay(caller.localCandidates, to: callee) }
        let toCaller = Task { await relay(callee.localCandidates, to: caller) }

        let sid = "loopback"
        let offer = try await caller.createOffer()
        let initiate = try SDPMapper.contents(fromSDP: offer, creator: "initiator")
        let media = initiate.contents.compactMap { content in
            content.description.flatMap(RTPDescription.init(element:))?.media
        }
        #expect(media == ["audio"])
        try await callee.setRemoteDescription(
            SDPMapper.sdp(sessionID: sid, contents: initiate.contents, group: initiate.group),
            isOffer: true)

        let answer = try await callee.createAnswer()
        let accept = try SDPMapper.contents(
            fromSDP: answer, creator: "initiator", author: .responder)
        #expect(accept.contents.map(\.name) == initiate.contents.map(\.name))
        try await caller.setRemoteDescription(
            SDPMapper.sdp(
                sessionID: sid, contents: accept.contents, group: accept.group,
                author: .responder),
            isOffer: false)

        async let callerState = settledState(of: caller, within: .seconds(10))
        async let calleeState = settledState(of: callee, within: .seconds(10))
        let states = await (callerState, calleeState)
        #expect(states.0 == .connected, "caller")
        #expect(states.1 == .connected, "callee")

        caller.close()
        callee.close()
        let relayedToCallee = await toCallee.value
        let relayedToCaller = await toCaller.value
        #expect(!relayedToCallee.isEmpty)
        #expect(!relayedToCaller.isEmpty)
    }

    /// Hands each candidate line to `engine` through Jingle, the way the CallManager does, until
    /// the stream ends. Returns the lines handed over.
    func relay(
        _ candidates: AsyncStream<(line: String, mid: String)>, to engine: WebRTCMediaEngine
    ) async -> [String] {
        var relayed: [String] = []
        for await candidate in candidates {
            #expect(candidate.line.hasPrefix("candidate:"), "\(candidate.line)")
            guard
                let element = SDPMapper.candidate(fromSDPLine: candidate.line, mid: candidate.mid),
                let id = element[attribute: "id"],
                let line = SDPMapper.sdpLine(from: element)
            else {
                Issue.record("not mapped: \(candidate.line)")
                continue
            }
            #expect(line.hasSuffix(" id \(id)"), "\(line)")
            do {
                try await engine.addRemoteCandidate(sdpLine: line, mid: candidate.mid)
                relayed.append(line)
            } catch MediaEngineError.closed {
                break
            } catch {
                Issue.record("refused \(line): \(error)")
            }
        }
        return relayed
    }

    /// The first of `.connected` and `.failed` within `limit`, or nil.
    func settledState(of engine: WebRTCMediaEngine, within limit: Duration) async -> MediaState? {
        await withTaskGroup(of: MediaState?.self) { group in
            group.addTask {
                for await state in engine.state where state == .connected || state == .failed {
                    return state
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
