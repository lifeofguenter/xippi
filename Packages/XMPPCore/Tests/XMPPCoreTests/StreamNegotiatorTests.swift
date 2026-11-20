import Foundation
import Testing

@testable import XMPPCore

@Suite struct StreamNegotiatorTests {
    static let serverHeader =
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client'"
        + " xmlns:stream='http://etherx.jabber.org/streams' id='s1' from='example.com'"
        + " version='1.0' xml:lang='en'>"
    static let scramFeatures =
        "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
        + "<mechanism>SCRAM-SHA-1</mechanism></mechanisms></stream:features>"
    static let bindFeatures =
        "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>"
        + "<sm xmlns='urn:xmpp:sm:3'/></stream:features>"

    static func config(
        directTLS: Bool = true, smResume: SMResumeState? = nil, fastToken: FASTToken? = nil,
        requestFASTToken: Bool = false, password: String? = FixtureAccount.password
    ) throws -> NegotiationConfig {
        try FixtureAccount.config(
            jid: "alice@example.com", directTLS: directTLS, fastToken: fastToken,
            requestFASTToken: requestFASTToken, smResume: smResume, password: password)
    }

    /// A direct TLS stream with SCRAM-SHA-1 offered and the auth element sent.
    static func authenticating(_ config: NegotiationConfig) throws -> NegotiationHarness {
        var harness = NegotiationHarness(config: config, tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(serverHeader + scramFeatures)
        return harness
    }

    /// Logged in with SASL1 and the restarted stream's header received.
    static func authenticated(_ config: NegotiationConfig) throws -> NegotiationHarness {
        var harness = try authenticating(config)
        try harness.receive(
            "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</challenge>")
        try harness.receive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</success>")
        try harness.receive(serverHeader)
        _ = harness.takeSent()
        return harness
    }

    static func error(_ body: () throws -> Void) -> NegotiationError? {
        do {
            try body()
            return nil
        } catch let error as NegotiationError {
            return error
        } catch {
            return .unexpected("not a NegotiationError: \(error)")
        }
    }

    // MARK: Recorded exchanges

    @Test func prosodyStartTLSScramBind() throws {
        let config = try FixtureAccount.config(
            jid: "alice@prosody.test", resource: "fixture", directTLS: false)
        var harness = NegotiationHarness(config: config)
        let result = try harness.replay(.load("prosody-starttls-scram-bind"))

        #expect(result.boundJID == (try JID("alice@prosody.test/fixture")))
        #expect(result.smEnabled)
        #expect(result.sm?.id == FixtureAccount.smID)
        #expect(result.sm?.boundJID == result.boundJID)
        #expect(!result.resumed)
        #expect(result.resumeAckedH == nil)
        #expect(result.carbonsEnabled)
        #expect(result.features.sm)
        #expect(result.features.csi)
        #expect(result.features.channelBindings == ["tls-exporter"])
        #expect(!result.features.sasl2)
        #expect(harness.actions.contains(.startTLS))
        #expect(harness.server.mechanisms == ["SCRAM-SHA-1-PLUS"])
    }

    @Test func directTLSSkipsStartTLS() throws {
        let config = try FixtureAccount.config(jid: "alice@prosody.test", directTLS: true)
        var harness = NegotiationHarness(config: config)
        let result = try harness.replay(.load("prosody-directtls-scram-bind"))

        #expect(!harness.actions.contains(.startTLS))
        #expect(result.boundJID.bare == (try JID("alice@prosody.test")))
        #expect(result.boundJID.resourcepart != nil)
        #expect(result.smEnabled)
        #expect(harness.server.mechanisms == ["SCRAM-SHA-1-PLUS"])
    }

    @Test func resumeSucceeds() throws {
        let previous = try JID("alice@prosody.test/fixture")
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 3, outboundH: 3,
            boundJID: previous)
        let config = try FixtureAccount.config(
            jid: "alice@prosody.test", directTLS: true, smResume: resume)
        var harness = NegotiationHarness(config: config)
        let result = try harness.replay(.load("prosody-resume"))

        let sent = NegotiationHarness.elements(
            harness.actions.compactMap {
                if case .send(let element) = $0 { element.xml() } else { nil }
            })
        let resumeElement = try #require(sent.first { $0.name == "resume" })
        #expect(resumeElement.namespace == "urn:xmpp:sm:3")
        #expect(resumeElement[attribute: "previd"] == FixtureAccount.smID)
        #expect(resumeElement[attribute: "h"] == "3")
        #expect(!sent.contains { $0.name == "iq" })
        #expect(result.resumed)
        #expect(result.resumeAckedH == 3)
        #expect(result.boundJID == previous)
        #expect(result.smEnabled)
        #expect(result.sm?.id == FixtureAccount.smID)
    }

    @Test func resumeFailedFallsBackToBind() throws {
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 0, outboundH: 0,
            boundJID: try JID("alice@prosody.test/gone"))
        let config = try FixtureAccount.config(
            jid: "alice@prosody.test", directTLS: true, smResume: resume)
        var harness = NegotiationHarness(config: config)
        let result = try harness.replay(.load("prosody-resume-failed"))

        let sent = NegotiationHarness.elements(
            harness.actions.compactMap {
                if case .send(let element) = $0 { element.xml() } else { nil }
            })
        #expect(sent.contains { $0.name == "resume" })
        #expect(
            sent.contains { $0.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil }
        )
        #expect(sent.contains { $0.name == "enable" && $0.namespace == "urn:xmpp:sm:3" })
        #expect(!result.resumed)
        #expect(result.smEnabled)
        #expect(result.boundJID.bare == (try JID("alice@prosody.test")))
    }

    @Test func ejabberdSASL2Bind2RequestsAToken() throws {
        let config = try FixtureAccount.config(
            jid: "alice@ejabberd.test", directTLS: true, requestFASTToken: true)
        var harness = NegotiationHarness(config: config, sendsDowngradeHash: true)
        let result = try harness.replay(.load("ejabberd-sasl2-bind2"))

        #expect(harness.server.mechanisms == ["SCRAM-SHA-512-PLUS"])
        #expect(result.features.sasl2)
        #expect(result.features.bind2)
        #expect(result.features.fast)
        #expect(result.smEnabled)
        #expect(result.carbonsEnabled)
        #expect(!result.resumed)
        #expect(result.boundJID.bare == (try JID("alice@ejabberd.test")))
        #expect(result.boundJID.resourcepart?.hasPrefix(FixtureAccount.software) == true)
        #expect(result.newFASTToken?.mechanism == HTMechanism.exporterName)
        #expect(result.newFASTToken?.token == FixtureAccount.fastToken)
    }

    @Test func ejabberdFASTLogin() throws {
        let token = FASTToken(
            mechanism: HTMechanism.exporterName, token: FixtureAccount.fastToken,
            expiry: .distantFuture)
        let config = try FixtureAccount.config(
            jid: "alice@ejabberd.test", directTLS: true, fastToken: token)
        var harness = NegotiationHarness(config: config, sendsDowngradeHash: true)
        let result = try harness.replay(.load("ejabberd-fast-login"))

        #expect(harness.server.mechanisms == [HTMechanism.exporterName])
        #expect(!result.fastTokenRejected)
        #expect(!harness.negotiator.fastTokenRejected)
        #expect(result.smEnabled)
        #expect(result.boundJID.bare == (try JID("alice@ejabberd.test")))
    }

    @Test func ejabberdSASL2InlineResume() throws {
        let previous = try JID("alice@ejabberd.test/Xippi.fixture")
        // What the session being resumed learnt after authentication; ejabberd sends no
        // features after an inline resumption (XEP-0198 9.2).
        let remembered = ServerFeatures(
            csi: true, sm: true, rosterVersioning: true, preApproval: true)
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 3, outboundH: 3,
            boundJID: previous, features: remembered)
        let config = try FixtureAccount.config(
            jid: "alice@ejabberd.test", directTLS: true, smResume: resume)
        var harness = NegotiationHarness(config: config, sendsDowngradeHash: true)
        let result = try harness.replay(.load("ejabberd-sasl2-resume"))

        #expect(result.features.csi)
        #expect(result.features.rosterVersioning)
        #expect(result.features.preApproval)
        #expect(result.features.sasl2)
        #expect(result.features.bind2)
        #expect(result.features.fast)
        #expect(result.features.channelBindings == ["tls-exporter", "tls-server-end-point"])
        #expect(result.sm?.features == result.features)

        #expect(result.resumed)
        #expect(result.resumeAckedH == 3)
        // The server names the resumed session's full JID; it wins over the remembered one.
        #expect(result.boundJID == (try JID("alice@ejabberd.test/Xippi.uW4H92fFhH")))
        #expect(result.boundJID != previous)
        #expect(result.sm?.boundJID == result.boundJID)
    }

    // MARK: Example exchanges (XEP-0388, XEP-0386, XEP-0484)

    @Test func sasl2Bind2Fast() throws {
        let config = try FixtureAccount.config(
            jid: "alice@example.com", directTLS: true, requestFASTToken: true)
        var harness = NegotiationHarness(config: config, tls: NegotiationHarness.unboundTLS)
        let result = try harness.replay(.load("sasl2-bind2-fast"))

        let sent = NegotiationHarness.elements(
            harness.actions.compactMap {
                if case .send(let element) = $0 { element.xml() } else { nil }
            })
        let authenticates = sent.filter { $0.name == "authenticate" }
        #expect(authenticates.count == 1)
        let authenticate = try #require(authenticates.first)
        #expect(authenticate.namespace == "urn:xmpp:sasl:2")
        let userAgent = try #require(authenticate.child("user-agent", namespace: "urn:xmpp:sasl:2"))
        #expect(userAgent[attribute: "id"] == FixtureAccount.clientID.uuidString.lowercased())
        #expect(userAgent.child("software", namespace: "urn:xmpp:sasl:2")?.text == "Xippi")
        #expect(userAgent.child("device", namespace: "urn:xmpp:sasl:2")?.text == "Mac")
        let bind = try #require(authenticate.child("bind", namespace: "urn:xmpp:bind:0"))
        #expect(bind.child("tag", namespace: "urn:xmpp:bind:0")?.text == "Xippi")
        let smEnable = try #require(bind.child("enable", namespace: "urn:xmpp:sm:3"))
        #expect(smEnable[attribute: "resume"] == "true")
        #expect(bind.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
        let request = try #require(
            authenticate.child("request-token", namespace: "urn:xmpp:fast:0"))
        #expect(request[attribute: "mechanism"] == "HT-SHA-256-NONE")
        #expect(!sent.contains { $0.name == "iq" })

        #expect(result.carbonsEnabled)
        #expect(result.smEnabled)
        #expect(result.sm?.id == FixtureAccount.smID)
        #expect(result.boundJID == (try JID("alice@example.com/Xippi.4232f4d4")))
        #expect(
            result.newFASTToken
                == FASTToken(
                    mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken,
                    expiry: Date(timeIntervalSince1970: 1_893_456_000)))
        #expect(result.features.csi)
        #expect(result.features.rosterVersioning)
        #expect(!result.carbonsNeedIQ)
        #expect(result.sm?.features == result.features)
    }

    @Test func sasl2WithoutBind2UsesLegacyBind() throws {
        var harness = NegotiationHarness(
            config: try Self.config(), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism></authentication></stream:features>")
        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        try harness.receive(
            "<success xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
                + "<authorization-identifier>alice@example.com</authorization-identifier>"
                + "</success>")
        #expect(!harness.actions.contains(.restartParser))
        _ = harness.takeSent()
        try harness.receive(Self.bindFeatures)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(bind.child("bind", namespace: "urn:ietf:params:xml:ns:xmpp-bind") != nil)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(carbons.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        #expect(
            NegotiationHarness.elements(harness.takeSent())
                == [Element("enable", namespace: "urn:xmpp:sm:3", attributes: ["resume": "true"])])
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3' id='x1' resume='true' max='300'/>")

        let result = try #require(harness.result)
        #expect(result.boundJID == (try JID("alice@example.com/r1")))
        #expect(result.carbonsEnabled)
        #expect(result.sm?.maxSeconds == 300)
        #expect(result.features.sasl2)
        #expect(!result.features.bind2)
    }

    @Test func rejectedFASTTokenFallsBackToThePassword() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token, requestFASTToken: true),
            tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        let first = try #require(NegotiationHarness.elements(harness.takeSent()).last)
        #expect(first[attribute: "mechanism"] == "HT-SHA-256-NONE")
        #expect(first.child("fast", namespace: "urn:xmpp:fast:0") != nil)

        try harness.receive(
            "<failure xmlns='urn:xmpp:sasl:2'>"
                + "<credentials-expired xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        let second = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(second[attribute: "mechanism"] == "SCRAM-SHA-1")
        #expect(second.child("fast", namespace: "urn:xmpp:fast:0") == nil)
        #expect(
            second.child("request-token", namespace: "urn:xmpp:fast:0")?[attribute: "mechanism"]
                == "HT-SHA-256-NONE")

        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        try harness.receive(
            "<success xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
                + "<authorization-identifier>alice@example.com</authorization-identifier>"
                + "<token xmlns='urn:xmpp:fast:0' token='new' expiry='2030-01-01T00:00:00.5+01:00'/>"
                + "</success>")
        _ = harness.takeSent()
        try harness.receive(
            "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></stream:features>")
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive("<iq type='error' id='\(carbons.id ?? "")'/>")

        let result = try #require(harness.result)
        #expect(result.fastTokenRejected)
        #expect(harness.negotiator.fastTokenRejected)
        #expect(!result.carbonsEnabled)
        #expect(!result.smEnabled)
        #expect(
            result.newFASTToken
                == FASTToken(
                    mechanism: "HT-SHA-256-NONE", token: "new",
                    expiry: Date(timeIntervalSince1970: 1_893_452_400.5)))
    }

    @Test func rejectedFASTTokenWithoutPasswordFails() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token, password: nil),
            tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        let error = Self.error {
            try harness.receive(
                "<failure xmlns='urn:xmpp:sasl:2'>"
                    + "<credentials-expired xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>"
                    + "<text>Token expired</text></failure>")
        }
        #expect(error == .authFailed(condition: "credentials-expired", text: "Token expired"))
        #expect(harness.negotiator.fastTokenRejected)
    }

    /// XEP-0484 5.1: whatever the failure, the client discards the token and falls back;
    /// `temporary-auth-failure` is not a refusal of the token (below).
    @Test func anyFailureWithATokenDiscardsIt() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        _ = harness.takeSent()
        try harness.receive(
            "<failure xmlns='urn:xmpp:sasl:2'>"
                + "<malformed-request xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        let retry = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(retry[attribute: "mechanism"] == "SCRAM-SHA-1")
        #expect(harness.negotiator.fastTokenRejected)
    }

    /// RFC 6120 6.5.10: `temporary-auth-failure` says nothing about the token. It is kept,
    /// the password is not tried on this stream, and the failure goes to the connection,
    /// which tries again later.
    @Test func temporaryAuthFailureKeepsTheToken() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        _ = harness.takeSent()
        let error = Self.error {
            try harness.receive(
                "<failure xmlns='urn:xmpp:sasl:2'>"
                    + "<temporary-auth-failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>"
            )
        }
        #expect(error == .authFailed(condition: "temporary-auth-failure", text: nil))
        #expect(!harness.negotiator.fastTokenRejected)
        #expect(harness.takeSent().isEmpty)
    }

    @Test func rejectedFASTTokenAndPasswordBothFail() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        try harness.receive(
            "<failure xmlns='urn:xmpp:sasl:2'>"
                + "<credentials-expired xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        let error = Self.error {
            try harness.receive(
                "<failure xmlns='urn:xmpp:sasl:2'>"
                    + "<not-authorized xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/></failure>")
        }
        #expect(error == .authFailed(condition: "not-authorized", text: nil))
        #expect(harness.negotiator.fastTokenRejected)
    }

    @Test func sasl2InlineResumeFailureBindsInline() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 4, outboundH: 9,
            boundJID: try JID("alice@example.com/Xippi.old"))
        var harness = NegotiationHarness(
            config: try Self.config(smResume: resume), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline><sm xmlns='urn:xmpp:sm:3'/>"
                + "<bind xmlns='urn:xmpp:bind:0'><inline><feature var='urn:xmpp:sm:3'/></inline>"
                + "</bind></inline></authentication></stream:features>")
        let authenticate = try #require(NegotiationHarness.elements(harness.takeSent()).last)
        let resumeElement = try #require(authenticate.child("resume", namespace: "urn:xmpp:sm:3"))
        #expect(resumeElement[attribute: "previd"] == "old")
        #expect(resumeElement[attribute: "h"] == "4")
        let bind = try #require(authenticate.child("bind", namespace: "urn:xmpp:bind:0"))
        #expect(bind.child("enable", namespace: "urn:xmpp:sm:3") != nil)
        #expect(bind.child("enable", namespace: "urn:xmpp:carbons:2") == nil)

        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        _ = harness.takeSent()
        try harness.receive(
            "<success xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
                + "<authorization-identifier>alice@example.com/Xippi.new</authorization-identifier>"
                + "<failed xmlns='urn:xmpp:sm:3' h='7'>"
                + "<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
                + "<bound xmlns='urn:xmpp:bind:0'><failed xmlns='urn:xmpp:sm:3'>"
                + "<internal-server-error xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>"
                + "</bound></success><stream:features><sm xmlns='urn:xmpp:sm:3'/></stream:features>"
        )
        // Carbons were not in the Bind2 list and SM is off: the carbons IQ, and no second
        // <enable/> after SM failed inline.
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(carbons.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        #expect(harness.takeSent().isEmpty)

        let result = try #require(harness.result)
        #expect(!result.resumed)
        #expect(result.resumeAckedH == 7)
        #expect(!result.smEnabled)
        #expect(result.carbonsEnabled)
        #expect(!result.carbonsNeedIQ)
        #expect(result.boundJID == (try JID("alice@example.com/Xippi.new")))
    }

    @Test func sasl2ContinueIsRefused() throws {
        var harness = NegotiationHarness(
            config: try Self.config(), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism></authentication></stream:features>")
        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        let error = Self.error {
            try harness.receive(
                "<continue xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
                    + "<tasks><task>TOTP</task></tasks><text>2FA required</text></continue>")
        }
        #expect(error == .authFailed(condition: "aborted", text: "2FA required"))
    }

    // MARK: TLS

    @Test func tlsRequiredRefusesPlainText() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: false))
        try harness.start()
        let error = Self.error { try harness.receive(Self.serverHeader + Self.scramFeatures) }
        #expect(error == .tlsRequired)
    }

    @Test func startTLSFailureIsTLSRequired() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: false))
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>"
        )
        let error = Self.error {
            try harness.receive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        }
        #expect(error == .tlsRequired)
    }

    /// RFC 6120 5.4.3.3: what arrives with `<proceed/>` in the same read was not protected by
    /// TLS and must not reach the stream (STARTTLS command injection).
    @Test func proceedDiscardsPlaintextInTheSameRead() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: false))
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>"
        )
        _ = harness.takeSent()

        var parser = XMLStreamParser()
        _ = parser.feed(Data(Self.serverHeader.utf8))
        let events = parser.feed(
            Data(
                ("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" + Self.scramFeatures
                    + "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>"
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + "evil.example</see-other-host></stream:error>").utf8))
        #expect(events.count == 4)
        #expect(try harness.negotiator.handle(events[0]) == [.startTLS])
        for event in events.dropFirst() {
            #expect(try harness.negotiator.handle(event) == [])
        }

        #expect(
            harness.negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
                == [.sendHeader(to: "example.com", from: "alice@example.com")])
    }

    @Test func headerCarriesFromOnlyAfterTLS() throws {
        var negotiator = StreamNegotiator(config: try Self.config(directTLS: false))
        #expect(negotiator.start() == [.sendHeader(to: "example.com", from: nil)])

        var direct = StreamNegotiator(config: try Self.config(directTLS: true))
        #expect(direct.start() == [])
        #expect(
            direct.tlsEstablished(NegotiationHarness.unboundTLS)
                == [.sendHeader(to: "example.com", from: "alice@example.com")])

        var tlsFirst = StreamNegotiator(config: try Self.config(directTLS: true))
        #expect(tlsFirst.tlsEstablished(NegotiationHarness.unboundTLS) == [])
        #expect(tlsFirst.start() == [.sendHeader(to: "example.com", from: "alice@example.com")])
    }

    @Test func streamHeaderFormat() {
        #expect(
            StreamNegotiator.streamHeader(to: "example.com", from: "alice@example.com")
                == "<?xml version='1.0'?><stream:stream from='alice@example.com'"
                + " to='example.com' version='1.0' xml:lang='en' xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>")
        #expect(
            StreamNegotiator.streamHeader(to: "example.com", from: nil)
                == "<?xml version='1.0'?><stream:stream to='example.com' version='1.0'"
                + " xml:lang='en' xmlns='jabber:client'"
                + " xmlns:stream='http://etherx.jabber.org/streams'>")
    }

    // MARK: Authentication

    @Test func authFailureSurfaces() throws {
        var harness = try Self.authenticating(try Self.config())
        let error = Self.error {
            try harness.receive(
                "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")
        }
        #expect(error == .authFailed(condition: "not-authorized", text: nil))
    }

    @Test func wrongServerSignatureFails() throws {
        var harness = try Self.authenticating(try Self.config())
        try harness.receive(
            "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</challenge>")
        let forged = Data("v=\(Data(repeating: 1, count: 20).base64EncodedString())".utf8)
        let error = Self.error {
            try harness.receive(
                "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                    + forged.base64EncodedString() + "</success>")
        }
        #expect(error == .sasl(.serverSignatureMismatch))
    }

    @Test func missingPasswordIsAnUnusableCredential() throws {
        var harness = NegotiationHarness(config: try Self.config(password: nil))
        try harness.start()
        let error = Self.error { try harness.receive(Self.serverHeader + Self.scramFeatures) }
        #expect(error == .sasl(.unusableCredential(.password)))
    }

    @Test func saslSuccessRestartsTheStream() throws {
        var harness = try Self.authenticating(try Self.config())
        try harness.receive(
            "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</challenge>")
        let before = harness.actions.count
        try harness.receive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</success>")
        #expect(
            Array(harness.actions[before...])
                == [.restartParser, .sendHeader(to: "example.com", from: "alice@example.com")])
    }

    // MARK: Binding

    @Test func bindErrorSurfaces() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(Self.bindFeatures)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        let error = Self.error {
            try harness.receive(
                "<iq type='error' id='\(bind.id ?? "")'><error type='cancel'>"
                    + "<not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        }
        #expect(error == .bindFailed(StanzaError(type: .cancel, condition: .notAllowed)))
    }

    @Test func boundJIDOfAnotherAccountIsRefused() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(Self.bindFeatures)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        let error = Self.error {
            try harness.receive(
                "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                    + "<jid>mallory@example.com/r1</jid></bind></iq>")
        }
        #expect(error == .unexpected("Bound JID is not the account's"))
    }

    @Test func requiredSessionIsEstablished() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(
            "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>"
                + "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></stream:features>")
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let session = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(session.child("session", namespace: "urn:ietf:params:xml:ns:xmpp-session") != nil)
        try harness.receive("<iq type='result' id='\(session.id ?? "")'/>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(carbons.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
    }

    /// Stanzas that come between binding and the end of negotiation are handed over, not lost.
    @Test func stanzasBeforeTheEndArePending() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(Self.bindFeatures)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<message from='bob@example.com/x' to='alice@example.com/r1' id='m1'><body>hi</body>"
                + "</message><iq type='result' id='\(carbons.id ?? "")'/>")
        try harness.receive(
            "<iq type='get' id='p1' from='example.com'><ping xmlns='urn:xmpp:ping'/></iq>"
                + "<enabled xmlns='urn:xmpp:sm:3'/>")

        let result = try #require(harness.result)
        #expect(result.pendingStanzas.map(\.name) == ["message", "iq"])
        #expect(result.smEnabled)
        #expect(result.sm == nil)
    }

    @Test func resumeFailedReportsTheAckedCount() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 2, outboundH: 5,
            boundJID: try JID("alice@example.com/r0"))
        var harness = try Self.authenticated(try Self.config(smResume: resume))
        try harness.receive(Self.bindFeatures)
        #expect(
            NegotiationHarness.elements(harness.takeSent())
                == [
                    Element(
                        "resume", namespace: "urn:xmpp:sm:3",
                        attributes: ["previd": "old", "h": "2"])
                ])
        try harness.receive(
            "<failed xmlns='urn:xmpp:sm:3' h='4'>"
                + "<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>")
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3' id='new' resume='1'/>")

        let result = try #require(harness.result)
        #expect(!result.resumed)
        #expect(result.resumeAckedH == 4)
        #expect(result.sm?.id == "new")
    }

    @Test func resumeWithoutTheBoundJIDBindsFresh() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 2, outboundH: 5, boundJID: nil)
        var harness = try Self.authenticated(try Self.config(smResume: resume))
        try harness.receive(Self.bindFeatures)
        let sent = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(sent.name == "iq")
    }

    // MARK: Stream errors and broken streams

    @Test func streamErrorSeeOtherHost() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: true))
        try harness.start()
        let error = Self.error {
            try harness.receive(
                Self.serverHeader
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + "other.example:5222</see-other-host></stream:error>")
        }
        #expect(error == .seeOtherHost("other.example:5222"))
    }

    @Test func seeOtherHostIsTrimmedAndTakesIPv6() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: true))
        try harness.start()
        let error = Self.error {
            try harness.receive(
                Self.serverHeader
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>\n"
                    + "  [2001:41D0:1:A49b::1]:9222\n</see-other-host></stream:error>")
        }
        #expect(error == .seeOtherHost("[2001:41D0:1:A49b::1]:9222"))
    }

    @Test(arguments: [
        "other example", "other.example:0", "other.example:70000", "other.example:52a",
        "a:b:c", "", "[::1", "<x>",
    ])
    func malformedSeeOtherHostIsNotFollowed(value: String) throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: true))
        try harness.start()
        let escaped = value.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let error = Self.error {
            try harness.receive(
                Self.serverHeader
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + escaped + "</see-other-host></stream:error>")
        }
        #expect(error == .streamError(condition: "see-other-host", text: nil))
    }

    @Test func seeOtherHostBeforeTLSStaysInTheDomain() throws {
        var other = NegotiationHarness(config: try Self.config(directTLS: false))
        try other.start()
        let refused = Self.error {
            try other.receive(
                Self.serverHeader
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + "other.example:5222</see-other-host></stream:error>")
        }
        #expect(refused == .streamError(condition: "see-other-host", text: nil))

        var same = NegotiationHarness(config: try Self.config(directTLS: false))
        try same.start()
        let followed = Self.error {
            try same.receive(
                Self.serverHeader
                    + "<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>"
                    + "example.com:5223</see-other-host></stream:error>")
        }
        #expect(followed == .seeOtherHost("example.com:5223"))
    }

    @Test func streamErrorEndsNegotiation() throws {
        var harness = try Self.authenticating(try Self.config())
        let error = Self.error {
            try harness.receive(
                "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/>"
                    + "<text xmlns='urn:ietf:params:xml:ns:xmpp-streams'>Replaced</text>"
                    + "</stream:error>")
        }
        #expect(error == .streamError(condition: "conflict", text: "Replaced"))
        #expect(error?.streamErrorToSend == nil)
        // The negotiator stays failed.
        #expect(
            Self.error { _ = try harness.negotiator.handle(.streamClosed) }
                == .streamError(condition: "conflict", text: "Replaced"))
    }

    @Test func contentNamespaceMustBeClientNamespace() throws {
        var harness = NegotiationHarness(config: try Self.config())
        try harness.start()
        let error = Self.error {
            try harness.receive(
                "<stream:stream xmlns='jabber:server' xmlns:stream='http://etherx.jabber.org/streams'"
                    + " version='1.0'>")
        }
        #expect(error == .invalidStream(condition: "invalid-namespace"))
        #expect(
            error?.streamErrorToSend
                == Element(
                    "error", namespace: "http://etherx.jabber.org/streams",
                    children: [
                        .element(
                            Element(
                                "invalid-namespace",
                                namespace: "urn:ietf:params:xml:ns:xmpp-streams"))
                    ]))
    }

    @Test(arguments: ["0.9", "", "2.0", "x"])
    func unsupportedVersionIsAStreamError(version: String) throws {
        var harness = NegotiationHarness(config: try Self.config())
        try harness.start()
        let error = Self.error {
            try harness.receive(
                "<stream:stream xmlns='jabber:client'"
                    + " xmlns:stream='http://etherx.jabber.org/streams' version='\(version)'>")
        }
        #expect(error == .invalidStream(condition: "unsupported-version"))
    }

    @Test(arguments: [
        (XMLStreamError.notWellFormed("x"), "not-well-formed"),
        (.restrictedXML("x"), "restricted-xml"),
        (.policyViolation("x"), "policy-violation"),
        (.invalidNamespace("x"), "invalid-namespace"),
        (.invalidUTF8, "unsupported-encoding"),
    ])
    func parserFailuresMapToStreamErrors(failure: XMLStreamError, condition: String) throws {
        var negotiator = StreamNegotiator(config: try Self.config())
        _ = negotiator.start()
        _ = negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
        let error = Self.error { _ = try negotiator.handle(.failed(failure)) }
        #expect(error == .invalidStream(condition: condition))
    }

    @Test func malformedXMLFromTheServerIsNotWellFormed() throws {
        var harness = NegotiationHarness(config: try Self.config())
        try harness.start()
        let error = Self.error { try harness.receive(Self.serverHeader + "<stream:features></x>") }
        #expect(error == .invalidStream(condition: "not-well-formed"))
    }

    @Test func serverClosingTheStreamEndsNegotiation() throws {
        var harness = try Self.authenticating(try Self.config())
        let error = Self.error { try harness.receive("</stream:stream>") }
        #expect(error == .unexpected("The server closed the stream"))
    }

    @Test func unexpectedElementDuringSASLFails() throws {
        var harness = try Self.authenticating(try Self.config())
        let error = Self.error { try harness.receive("<message><body>x</body></message>") }
        #expect(error == .unexpected("Unexpected <message> during authentication"))
    }

    // MARK: Secrets

    @Test func configDescriptionHasNoSecrets() throws {
        let token = FASTToken(mechanism: "HT-SHA-256-NONE", token: "tok-secret", expiry: .now)
        let config = try FixtureAccount.config(
            jid: "alice@example.com", directTLS: true, fastToken: token,
            password: "pw-secret")
        for text in [
            config.description, String(reflecting: config), String(describing: config),
            "\(Mirror(reflecting: config).children.map { "\($0.label ?? ""): \($0.value)" })",
        ] {
            #expect(!text.contains("pw-secret"))
            #expect(!text.contains("tok-secret"))
        }
        var negotiator = StreamNegotiator(config: config)
        _ = negotiator.start()
        let text = "\(negotiator) \(String(reflecting: negotiator))"
        #expect(!text.contains("pw-secret"))
        #expect(!text.contains("tok-secret"))
    }
}

// MARK: - Fix round 1

extension StreamNegotiatorTests {
    /// SASL2 with SCRAM-SHA-1 up to the client's response to the challenge. `inline` is the
    /// content of `<authentication><inline>`, `preAuth` more features beside it.
    static func sasl2Authenticating(
        _ config: NegotiationConfig, inline: String, preAuth: String = ""
    ) throws -> NegotiationHarness {
        var harness = NegotiationHarness(config: config, tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            serverHeader + "<stream:features>" + preAuth
                + "<authentication xmlns='urn:xmpp:sasl:2'><mechanism>SCRAM-SHA-1</mechanism>"
                + "<inline>" + inline + "</inline></authentication></stream:features>")
        try harness.receive("<challenge xmlns='urn:xmpp:sasl:2'>{{sasl}}</challenge>")
        _ = harness.takeSent()
        return harness
    }

    static func sasl2Success(_ identifier: String, _ extra: String = "") -> String {
        "<success xmlns='urn:xmpp:sasl:2'><additional-data>{{sasl}}</additional-data>"
            + "<authorization-identifier>\(identifier)</authorization-identifier>" + extra
            + "</success>"
    }

    /// Bound as alice@example.com/r1 on the legacy path, with `features` after
    /// authentication; returns the carbons IQ, the last element sent.
    static func bound(_ harness: inout NegotiationHarness, features: String = bindFeatures)
        throws -> Element
    {
        try harness.receive(features)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        return try #require(NegotiationHarness.elements(harness.takeSent()).first)
    }

    static let smEnable = Element(
        "enable", namespace: "urn:xmpp:sm:3", attributes: ["resume": "true"])

    // MARK: Bind2 without some inline features (I1)

    @Test func bind2WithoutInlineFeaturesRunsTheSessionSteps() throws {
        var harness = try Self.sasl2Authenticating(
            try Self.config(), inline: "<bind xmlns='urn:xmpp:bind:0'/>")
        try harness.receive(
            Self.sasl2Success("alice@example.com/Xippi.a1", "<bound xmlns='urn:xmpp:bind:0'/>")
                + "<stream:features><sm xmlns='urn:xmpp:sm:3'/></stream:features>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        #expect(carbons.child("enable", namespace: "urn:xmpp:carbons:2") != nil)
        #expect(harness.result == nil)

        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        #expect(NegotiationHarness.elements(harness.takeSent()) == [Self.smEnable])
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3' id='s2' resume='true'/>")

        let result = try #require(harness.result)
        #expect(result.boundJID == (try JID("alice@example.com/Xippi.a1")))
        #expect(result.carbonsEnabled)
        #expect(!result.carbonsNeedIQ)
        #expect(result.smEnabled)
        #expect(result.sm?.id == "s2")
        #expect(result.sm?.boundJID == result.boundJID)
    }

    /// SM is on from `<bound>`, so a carbons IQ now would be counted before the session's SM
    /// state exists: it is left to the session.
    @Test func bind2WithInlineSMOnlyLeavesCarbonsToTheSession() throws {
        var harness = try Self.sasl2Authenticating(
            try Self.config(),
            inline:
                "<bind xmlns='urn:xmpp:bind:0'><inline><feature var='urn:xmpp:sm:3'/></inline></bind>"
        )
        try harness.receive(
            Self.sasl2Success(
                "alice@example.com/Xippi.a1",
                "<bound xmlns='urn:xmpp:bind:0'>"
                    + "<enabled xmlns='urn:xmpp:sm:3' id='s3' resume='true'/></bound>")
                + "<stream:features><sm xmlns='urn:xmpp:sm:3'/></stream:features>")

        #expect(harness.takeSent().isEmpty)
        let result = try #require(harness.result)
        #expect(result.smEnabled)
        #expect(result.sm?.id == "s3")
        #expect(!result.carbonsEnabled)
        #expect(result.carbonsNeedIQ)
    }

    @Test func bind2WithInlineCarbonsOnlyEnablesSMAfter() throws {
        var harness = try Self.sasl2Authenticating(
            try Self.config(),
            inline: "<bind xmlns='urn:xmpp:bind:0'><inline>"
                + "<feature var='urn:xmpp:carbons:2'/></inline></bind>")
        try harness.receive(
            Self.sasl2Success("alice@example.com/Xippi.a1", "<bound xmlns='urn:xmpp:bind:0'/>")
                + "<stream:features><sm xmlns='urn:xmpp:sm:3'/></stream:features>")
        #expect(NegotiationHarness.elements(harness.takeSent()) == [Self.smEnable])
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3' id='s4' resume='true'/>")

        let result = try #require(harness.result)
        #expect(result.carbonsEnabled)
        #expect(!result.carbonsNeedIQ)
        #expect(result.smEnabled)
        #expect(result.sm?.id == "s4")
    }

    @Test func bind2WithoutSMAnywhereFinishesAfterCarbons() throws {
        var harness = try Self.sasl2Authenticating(
            try Self.config(),
            inline: "<bind xmlns='urn:xmpp:bind:0'><inline>"
                + "<feature var='urn:xmpp:carbons:2'/></inline></bind>")
        try harness.receive(
            Self.sasl2Success("alice@example.com/Xippi.a1", "<bound xmlns='urn:xmpp:bind:0'/>")
                + "<stream:features/>")
        #expect(harness.takeSent().isEmpty)
        let result = try #require(harness.result)
        #expect(result.carbonsEnabled)
        #expect(!result.smEnabled)
    }

    // MARK: SASL2 security checks (I2)

    @Test func sasl2SuccessWithoutServerSignatureFails() throws {
        var harness = try Self.sasl2Authenticating(try Self.config(), inline: "")
        let error = Self.error {
            try harness.receive(
                "<success xmlns='urn:xmpp:sasl:2'>"
                    + "<authorization-identifier>alice@example.com</authorization-identifier>"
                    + "</success>")
        }
        #expect(error == .sasl(.serverSignatureMismatch))
        #expect(harness.result == nil)
        #expect(Self.error { _ = try harness.negotiator.handle(.streamClosed) } == error)
    }

    @Test func sasl2SuccessWithAForgedServerSignatureFails() throws {
        var harness = try Self.sasl2Authenticating(try Self.config(), inline: "")
        let forged = Data("v=\(Data(repeating: 1, count: 20).base64EncodedString())".utf8)
        let error = Self.error {
            try harness.receive(
                "<success xmlns='urn:xmpp:sasl:2'><additional-data>"
                    + forged.base64EncodedString() + "</additional-data>"
                    + "<authorization-identifier>alice@example.com</authorization-identifier>"
                    + "</success>")
        }
        #expect(error == .sasl(.serverSignatureMismatch))
        #expect(harness.result == nil)
    }

    @Test func fastSuccessWithoutTheResponderFails() throws {
        let token = FASTToken(
            mechanism: "HT-SHA-256-NONE", token: FixtureAccount.fastToken, expiry: .distantFuture)
        var harness = NegotiationHarness(
            config: try Self.config(fastToken: token, password: nil),
            tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader
                + "<stream:features><authentication xmlns='urn:xmpp:sasl:2'>"
                + "<mechanism>SCRAM-SHA-1</mechanism><inline>"
                + "<fast xmlns='urn:xmpp:fast:0'><mechanism>HT-SHA-256-NONE</mechanism></fast>"
                + "</inline></authentication></stream:features>")
        let error = Self.error {
            try harness.receive(
                "<success xmlns='urn:xmpp:sasl:2'>"
                    + "<authorization-identifier>alice@example.com</authorization-identifier>"
                    + "</success>")
        }
        #expect(error == .sasl(.serverSignatureMismatch))
        #expect(harness.result == nil)
    }

    @Test func sasl2AuthorizationIdentifierOfAnotherAccountFails() throws {
        var harness = try Self.sasl2Authenticating(try Self.config(), inline: "")
        let error = Self.error {
            try harness.receive(Self.sasl2Success("mallory@example.com/x"))
        }
        #expect(error == .unexpected("Authorization identifier is not the account's"))
        #expect(Self.error { _ = try harness.negotiator.handle(.streamClosed) } == error)
    }

    @Test func sasl2ResumedForAnotherAccountFails() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 1, outboundH: 1,
            boundJID: try JID("alice@example.com/Xippi.old"))
        var harness = try Self.sasl2Authenticating(
            try Self.config(smResume: resume), inline: "<sm xmlns='urn:xmpp:sm:3'/>")
        let error = Self.error {
            try harness.receive(
                Self.sasl2Success(
                    "mallory@example.com/Xippi.old",
                    "<resumed xmlns='urn:xmpp:sm:3' previd='old' h='1'/>"))
        }
        #expect(error == .unexpected("Authorization identifier is not the account's"))
        #expect(harness.result == nil)
    }

    // MARK: Phases (I4)

    @Test func phasesOfALegacyLogin() throws {
        let config = try FixtureAccount.config(
            jid: "alice@prosody.test", resource: "fixture", directTLS: false)
        var harness = NegotiationHarness(config: config)
        _ = try harness.replay(.load("prosody-starttls-scram-bind"))
        #expect(harness.phases == [.connecting, .securing, .authenticating, .binding, .done])
    }

    @Test func phasesOfASASL2Login() throws {
        let config = try FixtureAccount.config(
            jid: "alice@ejabberd.test", directTLS: true, requestFASTToken: true)
        var harness = NegotiationHarness(config: config, sendsDowngradeHash: true)
        _ = try harness.replay(.load("ejabberd-sasl2-bind2"))
        #expect(harness.phases == [.connecting, .authenticating, .binding, .done])
    }

    @Test func phasesOfAResume() throws {
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 3, outboundH: 3,
            boundJID: try JID("alice@prosody.test/fixture"))
        var harness = NegotiationHarness(
            config: try FixtureAccount.config(
                jid: "alice@prosody.test", directTLS: true, smResume: resume))
        _ = try harness.replay(.load("prosody-resume"))
        #expect(harness.phases == [.connecting, .authenticating, .resuming, .done])
    }

    @Test func phasesOfAFailedResume() throws {
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 0, outboundH: 0,
            boundJID: try JID("alice@prosody.test/gone"))
        var harness = NegotiationHarness(
            config: try FixtureAccount.config(
                jid: "alice@prosody.test", directTLS: true, smResume: resume))
        _ = try harness.replay(.load("prosody-resume-failed"))
        #expect(harness.phases == [.connecting, .authenticating, .resuming, .binding, .done])
    }

    @Test func phasesOfASASL2InlineResume() throws {
        let resume = SMResumeState(
            id: FixtureAccount.smID, location: nil, maxSeconds: nil, inboundH: 3, outboundH: 3,
            boundJID: try JID("alice@ejabberd.test/Xippi.fixture"))
        var harness = NegotiationHarness(
            config: try FixtureAccount.config(
                jid: "alice@ejabberd.test", directTLS: true, smResume: resume),
            sendsDowngradeHash: true)
        _ = try harness.replay(.load("ejabberd-sasl2-resume"))
        #expect(harness.phases == [.connecting, .authenticating, .resuming, .done])
    }

    @Test func directTLSWaitsForTLSInSecuring() throws {
        var negotiator = StreamNegotiator(config: try Self.config(directTLS: true))
        #expect(negotiator.phase == .connecting)
        _ = negotiator.start()
        #expect(negotiator.phase == .securing)
        _ = negotiator.tlsEstablished(NegotiationHarness.unboundTLS)
        #expect(negotiator.phase == .authenticating)
    }

    @Test func failedNegotiationIsDone() throws {
        var harness = NegotiationHarness(config: try Self.config(directTLS: false))
        try harness.start()
        _ = Self.error { try harness.receive(Self.serverHeader + Self.scramFeatures) }
        #expect(harness.negotiator.phase == .done)
        #expect(harness.phases == [.connecting, .done])
    }

    // MARK: Features after an inline resumption (I5)

    @Test func inlineResumeReportsThePreAuthFeatures() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 2, outboundH: 2,
            boundJID: try JID("alice@example.com/Xippi.old"))
        var harness = try Self.sasl2Authenticating(
            try Self.config(smResume: resume),
            inline: "<sm xmlns='urn:xmpp:sm:3'/><bind xmlns='urn:xmpp:bind:0'><inline>"
                + "<feature var='urn:xmpp:csi:0'/><feature var='urn:xmpp:sm:3'/></inline></bind>",
            preAuth: "<sub xmlns='urn:xmpp:features:pre-approval'/>")
        try harness.receive(
            Self.sasl2Success(
                "alice@example.com", "<resumed xmlns='urn:xmpp:sm:3' previd='old' h='2'/>"))

        let result = try #require(harness.result)
        #expect(result.resumed)
        #expect(result.features.csi)
        #expect(result.features.sm)
        #expect(result.features.preApproval)
        #expect(result.features.bind2)
        #expect(result.boundJID == (try JID("alice@example.com/Xippi.old")))
    }

    // MARK: Minor findings

    /// M1: an element of the negotiation protocols out of place is an error; unknown
    /// extensions are ignored.
    @Test func sessionStepsRefuseNegotiationElements() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(Self.bindFeatures)
        try harness.receive("<unknown xmlns='urn:example:extension'/>")
        let error = Self.error {
            try harness.receive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        }
        #expect(error == .unexpected("Unexpected <success> after authentication"))
    }

    /// M2: `tlsEstablished` in the wrong state ends the negotiation.
    @Test func tlsEstablishedOutOfOrderFails() throws {
        var negotiator = StreamNegotiator(config: try Self.config(directTLS: false))
        _ = negotiator.start()
        #expect(negotiator.tlsEstablished(NegotiationHarness.unboundTLS) == [])
        #expect(negotiator.phase == .done)
        #expect(
            Self.error { _ = try negotiator.handle(.streamClosed) }
                == .unexpected("TLS established out of order"))
    }

    /// M3: the bind id answered by someone other than the server or the account is not the
    /// answer.
    @Test func bindAnswerFromAStrangerIsNotTheAnswer() throws {
        var harness = try Self.authenticated(try Self.config())
        try harness.receive(Self.bindFeatures)
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")' from='mallory@example.com/x'>"
                + "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/evil</jid></bind></iq>"
                + "<iq type='result' id='\(bind.id ?? "")' from='alice@example.com/other'>"
                + "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/evil</jid></bind></iq>")
        #expect(harness.takeSent().isEmpty)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")' from='alice@example.com'>"
                + "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        // The bound full JID may answer too.
        try harness.receive(
            "<iq type='result' id='\(carbons.id ?? "")' from='alice@example.com/r1'/>")
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3'/>")

        let result = try #require(harness.result)
        #expect(result.boundJID == (try JID("alice@example.com/r1")))
        #expect(result.carbonsEnabled)
        #expect(
            result.pendingStanzas.map { $0[attribute: "from"] }
                == ["mallory@example.com/x", "alice@example.com/other"])
    }

    /// M5: `location` is checked like see-other-host before anyone connects there.
    @Test(arguments: [
        ("[2001:db8::1]:5222", "[2001:db8::1]:5222"), ("example.net:5223", "example.net:5223"),
        ("bad host", nil), ("example.net:99999", nil),
    ])
    func smLocationIsValidated(location: String, expected: String?) throws {
        var harness = try Self.authenticated(try Self.config())
        let carbons = try Self.bound(&harness)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        try harness.receive(
            "<enabled xmlns='urn:xmpp:sm:3' id='s1' resume='true' location='\(location)'/>")
        let result = try #require(harness.result)
        #expect(result.sm?.location == expected)
    }

    /// M8
    @Test func resumedWithAnotherPrevidFails() throws {
        let resume = SMResumeState(
            id: "old", location: nil, maxSeconds: nil, inboundH: 2, outboundH: 5,
            boundJID: try JID("alice@example.com/r0"))
        var harness = try Self.authenticated(try Self.config(smResume: resume))
        try harness.receive(Self.bindFeatures)
        let error = Self.error {
            try harness.receive("<resumed xmlns='urn:xmpp:sm:3' previd='other' h='1'/>")
        }
        #expect(error == .unexpected("Resumed another session"))
    }

    /// M8
    @Test func pendingStanzasAreCapped() throws {
        var harness = try Self.authenticated(try Self.config())
        _ = try Self.bound(&harness)
        let messages = String(
            repeating: "<message from='bob@example.com/x'><body>x</body></message>",
            count: StreamNegotiator.maxPendingStanzas)
        try harness.receive(messages)
        let error = Self.error {
            try harness.receive("<message from='bob@example.com/x'><body>x</body></message>")
        }
        #expect(error == .invalidStream(condition: "policy-violation"))
    }

    // MARK: Final review: stream limits (XEP-0478) and the mechanism used

    static func limits(_ maxBytes: String) -> String {
        "<limits xmlns='urn:xmpp:stream-limits:0'><max-bytes>\(maxBytes)</max-bytes>"
            + "<idle-seconds>1800</idle-seconds></limits>"
    }

    /// The limits of the latest features count: after authentication, those that came with
    /// it, never the ones from before.
    @Test func limitsAfterAuthenticationCount() throws {
        var harness = try Self.sasl2Authenticating(
            try Self.config(), inline: "", preAuth: Self.limits("10000"))
        try harness.receive(
            Self.sasl2Success("alice@example.com")
                + "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>"
                + Self.limits("262144") + "</stream:features>")
        let bind = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive(
            "<iq type='result' id='\(bind.id ?? "")'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
                + "<jid>alice@example.com/r1</jid></bind></iq>")
        let carbons = try #require(NegotiationHarness.elements(harness.takeSent()).first)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")

        let result = try #require(harness.result)
        #expect(result.features.maxStanzaBytes == 262_144)
        #expect(result.mechanism == "SCRAM-SHA-1")
    }

    @Test func limitsFromBeforeAuthenticationDoNotCarryOver() throws {
        var harness = NegotiationHarness(
            config: try Self.config(), tls: NegotiationHarness.unboundTLS)
        try harness.start()
        try harness.receive(
            Self.serverHeader + "<stream:features>" + Self.limits("10000")
                + "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>"
                + "<mechanism>SCRAM-SHA-1</mechanism></mechanisms></stream:features>")
        try harness.receive(
            "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</challenge>")
        try harness.receive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>{{sasl}}</success>")
        try harness.receive(Self.serverHeader)
        _ = harness.takeSent()
        let carbons = try Self.bound(&harness)
        try harness.receive("<iq type='result' id='\(carbons.id ?? "")'/>")
        try harness.receive("<enabled xmlns='urn:xmpp:sm:3' id='s5' resume='true'/>")

        let result = try #require(harness.result)
        #expect(result.features.maxStanzaBytes == nil)
        #expect(result.mechanism == "SCRAM-SHA-1")
        // A resumable session remembers the value for its resumption.
        #expect(result.sm?.features?.maxStanzaBytes == nil)
    }

    @Test(
        arguments: [
            ("4096", 4096), ("  262144\n", 262_144), ("0", nil), ("-5", nil), ("1e6", nil),
            ("", nil),
            ("99999999999999999999", nil),
        ] as [(String, Int?)])
    func maxBytesIsReadWhenValid(_ text: String, _ expected: Int?) {
        let element = NegotiationHarness.elements(
            ["<stream:features>" + Self.limits(text) + "</stream:features>"])
        let features = StreamFeatures(element.first ?? Element("features"))
        #expect(features.maxStanzaBytes == expected)
    }
}
