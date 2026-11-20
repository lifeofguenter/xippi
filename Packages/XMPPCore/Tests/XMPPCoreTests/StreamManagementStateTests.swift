import Testing

@testable import XMPPCore

@Suite struct StreamManagementStateTests {
    static func message(_ number: Int) -> Element {
        Element.message(id: "m\(number)", body: "\(number)")
    }

    static func enabled() -> StreamManagementState {
        var state = StreamManagementState()
        state.enabled(id: "sm-1", resumable: true, location: nil, max: 300)
        return state
    }

    @Test func threeSendsThenAckOfTwoLeavesOne() throws {
        var state = Self.enabled()
        let stanzas = (1...3).map(Self.message)
        for stanza in stanzas { state.willSend(stanza) }

        let acked = try state.handleAck(h: 2)

        #expect(acked == Array(stanzas.prefix(2)))
        #expect(state.unacked == [stanzas[2]])
        #expect(state.outboundH == 3)
    }

    @Test func inboundHWrapsFromMaxToZero() {
        var state = Self.enabled()
        state.inboundH = .max
        state.received(stanza: Self.message(1))
        #expect(state.inboundH == 0)
        #expect(state.ackElement()[attribute: "h"] == "0")
    }

    @Test func outboundCountWrapsAndAcksAcrossTheWrap() throws {
        var state = Self.enabled()
        state.outboundH = .max - 1
        let stanzas = (1...3).map(Self.message)
        for stanza in stanzas { state.willSend(stanza) }
        #expect(state.outboundH == 1)

        // The last acknowledged count was max - 1; h 0 acknowledges max and 0.
        let acked = try state.handleAck(h: 0)

        #expect(acked == Array(stanzas.prefix(2)))
        #expect(state.unacked == [stanzas[2]])
    }

    @Test func ackOfMoreThanSentThrows() {
        var state = Self.enabled()
        let stanzas = (1...3).map(Self.message)
        for stanza in stanzas { state.willSend(stanza) }

        #expect(throws: SMError.ackOutOfRange) { try state.handleAck(h: 5) }
        #expect(state.unacked == stanzas)
    }

    @Test func ackBelowAnEarlierAckThrows() throws {
        var state = Self.enabled()
        for stanza in (1...3).map(Self.message) { state.willSend(stanza) }
        _ = try state.handleAck(h: 2)

        #expect(throws: SMError.ackOutOfRange) { try state.handleAck(h: 1) }
        #expect(try state.handleAck(h: 2).isEmpty)
        #expect(state.unacked.count == 1)
    }

    @Test func resumedReturnsExactlyTheUnacked() throws {
        var state = Self.enabled()
        let stanzas = (1...5).map(Self.message)
        for stanza in stanzas { state.willSend(stanza) }
        _ = try state.handleAck(h: 1)

        let resend = try state.resumed(serverH: 3)

        #expect(resend == Array(stanzas[3...]))
        #expect(state.unacked == resend)
        #expect(state.outboundH == 5)
    }

    @Test func resumedWithAnImpossibleHThrows() {
        var state = Self.enabled()
        for stanza in (1...2).map(Self.message) { state.willSend(stanza) }
        #expect(throws: SMError.ackOutOfRange) { try state.resumed(serverH: 3) }
    }

    @Test func onlyStanzasAreCounted() {
        var state = Self.enabled()
        state.received(stanza: Element("a", namespace: "urn:xmpp:sm:3", attributes: ["h": "1"]))
        state.received(stanza: Element("features", namespace: "http://etherx.jabber.org/streams"))
        state.willSend(Element("r", namespace: "urn:xmpp:sm:3"))
        #expect(state.inboundH == 0)
        #expect(state.outboundH == 0)

        state.received(stanza: Element("message", namespace: "jabber:client"))
        state.received(stanza: Element("presence", namespace: "jabber:client"))
        state.received(stanza: Element("iq", namespace: "jabber:client"))
        state.willSend(Element.presence())
        #expect(state.inboundH == 3)
        #expect(state.outboundH == 1)
    }

    @Test func nothingIsCountedBeforeSMIsEnabled() {
        var state = StreamManagementState()
        state.willSend(Self.message(1))
        state.received(stanza: Self.message(2))
        #expect(!state.isEnabled)
        #expect(state.outboundH == 0)
        #expect(state.inboundH == 0)
        #expect(state.unacked.isEmpty)
        #expect(state.resumeState == nil)
    }

    @Test func enablingStartsTheCountersAtZero() throws {
        var state = Self.enabled()
        state.willSend(Self.message(1))
        state.received(stanza: Self.message(2))
        state.enabled(id: "sm-2", resumable: true, location: nil, max: nil)
        #expect(state.outboundH == 0)
        #expect(state.inboundH == 0)
        #expect(state.unacked.isEmpty)
        #expect(state.resumeState?.id == "sm-2")
    }

    @Test func resumeStateCarriesTheCounters() throws {
        let jid = try JID("alice@example.com/desk")
        var state = StreamManagementState()
        state.enabled(
            id: "sm-1", resumable: true, location: "[2001:db8::1]:5222", max: 600, boundJID: jid)
        state.willSend(Self.message(1))
        state.received(stanza: Self.message(2))
        state.received(stanza: Self.message(3))

        #expect(
            state.resumeState
                == SMResumeState(
                    id: "sm-1", location: "[2001:db8::1]:5222", maxSeconds: 600, inboundH: 2,
                    outboundH: 1, boundJID: jid))
    }

    @Test func notResumableHasNoResumeState() {
        var state = StreamManagementState()
        state.enabled(id: "sm-1", resumable: false, location: nil, max: nil)
        #expect(state.isEnabled)
        #expect(state.resumeState == nil)

        state.enabled(id: nil, resumable: true, location: nil, max: nil)
        #expect(state.resumeState == nil)
    }

    @Test func enabledFromAResultCarriesTheSession() throws {
        let jid = try JID("alice@example.com/desk")
        let features = ServerFeatures(csi: true, sm: true, rosterVersioning: true)
        let sm = SMResumeState(
            id: "s1", location: "example.com:5222", maxSeconds: 300, inboundH: 0, outboundH: 0,
            boundJID: jid, features: features)
        let result = NegotiationResult(
            boundJID: jid, resumed: false, sm: sm, smEnabled: true, carbonsEnabled: true,
            features: features, newFASTToken: nil, resumeAckedH: nil)
        var state = Self.enabled()
        state.willSend(Self.message(1))

        state.enabled(from: result)

        #expect(state.isEnabled)
        #expect(state.unacked.isEmpty)
        #expect(state.resumeState == sm)

        var notResumable = StreamManagementState()
        notResumable.enabled(
            from: NegotiationResult(
                boundJID: jid, resumed: false, sm: nil, smEnabled: true, carbonsEnabled: false,
                features: features, newFASTToken: nil, resumeAckedH: nil))
        #expect(notResumable.isEnabled)
        #expect(notResumable.resumeState == nil)

        var off = StreamManagementState()
        off.enabled(
            from: NegotiationResult(
                boundJID: jid, resumed: false, sm: nil, smEnabled: false, carbonsEnabled: false,
                features: features, newFASTToken: nil, resumeAckedH: nil))
        #expect(!off.isEnabled)
    }

    @Test func ackAndRequestElements() {
        var state = Self.enabled()
        for number in 1...7 { state.received(stanza: Self.message(number)) }
        #expect(
            state.ackElement()
                == Element("a", namespace: "urn:xmpp:sm:3", attributes: ["h": "7"]))
        #expect(state.requestElement() == Element("r", namespace: "urn:xmpp:sm:3"))
    }
}
