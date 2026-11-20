import Foundation
import Testing
import WebRTC
import XMPPCore
import XippiCalls

/// Feeds what `SDPMapper` writes for real peers' session-initiates to libwebrtc, the engine
/// Task 19 runs, and maps libwebrtc's answer back. No capture device is opened: the answer has
/// no local tracks.
@Suite struct WebRTCAcceptanceTests {
    static let fixtures = [
        "conversations-session-initiate", "dino-session-initiate", "monal-session-initiate",
    ]

    @Test func libwebrtcTakesMappedOffersAndCandidates() async throws {
        _ = RTCInitializeSSL()
        // The plain initializer has H264 only; Dino offers H264 without parameters and Monal
        // with names of its own, so neither would match and their video would be refused.
        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        for name in Self.fixtures {
            try await check(name, factory: factory)
        }
    }

    func check(_ name: String, factory: RTCPeerConnectionFactory) async throws {
        let iq = try #require(JingleIQ(element: parseElement(fixture(name, "xml"))))
        let group = iq.info.lazy.compactMap(JingleGroup.init(element:)).first?.contents ?? []
        let offer = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: group)

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        // Dino does not bundle.
        configuration.bundlePolicy = .balanced
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = try #require(
            factory.peerConnection(with: configuration, constraints: constraints, delegate: nil),
            "\(name): no peer connection")
        defer { connection.close() }

        // The offer carries the fixture's candidates, each with its id extension pair.
        do {
            try await connection.setRemoteDescription(
                RTCSessionDescription(type: .offer, sdp: offer))
        } catch {
            Issue.record("\(name): libwebrtc refused the offer: \(error)\n\(offer)")
            return
        }

        let answer = try await connection.answer(for: constraints)
        let mapped = try SDPMapper.contents(
            fromSDP: answer.sdp, creator: "initiator", author: .responder)
        #expect(mapped.contents.map(\.name) == iq.contents.map(\.name), "\(name)")
        #expect(mapped.group == group, "\(name)")
        for content in mapped.contents {
            #expect(content.creator == "initiator", "\(name)")
            // No local tracks: the responder only receives.
            #expect(content.senders == "initiator", "\(name)")
            let description = try #require(
                content.description.flatMap(RTPDescription.init(element:)))
            #expect(!description.payloadTypes.isEmpty, "\(name) \(content.name)")
            #expect(description.rtcpMux, "\(name) \(content.name)")
            let transport = try #require(content.transport.flatMap(ICEUDPTransport.init(element:)))
            #expect(transport.ufrag?.isEmpty == false, "\(name) \(content.name)")
            #expect(transport.pwd?.isEmpty == false, "\(name) \(content.name)")
            #expect(transport.fingerprints.first?.hash == "sha-256", "\(name) \(content.name)")
            #expect(transport.fingerprints.first?.setup == "active", "\(name) \(content.name)")
        }
        // The answer goes back to the peer as a session-accept.
        let accept = JingleIQ(
            action: .sessionAccept, sid: iq.sid, contents: mapped.contents,
            info: mapped.group.isEmpty ? [] : [JingleGroup(contents: mapped.group).element])
        #expect(try JingleIQ(element: parseElement(accept.element.xml())) == accept, "\(name)")

        // A candidate the peer trickles later, through transport-info.
        let trickled = ICECandidate(
            component: 1, foundation: "4242", id: "trickled-\(name)", ip: "198.51.100.9",
            network: 1, port: 40000, priority: 1_686_052_607, type: "srflx", relAddr: "10.0.0.9",
            relPort: 40000)
        let line = try #require(SDPMapper.sdpLine(from: trickled.element))
        #expect(line.hasSuffix(" network-id 1 id trickled-\(name)"))
        let mid = iq.contents[0].name
        do {
            try await connection.add(RTCIceCandidate(sdp: line, sdpMLineIndex: 0, sdpMid: mid))
        } catch {
            Issue.record("\(name): libwebrtc refused the candidate \(line): \(error)")
        }
    }
}
