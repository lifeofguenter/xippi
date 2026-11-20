import Foundation
import Testing
import XMPPCore
import XippiCalls

private func rtp(_ content: JingleContent) throws -> RTPDescription {
    try #require(content.description.flatMap(RTPDescription.init(element:)))
}

private func ice(_ content: JingleContent) throws -> ICEUDPTransport {
    try #require(content.transport.flatMap(ICEUDPTransport.init(element:)))
}

/// Same contents as far as SDP can carry them: payload types with their parameters and
/// feedback, header extensions, sources, rtcp-mux, the transport with its fingerprints and
/// candidates, and the senders ("both" whether written or not).
private func expectEquivalent(
    _ original: [JingleContent], _ mapped: [JingleContent],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(original.map(\.name) == mapped.map(\.name), sourceLocation: sourceLocation)
    #expect(original.map(\.creator) == mapped.map(\.creator), sourceLocation: sourceLocation)
    #expect(
        original.map { $0.senders ?? "both" } == mapped.map { $0.senders ?? "both" },
        sourceLocation: sourceLocation)
    for (before, after) in zip(original, mapped) {
        let descriptionBefore = try rtp(before)
        let descriptionAfter = try rtp(after)
        #expect(
            descriptionBefore.payloadTypes == descriptionAfter.payloadTypes,
            sourceLocation: sourceLocation)
        #expect(descriptionBefore == descriptionAfter, sourceLocation: sourceLocation)
        let transportBefore = try ice(before)
        let transportAfter = try ice(after)
        #expect(
            transportBefore.fingerprints == transportAfter.fingerprints,
            sourceLocation: sourceLocation)
        #expect(
            transportBefore.candidates == transportAfter.candidates, sourceLocation: sourceLocation)
        #expect(transportBefore == transportAfter, sourceLocation: sourceLocation)
    }
}

@Suite struct SDPMapperTests {
    @Test func conversationsOfferRoundTrips() throws {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("conversations-session-initiate", "xml"))))
        let group = try #require(iq.info.lazy.compactMap(JingleGroup.init(element:)).first)
        #expect(group.contents == ["0", "1"])

        let sdp = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: group.contents)
        let mapped = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")

        #expect(mapped.group == ["0", "1"])
        try expectEquivalent(iq.contents, mapped.contents)
        // The parts the brief names, spelled out.
        let audio = try rtp(mapped.contents[0])
        #expect(audio.payloadTypes.map(\.id) == [111, 63, 9, 0, 8, 13, 110, 126])
        #expect(
            audio.payloadTypes[0].parameters == [
                RTPParameter(name: "minptime", value: "10"),
                RTPParameter(name: "useinbandfec", value: "1"),
            ])
        let video = try rtp(mapped.contents[1])
        #expect(
            video.sourceGroups == [
                RTPSourceGroup(semantics: "FID", sources: [1_846_272_135, 3_005_519_812])
            ])
        let transport = try ice(mapped.contents[0])
        #expect(
            transport.fingerprints == [
                DTLSFingerprint(
                    hash: "sha-256", setup: "actpass",
                    value:
                        "4F:21:9C:0E:7A:D3:58:B1:66:2C:E0:9F:13:A4:7B:C8:05:DE:91:3F:48:B2:6A:E7:10:5C:FD:83:29:B6:C4:7E"
                )
            ])
        #expect(transport.iceOptions == ["trickle", "renomination"])
        #expect(
            transport.candidates.map(\.id) == [
                "1d6a0f7c-3d1b-4f0a-9a64-1b9c0e2f5a31", "8b4f2e91-0c7d-4b3a-a5e6-7d2c1f0b9e84",
                "c9e1d3a7-2f5b-4e8c-b6a0-3d9f7e1c5b26", "5f0b8d2e-9a4c-4d1f-8e7b-6c3a2d0f1e95",
            ])
    }

    @Test func dinoOfferRoundTrips() throws {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("dino-session-initiate", "xml"))))
        #expect(iq.info.isEmpty)

        let sdp = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: [])
        #expect(!sdp.contains("a=group:"))
        #expect(!sdp.contains("a=crypto"))
        let mapped = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")

        #expect(mapped.group.isEmpty)
        try expectEquivalent(iq.contents, mapped.contents)
        let audio = try ice(mapped.contents[0])
        #expect(audio.candidates.map(\.network) == [0, 0, 0, 0])
        #expect(audio.candidates.map(\.component) == [1, 2, 1, 1])
        #expect(
            audio.candidates.map(\.id) == ["q7v2x9k4m1", "h3n8c5w0p6", "t6b1r4j9y2", "z0f5d8s3g7"])
    }

    @Test func monalOfferRoundTrips() throws {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("monal-session-initiate", "xml"))))
        let group = try #require(iq.info.lazy.compactMap(JingleGroup.init(element:)).first)

        let sdp = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: group.contents)
        let mapped = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")

        #expect(mapped.group == ["0", "1"])
        // Monal writes <extmap-allow-mixed/> in the RTP namespace rather than XEP-0294's.
        for content in iq.contents { #expect(try rtp(content).extmapAllowMixed) }
        let lines = sdp.components(separatedBy: "\r\n")
        #expect(lines.filter { $0 == "a=extmap-allow-mixed" }.count == 2)
        // Its own parameter names are passed on as they are, as Conversations does.
        #expect(lines.contains("a=fmtp:63 encodings=111;encodings=111"))
        #expect(
            lines.contains(
                "a=fmtp:96 packetization_mode=1;level_asymmetry_allowed=true;profile_level_id=6556724"
            ))
        #expect(lines.contains("a=fmtp:111 useinbandfec=true;minptime=10"))
        // The mapped contents carry the XEP-0294 namespace, so they compare by value only.
        try expectEquivalent(iq.contents, mapped.contents)
    }

    @Test func chromeSDPToJingleHasRequiredFields() throws {
        let sdp = try fixture("chrome-offer", "sdp")
        let (contents, group) = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")

        #expect(group == ["0", "1"])
        #expect(contents.map(\.name) == ["0", "1"])
        for content in contents {
            #expect(content.creator == "initiator")
            #expect(content.senders == nil)
            #expect(content.security == nil)
            let description = try rtp(content)
            #expect(description.rtcpMux)
            #expect(description.extmapAllowMixed)
            let transport = try ice(content)
            #expect(transport.ufrag == "Kb3d")
            #expect(transport.pwd == "x7Gq0LpcR2jvN1uEw5yTaHsZ")
            #expect(transport.iceOptions == ["trickle"])
            #expect(transport.fingerprints.count == 1)
            #expect(transport.fingerprints.first?.hash == "sha-256")
            #expect(transport.fingerprints.first?.setup == "actpass")
            #expect(
                transport.fingerprints.first?.value
                    == "7B:8B:F0:65:5F:78:E2:51:3B:AC:6F:F3:3F:46:1B:35:DC:B8:5F:64:1A:24:C2:43:F0:A1:58:D0:A1:2C:19:08"
            )
        }

        let audio = try rtp(contents[0])
        #expect(audio.media == "audio")
        #expect(audio.payloadTypes.map(\.id) == [111, 63, 9, 0, 8, 13, 110, 126])
        let opus = audio.payloadTypes[0]
        #expect(opus.name == "opus")
        #expect(opus.clockrate == 48000)
        #expect(opus.channels == 2)
        #expect(
            opus.parameters == [
                RTPParameter(name: "minptime", value: "10"),
                RTPParameter(name: "useinbandfec", value: "1"),
            ])
        #expect(opus.feedback == [RTCPFeedback(type: "transport-cc")])
        // RFC 2198 redundancy has a value without a name.
        #expect(audio.payloadTypes[1].parameters == [RTPParameter(name: "", value: "111/111")])
        #expect(audio.payloadTypes[3].channels == nil)
        #expect(audio.headerExtensions.map(\.id) == [1, 2, 3, 4])
        #expect(audio.headerExtensions[3].uri == "urn:ietf:params:rtp-hdrext:sdes:mid")
        #expect(
            audio.sources == [
                RTPSource(
                    ssrc: 1_001_623_473,
                    parameters: [
                        .init(name: "cname", value: "F3pd8fCLm5Q0yEuS"),
                        .init(
                            name: "msid",
                            value:
                                "3c5b1a7e-6f0d-4a2b-9e1c-8d7f6a5b4c3d 9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
                        ),
                    ])
            ])

        let video = try rtp(contents[1])
        #expect(
            video.payloadTypes.map(\.id) == [
                96, 97, 98, 99, 100, 101, 102, 103, 35, 36, 114, 115, 116,
            ])
        #expect(
            video.payloadTypes[0].feedback == [
                RTCPFeedback(type: "goog-remb"), RTCPFeedback(type: "transport-cc"),
                RTCPFeedback(type: "ccm", subtype: "fir"), RTCPFeedback(type: "nack"),
                RTCPFeedback(type: "nack", subtype: "pli"),
            ])
        #expect(video.payloadTypes[1].parameters == [RTPParameter(name: "apt", value: "96")])
        #expect(
            video.payloadTypes[6].parameters.map(\.name) == [
                "level-asymmetry-allowed", "packetization-mode", "profile-level-id",
            ])
        #expect(video.headerExtensions.count == 11)
        #expect(
            video.sourceGroups == [
                RTPSourceGroup(semantics: "FID", sources: [2_944_286_387, 1_294_817_352])
            ])
        #expect(video.sources.map(\.ssrc) == [2_944_286_387, 1_294_817_352])

        let candidates = try ice(contents[0]).candidates
        #expect(candidates.count == 3)
        #expect(try ice(contents[1]).candidates.isEmpty)
        let host = candidates[0]
        #expect(host.foundation == "2999745851")
        #expect(host.component == 1)
        #expect(host.transportProtocol == "udp")
        #expect(host.priority == 2_122_260_223)
        #expect(host.ip == "192.168.1.20")
        #expect(host.port == 56143)
        #expect(host.type == "host")
        #expect(host.generation == 0)
        #expect(host.network == 1)
        #expect(host.id?.isEmpty == false)
        let srflx = candidates[1]
        #expect(srflx.relAddr == "192.168.1.20")
        #expect(srflx.relPort == 56143)
        let tcp = candidates[2]
        #expect(tcp.transportProtocol == "tcp")
        #expect(tcp.tcpType == "active")
        #expect(Set(candidates.compactMap(\.id)).count == 3)
    }

    @Test func chromeSDPRoundTripIsStable() throws {
        let sdp = try fixture("chrome-offer", "sdp")
        let first = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")
        let written = try SDPMapper.sdp(
            sessionID: "s", contents: first.contents, group: first.group)
        let second = try SDPMapper.contents(fromSDP: written, creator: "initiator")
        #expect(second.group == first.group)
        try expectEquivalent(first.contents, second.contents)
        // Writing again gives the same text.
        #expect(
            try SDPMapper.sdp(sessionID: "s", contents: second.contents, group: second.group)
                == written)
    }

    @Test func lineEndingsDoNotMatter() throws {
        let lf = try fixture("chrome-offer", "sdp").replacingOccurrences(of: "\r\n", with: "\n")
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let fromLF = try SDPMapper.contents(fromSDP: lf, creator: "initiator")
        let fromCRLF = try SDPMapper.contents(fromSDP: crlf, creator: "initiator")
        #expect(fromLF.group == fromCRLF.group)
        try expectEquivalent(
            fromLF.contents.map(withoutCandidateIDs), fromCRLF.contents.map(withoutCandidateIDs))
    }

    @Test func outputIsCRLFInWebRTCOrder() throws {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("conversations-session-initiate", "xml"))))
        let sdp = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: ["0", "1"])

        #expect(sdp.hasSuffix("\r\n"))
        #expect(!sdp.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let lines = sdp.components(separatedBy: "\r\n").dropLast()
        #expect(Array(lines.prefix(4)).map { String($0.prefix(2)) } == ["v=", "o=", "s=", "t="])
        #expect(lines[4] == "a=group:BUNDLE 0 1")
        #expect(lines[5].hasPrefix("a=msid-semantic:"))

        // Within each media section, the first line of each kind appears in this order.
        let order = [
            "m=", "c=", "a=rtcp:", "a=candidate:", "a=ice-ufrag:", "a=ice-pwd:", "a=ice-options:",
            "a=fingerprint:", "a=setup:", "a=mid:", "a=extmap:", "a=extmap-allow-mixed",
            "a=sendrecv", "a=rtcp-mux", "a=rtpmap:", "a=ssrc-group:", "a=ssrc:",
        ]
        let sections = lines.split(whereSeparator: { $0.hasPrefix("m=") })
        let mLines = lines.filter { $0.hasPrefix("m=") }
        #expect(
            mLines == [
                "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126",
                "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 102 103 35 36 114 115 116",
            ])
        for (mLine, body) in zip(mLines, sections.dropFirst()) {
            let section = [mLine] + body
            let firstIndex = order.compactMap { prefix in
                section.firstIndex(where: { $0.hasPrefix(prefix) })
            }
            #expect(firstIndex == firstIndex.sorted(), "\(mLine)")
            let lastPayloadLine = section.lastIndex(where: {
                $0.hasPrefix("a=rtpmap:") || $0.hasPrefix("a=fmtp:") || $0.hasPrefix("a=rtcp-fb:")
            })
            let firstSourceLine = section.firstIndex(where: { $0.hasPrefix("a=ssrc") })
            #expect((lastPayloadLine ?? 0) < (firstSourceLine ?? .max), "\(mLine)")
        }
        // Per payload type: rtpmap, then its fmtp, then its rtcp-fb.
        let h264 = lines.filter { $0.contains(":102 ") }
        #expect(
            h264 == [
                "a=rtpmap:102 H264/90000",
                "a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
                "a=rtcp-fb:102 goog-remb", "a=rtcp-fb:102 transport-cc", "a=rtcp-fb:102 ccm fir",
                "a=rtcp-fb:102 nack", "a=rtcp-fb:102 nack pli",
            ])
        #expect(lines.contains("a=rtpmap:111 opus/48000/2"))
        #expect(lines.contains("a=rtpmap:9 G722/8000"))
        #expect(lines.contains("a=ssrc:2364108716 msid:my-media-stream my-audio-track"))
        #expect(lines.contains("a=ssrc-group:FID 1846272135 3005519812"))
        #expect(lines.contains("a=ice-options:trickle renomination"))
        #expect(
            lines.contains(
                "a=candidate:842163049 1 udp 1686052607 198.51.100.23 41625 typ srflx raddr 192.168.178.31 rport 41625 generation 0 id c9e1d3a7-2f5b-4e8c-b6a0-3d9f7e1c5b26"
            ))
    }

    @Test func sendersFollowTheAuthorsRole() throws {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("dino-session-initiate", "xml"))))
        var contents = iq.contents
        contents[0].senders = "initiator"
        contents[1].senders = "none"

        // The initiator's offer: it sends, so sendonly.
        let offer = try SDPMapper.sdp(sessionID: iq.sid, contents: contents, group: [])
        #expect(offer.contains("a=mid:audio\r\n") && offer.contains("a=sendonly\r\n"))
        #expect(offer.contains("a=inactive\r\n"))
        let back = try SDPMapper.contents(fromSDP: offer, creator: "initiator")
        #expect(back.contents.map(\.senders) == ["initiator", "none"])

        // The same contents in the responder's answer: it only receives.
        let answer = try SDPMapper.sdp(
            sessionID: iq.sid, contents: contents, group: [], author: .responder)
        #expect(answer.contains("a=recvonly\r\n"))
        let answerBack = try SDPMapper.contents(
            fromSDP: answer, creator: "initiator", author: .responder)
        #expect(answerBack.contents.map(\.senders) == ["initiator", "none"])
        #expect(answerBack.contents.map(\.creator) == ["initiator", "initiator"])
    }

    @Test func trickledCandidateMapsBothWays() throws {
        let line =
            "candidate:842163049 1 udp 1677729535 198.51.100.7 50000 typ srflx raddr 0.0.0.0 rport 0 generation 0 ufrag sXTq network-id 1 network-cost 10"
        let element = try #require(SDPMapper.candidate(fromSDPLine: line, mid: "0"))
        #expect(element.name == "candidate")
        #expect(element.namespace == JingleNamespace.iceUDP)
        #expect(element[attribute: "foundation"] == "842163049")
        #expect(element[attribute: "component"] == "1")
        #expect(element[attribute: "protocol"] == "udp")
        #expect(element[attribute: "priority"] == "1677729535")
        #expect(element[attribute: "ip"] == "198.51.100.7")
        #expect(element[attribute: "port"] == "50000")
        #expect(element[attribute: "type"] == "srflx")
        #expect(element[attribute: "rel-addr"] == "0.0.0.0")
        #expect(element[attribute: "rel-port"] == "0")
        #expect(element[attribute: "generation"] == "0")
        #expect(element[attribute: "network"] == "1")
        let id = try #require(element[attribute: "id"])
        #expect(!id.isEmpty)

        #expect(
            SDPMapper.sdpLine(from: element)
                == "candidate:842163049 1 udp 1677729535 198.51.100.7 50000 typ srflx raddr 0.0.0.0 rport 0 generation 0 network-id 1 id \(id)"
        )
        // With the "a=" prefix of a full SDP line too.
        #expect(SDPMapper.candidate(fromSDPLine: "a=" + line, mid: "0") != nil)
    }

    @Test func jingleCandidateWithoutNetworkOrID() throws {
        let element = try parseElement(
            "<candidate xmlns='urn:xmpp:jingle:transports:ice-udp:1' component='1' foundation='1' generation='0' ip='10.0.1.1' port='8998' priority='2130706431' protocol='udp' type='host'/>"
        )
        #expect(
            SDPMapper.sdpLine(from: element)
                == "candidate:1 1 udp 2130706431 10.0.1.1 8998 typ host generation 0")
    }

    @Test(arguments: [
        "candidate:1 1 udp 2130706431 10.0.1.1 8998",
        "candidate:1 1 udp 2130706431 10.0.1.1 8998 typ",
        "candidate:1 1 udp 2130706431 10.0.1.1 99999 typ host",
        "candidate:1 0 udp 2130706431 10.0.1.1 8998 typ host",
        "candidate:1 1 udp -5 10.0.1.1 8998 typ host",
        "candidate:1 1 udp 2130706431 10.0.1.1 8998 typ wormhole",
        "candidate:1 1 tcp 2130706431 10.0.1.1 9 typ host tcptype sideways",
        "candidate:1 1 udp 2130706431 10.0.1.1 8998 typ srflx raddr 10.0.0.1 rport x",
        "ice-ufrag:abcd",
        "",
    ])
    func malformedCandidateLinesAreRefused(_ line: String) {
        #expect(SDPMapper.candidate(fromSDPLine: line, mid: "0") == nil)
    }

    @Test func candidateNeedsAMid() {
        let line = "candidate:1 1 udp 2130706431 10.0.1.1 8998 typ host generation 0"
        #expect(SDPMapper.candidate(fromSDPLine: line, mid: "") == nil)
        #expect(SDPMapper.candidate(fromSDPLine: line, mid: "a b") == nil)
    }

    @Test func peerPartsMapWhenNothingIsInjected() throws {
        let parts = try PeerParts.base()
        let sdp = try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: parts.group)
        // Every field the injection test touches is in this SDP.
        for line in [
            "b=AS:128", "a=rtcp-fb:* ccm fir",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level a=1",
            "a=ssrc-group:FID 2364108716 1", "a=setup:actpass", "a=group:BUNDLE 0",
            "tcptype passive",
        ] {
            #expect(sdp.contains(line), "\(line)")
        }
    }

    @Test(arguments: PeerField.all)
    func peerValuesCannotInjectSDPLines(_ field: PeerField) throws {
        for injected in ["x\r\na=injected:1", "x\na=injected:1", "x\ra=injected:1"] {
            var parts = try PeerParts.base()
            field.set(&parts, injected)
            let sdp = try? SDPMapper.sdp(
                sessionID: "s", contents: [parts.content], group: parts.group)
            #expect(sdp.map { !$0.contains("a=injected") } ?? true)
        }
        let candidate = try parseElement(
            "<candidate xmlns='urn:xmpp:jingle:transports:ice-udp:1' component='1' foundation='1' generation='0' id='x' ip='10.0.1.1 typ relay' port='8998' priority='1' protocol='udp' type='host'/>"
        )
        #expect(SDPMapper.sdpLine(from: candidate) == nil)
    }

    @Test func unknownEnumeratedValuesAreDropped() throws {
        let ice = "urn:xmpp:jingle:transports:ice-udp:1"
        // A candidate in a protocol libwebrtc does not parse is left out, not the description.
        let sctp = try parseElement(
            "<candidate xmlns='\(ice)' component='1' foundation='1' generation='0' ip='10.0.1.1' port='1' priority='1' protocol='sctp' type='host'/>"
        )
        #expect(ICECandidate(element: sctp) == nil)
        #expect(
            SDPMapper.candidate(fromSDPLine: "candidate:1 1 sctp 1 10.0.1.1 1 typ host", mid: "0")
                == nil)
        // tcptype belongs to TCP candidates only.
        let udp = try parseElement(
            "<candidate xmlns='\(ice)' component='1' foundation='1' generation='0' ip='10.0.1.1' port='1' priority='1' protocol='udp' tcptype='active' type='host'/>"
        )
        #expect(try #require(ICECandidate(element: udp)).tcpType == nil)
        let fromLine = SDPMapper.candidate(
            fromSDPLine: "candidate:1 1 udp 1 10.0.1.1 1 typ host tcptype active", mid: "0")
        #expect(fromLine != nil)
        #expect(fromLine?[attribute: "tcptype"] == nil)
        // XEP-0320 setup is actpass, active or passive; holdconn has no mapping.
        for setup in ["holdconn", "sometimes"] {
            let transport = try parseElement(
                "<transport xmlns='\(ice)' ufrag='u' pwd='p'><fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='\(setup)'>AA:BB</fingerprint></transport>"
            )
            #expect(
                try #require(ICEUDPTransport(element: transport)).fingerprints.first?.setup == nil)
        }
        // Only audio and video are RTP media the engine takes.
        var parts = try PeerParts.base()
        parts.description.media = "application"
        parts.apply()
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: [])
        }
        // A source attribute without a value has no SDP form libwebrtc reads; it is left out.
        parts = try PeerParts.base()
        parts.description.sources[0].parameters.append(.init(name: "flag"))
        parts.apply()
        let sdp = try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: [])
        #expect(!sdp.contains("a=ssrc:2364108716 flag"))
        #expect(sdp.contains("a=ssrc:2364108716 cname:5RgMZQAyKHnbJ1v8"))
    }

    @Test func emptyFormatParametersAreLeftOut() throws {
        let xml = """
            <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>\
            <payload-type id='111' name='opus' clockrate='48000' channels='2'>\
            <parameter name='x' value=''/><parameter name='y'/><parameter name='minptime' value='10'/>\
            </payload-type>\
            <payload-type id='63' name='red' clockrate='48000' channels='2'><parameter value='111/111'/></payload-type>\
            <payload-type id='9' name='G722' clockrate='8000'><parameter name='z' value=''/></payload-type>\
            </description>
            """
        let description = try #require(RTPDescription(element: parseElement(xml)))
        // A parameter without a name is the nameless form RED's value takes.
        #expect(
            description.payloadTypes[1].parameters == [RTPParameter(name: "", value: "111/111")])
        var parts = try PeerParts.base()
        parts.description.payloadTypes = description.payloadTypes
        parts.apply()
        let lines = try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: [])
            .components(separatedBy: "\r\n")
        #expect(lines.contains("a=fmtp:111 minptime=10"))
        #expect(lines.contains("a=fmtp:63 111/111"))
        #expect(!lines.contains { $0.hasPrefix("a=fmtp:9") })
    }

    @Test func payloadTypesFrom35NeedAnRtpmap() throws {
        var parts = try PeerParts.base()
        parts.description.payloadTypes = [RTPPayloadType(id: 34)]
        parts.apply()
        let sdp = try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: [])
        #expect(sdp.contains("m=audio 9 UDP/TLS/RTP/SAVPF 34\r\n"))
        #expect(!sdp.contains("a=rtpmap:"))
        // 35-95 are not static payload types; libwebrtc hands them out dynamically.
        parts.description.payloadTypes = [RTPPayloadType(id: 35)]
        parts.apply()
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.sdp(sessionID: "s", contents: [parts.content], group: [])
        }
    }

    @Test func lessCommonLinesMapBothWays() throws {
        let sdp = """
            v=0
            o=- 1 2 IN IP4 127.0.0.1
            s=-
            t=0 0
            a=ice-ufrag:sess
            a=ice-pwd:sessionpasswordsessionpw
            a=ice-options:trickle
            a=fingerprint:sha-256 AA:BB
            a=setup:passive
            m=audio 9 UDP/TLS/RTP/SAVPF 111
            c=IN IP4 0.0.0.0
            b=AS:64
            a=candidate:1 1 udp 2130706431 10.0.0.1 5000 typ host generation 2
            a=mid:a
            a=extmap:1/recvonly urn:example:one
            a=extmap:2/inactive urn:example:two
            a=extmap:3/sendonly urn:example:three attr=1 flag
            a=sendonly
            a=msid:stream track
            a=rtcp-fb:* nack
            a=rtpmap:111 opus/48000/2
            a=rtcp-fb:111 trr-int 100
            a=ptime:20
            a=maxptime:60
            a=ssrc:42 cname:c
            """
        let (contents, group) = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")
        #expect(group.isEmpty)
        let content = try #require(contents.first)
        #expect(content.senders == "initiator")
        let transport = try ice(content)
        // Session-level ICE and DTLS lines apply to the media section.
        #expect(transport.ufrag == "sess")
        #expect(transport.pwd == "sessionpasswordsessionpw")
        #expect(transport.iceOptions == ["trickle"])
        #expect(
            transport.fingerprints == [
                DTLSFingerprint(hash: "sha-256", setup: "passive", value: "AA:BB")
            ])
        #expect(transport.candidates.first?.generation == 2)
        let description = try rtp(content)
        #expect(description.bandwidth == RTPBandwidth(type: "AS", value: 64))
        #expect(
            description.headerExtensions == [
                RTPHeaderExtension(id: 1, uri: "urn:example:one", senders: "responder"),
                RTPHeaderExtension(
                    id: 3, uri: "urn:example:three", senders: "initiator",
                    parameters: [
                        RTPParameter(name: "attr", value: "1"),
                        RTPParameter(name: "flag", value: ""),
                    ]),
            ])
        #expect(description.feedback == [RTCPFeedback(type: "nack")])
        let opus = try #require(description.payloadTypes.first)
        #expect(opus.feedback == [RTCPFeedback(type: "trr-int", subtype: "100")])
        #expect(opus.ptime == 20)
        #expect(opus.maxptime == 60)
        // The media-level msid goes onto the source that has none.
        #expect(
            description.sources == [
                RTPSource(
                    ssrc: 42,
                    parameters: [
                        .init(name: "cname", value: "c"),
                        .init(name: "msid", value: "stream track"),
                    ])
            ])
        #expect(
            description.element.child("payload-type")?.child("rtcp-fb-trr-int")?[attribute: "value"]
                == "100")

        let lines = try SDPMapper.sdp(sessionID: "s", contents: contents, group: [])
            .components(separatedBy: "\r\n")
        for line in [
            "b=AS:64", "a=setup:passive", "a=extmap:1/recvonly urn:example:one",
            "a=extmap:3/sendonly urn:example:three attr=1 flag", "a=sendonly", "a=rtcp-fb:* nack",
            "a=rtcp-fb:111 trr-int 100", "a=ptime:20", "a=maxptime:60",
            "a=ssrc:42 msid:stream track",
            "a=candidate:1 1 udp 2130706431 10.0.0.1 5000 typ host generation 2 id \(transport.candidates[0].id ?? "")",
        ] {
            #expect(lines.contains(line), "\(line)")
        }
        #expect(!lines.contains { $0.contains("urn:example:two") })

        // The same lines in the responder's answer belong to the other party.
        let answer = try SDPMapper.contents(fromSDP: sdp, creator: "initiator", author: .responder)
        #expect(answer.contents.first?.senders == "responder")
        #expect(
            try rtp(#require(answer.contents.first)).headerExtensions.map(\.senders) == [
                "initiator", "responder",
            ])
        let active = try SDPMapper.contents(
            fromSDP: sdp.replacingOccurrences(of: "setup:passive", with: "setup:active"),
            creator: "initiator")
        #expect(try ice(#require(active.contents.first)).fingerprints.first?.setup == "active")
    }

    @Test func contentsWithoutRTPOrICEAreRefused() throws {
        let stub = try #require(JingleIQ(element: parseElement(XEP0166.stubInitiate)))
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.sdp(sessionID: stub.sid, contents: stub.contents, group: [])
        }
        // The XEP-0166 answer has a transport without ufrag and pwd.
        let accept = try #require(JingleIQ(element: parseElement(XEP0166.rtpAccept)))
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.sdp(sessionID: accept.sid, contents: accept.contents, group: [])
        }
    }

    @Test func malformedSDPIsRefused() throws {
        let sdp = try fixture("chrome-offer", "sdp")
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.contents(
                fromSDP: sdp.replacingOccurrences(of: "a=mid:1\n", with: ""), creator: "initiator")
        }
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.contents(fromSDP: sdp, creator: "both")
        }
        #expect(throws: SDPMapperError.self) {
            try SDPMapper.contents(fromSDP: "v=0\nthis is not sdp\n", creator: "initiator")
        }
    }

    @Test func rejectedMediaSectionsAreLeftOut() throws {
        let sdp = try fixture("chrome-offer", "sdp")
            .replacingOccurrences(
                of: "m=video 9 UDP/TLS/RTP/SAVPF", with: "m=video 0 UDP/TLS/RTP/SAVPF")
        let (contents, group) = try SDPMapper.contents(fromSDP: sdp, creator: "initiator")
        #expect(contents.map(\.name) == ["0"])
        #expect(group == ["0"])
    }

    @Test func groupOnlyNamesContentsThatArePresent() throws {
        // libwebrtc refuses a BUNDLE group naming a mid without a media section.
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("conversations-session-initiate", "xml"))))
        let sdp = try SDPMapper.sdp(
            sessionID: iq.sid, contents: Array(iq.contents.prefix(1)), group: ["0", "1", "2"])
        #expect(sdp.contains("\r\na=group:BUNDLE 0\r\n"))
        let none = try SDPMapper.sdp(sessionID: iq.sid, contents: iq.contents, group: ["9"])
        #expect(!none.contains("a=group:"))
    }
}

/// Candidate ids that SDP did not carry are made up on each mapping.
private func withoutCandidateIDs(_ content: JingleContent) -> JingleContent {
    guard var transport = content.transport.flatMap(ICEUDPTransport.init(element:)) else {
        return content
    }
    for index in transport.candidates.indices { transport.candidates[index].id = nil }
    var copy = content
    copy.transport = transport.element
    return copy
}

/// The parts of one content the injection test changes.
struct PeerParts {
    var content: JingleContent
    var description: RTPDescription
    var transport: ICEUDPTransport
    var group: [String]

    /// The Conversations audio content with one of every value that reaches SDP.
    static func base() throws -> PeerParts {
        let iq = try #require(
            JingleIQ(element: parseElement(fixture("conversations-session-initiate", "xml"))))
        let content = iq.contents[0]
        var description = try #require(content.description.flatMap(RTPDescription.init(element:)))
        description.bandwidth = RTPBandwidth(type: "AS", value: 128)
        description.feedback = [RTCPFeedback(type: "ccm", subtype: "fir")]
        description.headerExtensions[0].parameters = [RTPParameter(name: "a", value: "1")]
        description.sourceGroups = [RTPSourceGroup(semantics: "FID", sources: [2_364_108_716, 1])]
        var transport = try #require(content.transport.flatMap(ICEUDPTransport.init(element:)))
        transport.candidates.append(
            ICECandidate(
                component: 1, foundation: "9", id: "tcp1", ip: "192.168.178.31", port: 9,
                priority: 1, transportProtocol: "tcp", type: "host", tcpType: "passive"))
        var parts = PeerParts(
            content: content, description: description, transport: transport, group: ["0"])
        parts.apply()
        return parts
    }

    mutating func apply() {
        content.description = description.element
        content.transport = transport.element
    }
}

/// A peer value that ends up in the SDP.
struct PeerField: Sendable, CustomTestStringConvertible {
    let name: String
    let change: @Sendable (inout PeerParts, String) -> Void

    var testDescription: String { name }

    func set(_ parts: inout PeerParts, _ value: String) {
        change(&parts, value)
        parts.apply()
    }

    static let all: [PeerField] = [
        PeerField(name: "media") { $0.description.media = $1 },
        PeerField(name: "payload type name") { $0.description.payloadTypes[0].name = $1 },
        PeerField(name: "format parameter name") {
            $0.description.payloadTypes[0].parameters[0].name = $1
        },
        PeerField(name: "format parameter value") {
            $0.description.payloadTypes[0].parameters[0].value = $1
        },
        PeerField(name: "feedback type") { $0.description.payloadTypes[0].feedback[0].type = $1 },
        PeerField(name: "feedback subtype") {
            $0.description.payloadTypes[0].feedback[0].subtype = $1
        },
        PeerField(name: "wildcard feedback type") { $0.description.feedback[0].type = $1 },
        PeerField(name: "header extension uri") { $0.description.headerExtensions[0].uri = $1 },
        PeerField(name: "header extension attribute name") {
            $0.description.headerExtensions[0].parameters[0].name = $1
        },
        PeerField(name: "header extension attribute value") {
            $0.description.headerExtensions[0].parameters[0].value = $1
        },
        PeerField(name: "bandwidth type") { $0.description.bandwidth?.type = $1 },
        PeerField(name: "source group semantics") { $0.description.sourceGroups[0].semantics = $1 },
        PeerField(name: "source attribute name") {
            $0.description.sources[0].parameters[0].name = $1
        },
        PeerField(name: "source attribute value") {
            $0.description.sources[0].parameters[0].value = $1
        },
        PeerField(name: "ufrag") { $0.transport.ufrag = $1 },
        PeerField(name: "pwd") { $0.transport.pwd = $1 },
        PeerField(name: "fingerprint hash") { $0.transport.fingerprints[0].hash = $1 },
        PeerField(name: "fingerprint value") { $0.transport.fingerprints[0].value = $1 },
        PeerField(name: "setup") { $0.transport.fingerprints[0].setup = $1 },
        PeerField(name: "candidate foundation") { $0.transport.candidates[0].foundation = $1 },
        PeerField(name: "candidate ip") { $0.transport.candidates[0].ip = $1 },
        PeerField(name: "candidate protocol") {
            $0.transport.candidates[0].transportProtocol = $1
        },
        PeerField(name: "candidate type") { $0.transport.candidates[0].type = $1 },
        PeerField(name: "candidate rel-addr") { $0.transport.candidates[2].relAddr = $1 },
        PeerField(name: "candidate tcptype") {
            $0.transport.candidates[$0.transport.candidates.count - 1].tcpType = $1
        },
        PeerField(name: "candidate id") { $0.transport.candidates[0].id = $1 },
        PeerField(name: "content name") { $0.content.name = $1 },
        PeerField(name: "group member") { $0.group = [$1] },
    ]
}
