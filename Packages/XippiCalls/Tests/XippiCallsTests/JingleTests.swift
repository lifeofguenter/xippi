import Testing
import XMPPCore
import XippiCalls

/// Examples from XEP-0166, verbatim apart from whitespace.
enum XEP0166 {
    static let stubInitiate = """
        <iq from='romeo@montague.lit/orchard' id='zid615d9' to='juliet@capulet.lit/balcony' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='romeo@montague.lit/orchard' sid='a73sjjvkla37jfea'>
            <content creator='initiator' name='this-is-a-stub'>
              <description xmlns='urn:xmpp:jingle:apps:stub:0'/>
              <transport xmlns='urn:xmpp:jingle:transports:stub:0'/>
            </content>
          </jingle>
        </iq>
        """

    static let rtpInitiate = """
        <iq from='romeo@montague.lit/orchard' id='ph37a419' to='juliet@capulet.lit/balcony' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='romeo@montague.lit/orchard' sid='a73sjjvkla37jfea'>
            <content creator='initiator' name='voice'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='96' name='speex' clockrate='16000'/>
                <payload-type id='97' name='speex' clockrate='8000'/>
                <payload-type id='18' name='G729'/>
                <payload-type id='0' name='PCMU' />
                <payload-type id='103' name='L16' clockrate='16000' channels='2'/>
                <payload-type id='98' name='x-ISAC' clockrate='8000'/>
              </description>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' pwd='asd88fgpdd777uzjYhagZg' ufrag='8hhy'>
                <candidate component='1' foundation='1' generation='0' id='el0747fg11' ip='10.0.1.1' network='1' port='8998' priority='2130706431' protocol='udp' type='host'/>
                <candidate component='1' foundation='2' generation='0' id='y3s2b30v3r' ip='192.0.2.3' network='1' port='45664' priority='1694498815' protocol='udp' rel-addr='10.0.1.1' rel-port='8998' type='srflx'/>
              </transport>
            </content>
          </jingle>
        </iq>
        """

    static let rtpAccept = """
        <iq from='juliet@capulet.lit/balcony' id='yd71f495' to='romeo@montague.lit/orchard' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-accept' responder='juliet@capulet.lit/balcony' sid='a73sjjvkla37jfea'>
            <content creator='initiator' name='voice'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>
                <payload-type id='97' name='speex' clockrate='8000'/>
                <payload-type id='18' name='G729'/>
              </description>
              <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1'>
                <candidate component='1' foundation='1' generation='0' id='or2ii2syr1' ip='192.0.2.1' network='0' port='3478' priority='2130706431' protocol='udp' type='host'/>
              </transport>
            </content>
          </jingle>
        </iq>
        """

    static let terminateWithText = """
        <iq from='juliet@capulet.lit/balcony' id='vua614d9' to='romeo@montague.lit/orchard' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='a73sjjvkla37jfea'>
            <reason>
              <success/>
              <text>Sorry, gotta go!</text>
            </reason>
          </jingle>
        </iq>
        """

    static let terminateAlternativeSession = """
        <iq from='juliet@capulet.lit/balcony' id='ay3r2b86' to='romeo@montague.lit/orchard' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='a73sjjvkla37jfea'>
            <reason>
              <alternative-session>
                <sid>b84tkkwlmb48kgfb</sid>
              </alternative-session>
            </reason>
          </jingle>
        </iq>
        """

    static let ringing = """
        <iq from='juliet@capulet.lit/balcony' id='hq7rg186' to='romeo@montague.lit/orchard' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='a73sjjvkla37jfea'>
            <ringing xmlns='urn:xmpp:jingle:apps:rtp:1:info'/>
          </jingle>
        </iq>
        """

    static let sessionPing = """
        <iq from='juliet@capulet.lit/balcony' id='ug37vb25' to='romeo@montague.lit/orchard' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='a73sjjvkla37jfea'/>
        </iq>
        """

    static let securityPrecondition = """
        <iq from='romeo@montague.lit/orchard' id='tiw51bv9' to='juliet@capulet.lit/balcony' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' initiator='romeo@montague.lit/orchard' sid='a73sjjvkla37jfea'>
            <content creator='initiator' name='this-is-a-stub'>
              <description xmlns='urn:xmpp:jingle:apps:stub:0'/>
              <transport xmlns='urn:xmpp:jingle:transports:stub:0'/>
              <security xmlns='urn:xmpp:jingle:security:stub:0'/>
            </content>
          </jingle>
        </iq>
        """

    static let securityInfo = """
        <iq from='romeo@montague.lit/orchard' id='zyw6m167' to='juliet@capulet.lit/balcony' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='security-info' sid='a73sjjvkla37jfea'>
            <content creator='initiator' name='xmlstream'>
              <security xmlns='urn:xmpp:jingle:security:xtls:0'>
                <method name='x509'/>
              </security>
            </content>
          </jingle>
        </iq>
        """

    /// XEP-0234: a content-reject whose reason carries an application condition.
    static let fileNotAvailable = """
        <iq from='romeo@montague.example/dr4hcr0st3lup4c' id='wsn361c9' to='juliet@capulet.example/yn0cl4bnw0yr3vym' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='content-reject' sid='uj3b2'>
            <content creator='initiator' name='requesting-file' senders='initiator'/>
            <reason>
              <failed-application />
              <file-not-available xmlns='urn:xmpp:jingle:apps:file-transfer:errors:0' />
            </reason>
          </jingle>
        </iq>
        """

    /// XEP-0338: content-add with the new BUNDLE group.
    static let bundleContentAdd = """
        <iq from='romeo@montague.lit/orchard' id='bundle-add-1' to='juliet@capulet.lit/balcony' type='set'>
          <jingle xmlns='urn:xmpp:jingle:1' action='content-add' sid='a73sjjvkla37jfea'>
            <group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'>
              <content name='voice'/>
              <content name='webcam'/>
              <content name='screen'/>
            </group>
            <content creator='initiator' name='screen'>
              <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'/>
            </content>
          </jingle>
        </iq>
        """

    static let all = [
        stubInitiate, rtpInitiate, rtpAccept, terminateWithText, terminateAlternativeSession,
        ringing, sessionPing, securityPrecondition, securityInfo, fileNotAvailable,
        bundleContentAdd,
    ]
}

@Suite struct JingleTests {
    @Test(arguments: XEP0166.all)
    func examplesRoundTrip(_ xml: String) throws {
        let parsed = try #require(JingleIQ(element: parseElement(xml)))
        let written = parsed.element.xml()
        let reparsed = try #require(JingleIQ(element: parseElement(written)))
        #expect(reparsed == parsed)
        #expect(stripWhitespace(parsed.element) == stripWhitespace(reparsed.element))
    }

    @Test func sessionInitiateFields() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.rtpInitiate)))
        #expect(iq.action == .sessionInitiate)
        #expect(iq.sid == "a73sjjvkla37jfea")
        #expect(iq.initiator == (try JID("romeo@montague.lit/orchard")))
        #expect(iq.responder == nil)
        #expect(iq.reason == nil)
        #expect(iq.info.isEmpty)
        let content = try #require(iq.contents.first)
        #expect(iq.contents.count == 1)
        #expect(content.creator == "initiator")
        #expect(content.name == "voice")
        #expect(content.senders == nil)
        #expect(content.description?.namespace == "urn:xmpp:jingle:apps:rtp:1")
        #expect(content.transport?.namespace == "urn:xmpp:jingle:transports:ice-udp:1")
        #expect(content.security == nil)

        let description = try #require(content.description.flatMap(RTPDescription.init(element:)))
        #expect(description.media == "audio")
        #expect(description.payloadTypes.map(\.id) == [96, 97, 18, 0, 103, 98])
        #expect(description.payloadTypes[4].channels == 2)
        #expect(description.payloadTypes[2].clockrate == nil)

        let transport = try #require(content.transport.flatMap(ICEUDPTransport.init(element:)))
        #expect(transport.ufrag == "8hhy")
        #expect(transport.pwd == "asd88fgpdd777uzjYhagZg")
        #expect(transport.candidates.count == 2)
        let srflx = transport.candidates[1]
        #expect(srflx.id == "y3s2b30v3r")
        #expect(srflx.network == 1)
        #expect(srflx.relAddr == "10.0.1.1")
        #expect(srflx.relPort == 8998)
        #expect(srflx.type == "srflx")
        #expect(srflx.priority == 1_694_498_815)
    }

    @Test func reasonWithText() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.terminateWithText)))
        #expect(iq.action == .sessionTerminate)
        #expect(iq.reason == JingleReason(condition: "success", text: "Sorry, gotta go!"))
    }

    @Test func reasonWithAlternativeSession() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.terminateAlternativeSession)))
        #expect(iq.reason?.condition == "alternative-session")
        #expect(iq.reason?.alternativeSessionID == "b84tkkwlmb48kgfb")
    }

    @Test func reasonKeepsApplicationCondition() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.fileNotAvailable)))
        #expect(iq.action == .contentReject)
        #expect(iq.reason?.condition == "failed-application")
        #expect(iq.reason?.details.map(\.name) == ["file-not-available"])
        #expect(iq.contents.first?.senders == "initiator")
        #expect(iq.contents.first?.description == nil)
    }

    @Test func sessionInfoKeepsItsPayload() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.ringing)))
        #expect(iq.action == .sessionInfo)
        #expect(iq.contents.isEmpty)
        #expect(iq.info.map(\.name) == ["ringing"])
    }

    @Test func groupIsKeptAsInfo() throws {
        let iq = try #require(JingleIQ(element: parseElement(XEP0166.bundleContentAdd)))
        let group = try #require(iq.info.lazy.compactMap(JingleGroup.init(element:)).first)
        #expect(group.semantics == "BUNDLE")
        #expect(group.contents == ["voice", "webcam", "screen"])
        #expect(JingleGroup(element: group.element) == group)
    }

    @Test func acceptsTheJingleElementItself() throws {
        let iq = try parseElement(XEP0166.rtpAccept)
        let jingle = try #require(iq.child("jingle", namespace: JingleNamespace.jingle))
        #expect(JingleIQ(element: jingle) == JingleIQ(element: iq))
        #expect(JingleIQ(element: jingle)?.responder == (try JID("juliet@capulet.lit/balcony")))
    }

    @Test func builtElementIsTheXEPWireFormat() throws {
        let terminate = JingleIQ(
            action: .sessionTerminate, sid: "a73sjjvkla37jfea",
            reason: JingleReason(condition: "success"))
        #expect(
            terminate.element.xml()
                == "<jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='a73sjjvkla37jfea'>"
                + "<reason><success/></reason></jingle>")

        let initiate = JingleIQ(
            action: .sessionInitiate, sid: "s1", initiator: try JID("romeo@montague.lit/orchard"),
            contents: [
                JingleContent(
                    creator: "initiator", name: "voice", senders: "initiator",
                    description: Element(
                        "description", namespace: "urn:xmpp:jingle:apps:rtp:1",
                        attributes: ["media": "audio"]))
            ])
        #expect(
            initiate.element.xml()
                == "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate'"
                + " initiator='romeo@montague.lit/orchard' sid='s1'>"
                + "<content creator='initiator' name='voice' senders='initiator'>"
                + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>"
                + "</content></jingle>")
    }

    @Test func everyXEP0166Action() {
        #expect(
            Set(JingleAction.allCases.map(\.rawValue)) == [
                "content-accept", "content-add", "content-modify", "content-reject",
                "content-remove", "description-info", "security-info", "session-accept",
                "session-info", "session-initiate", "session-terminate", "transport-accept",
                "transport-info", "transport-reject", "transport-replace",
            ])
    }

    @Test func everyXEP0166Condition() {
        #expect(
            JingleReason.conditions == [
                "alternative-session", "busy", "cancel", "connectivity-error", "decline",
                "expired", "failed-application", "failed-transport", "general-error", "gone",
                "incompatible-parameters", "media-error", "security-error", "success", "timeout",
                "unsupported-applications", "unsupported-transports",
            ])
    }

    @Test(arguments: [
        // unknown action
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-start' sid='a'/>",
        // no sid
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-info'/>",
        // empty sid
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid=''/>",
        // wrong namespace
        "<jingle xmlns='urn:xmpp:jingle:0' action='session-info' sid='a'/>",
        // initiator that is not a JID
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='a' initiator='a@b@c'/>",
        // creator outside the two roles
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='a'><content creator='me' name='x'/></jingle>",
        // senders outside the four values
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='a'><content creator='initiator' name='x' senders='all'/></jingle>",
        // content without a name
        "<jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='a'><content creator='initiator'/></jingle>",
        // an IQ without Jingle
        "<iq type='set' id='x'><query xmlns='jabber:iq:version'/></iq>",
    ])
    func malformedJingleIsRejected(_ xml: String) throws {
        #expect(JingleIQ(element: try parseElement(xml)) == nil)
    }

    @Test func missingCreatorMeansInitiator() throws {
        // Dino reads a missing creator as the initiator; so do we.
        let xml =
            "<jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='a'><content name='x'/></jingle>"
        #expect(JingleIQ(element: try parseElement(xml))?.contents.first?.creator == "initiator")
    }
}
