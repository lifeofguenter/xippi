import Testing
import XMPPCore
import XippiCalls

/// Messages from XEP-0353's examples.
enum XEP0353 {
    static let propose = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example' type='chat'>
          <propose xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
            <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>
          </propose>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let ringing = """
        <message from='juliet@capulet.example/phone' to='romeo@montague.example/orchard' type='chat'>
          <ringing xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'/>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let retract = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example' type='chat'>
          <retract xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
            <reason xmlns="urn:xmpp:jingle:1">
              <cancel/>
              <text>Retracted</text>
            </reason>
          </retract>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let proceed = """
        <message from='juliet@capulet.example/phone' to='romeo@montague.example/orchard' type='chat'>
          <proceed xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'/>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let reject = """
        <message from='juliet@capulet.example/phone' to='romeo@montague.example/orchard' type='chat'>
          <reject xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
            <reason xmlns="urn:xmpp:jingle:1">
              <busy/>
              <text>Busy</text>
            </reason>
          </reject>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let tieBreakReject = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example' type='chat'>
          <reject xmlns='urn:xmpp:jingle-message:0' id='fecbea35-08d3-404f-9ec7-2b57c566fa74'>
            <reason xmlns="urn:xmpp:jingle:1">
              <expired/>
              <text>Tie-Break</text>
            </reason>
            <tie-break/>
          </reject>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    /// The XEP's example closes this one with `</reject>`; fixed here so it is XML at all.
    static let tieBreakRetract = """
        <message from='juliet@capulet.example/phone' to='romeo@montague.example/orchard' type='chat'>
          <retract xmlns='urn:xmpp:jingle-message:0' id='fecbea35-08d3-404f-9ec7-2b57c566fa74'>
            <reason xmlns="urn:xmpp:jingle:1">
              <expired/>
              <text>Tie-Break</text>
            </reason>
            <tie-break/>
          </retract>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let finish = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example/phone' type='chat'>
          <finish xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
            <reason xmlns="urn:xmpp:jingle:1">
              <success/>
              <text>Success</text>
            </reason>
          </finish>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let migrated = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example' type='chat'>
          <finish xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'>
            <reason xmlns="urn:xmpp:jingle:1">
              <expired/>
              <text>Session migrated</text>
            </reason>
            <migrated to='989a46a6-f202-4910-a7c3-83c6ba3f3947'/>
          </finish>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    /// Sent to the own bare JID by Conversations and Dino when a call is taken on this device.
    static let accept = """
        <message from='juliet@capulet.example/phone' to='juliet@capulet.example' type='chat'>
          <accept xmlns='urn:xmpp:jingle-message:0' id='ca3cf894-5325-482f-a412-a6e9f832298d'/>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """

    static let videoPropose = """
        <message from='romeo@montague.example/orchard' to='juliet@capulet.example' type='chat'>
          <propose xmlns='urn:xmpp:jingle-message:0' id='9a1b'>
            <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'/>
            <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'/>
          </propose>
          <store xmlns="urn:xmpp:hints"/>
        </message>
        """
}

@Suite struct JMITests {
    static let sid = "ca3cf894-5325-482f-a412-a6e9f832298d"

    @Test func jmiParseAll() throws {
        let sid = Self.sid
        let cases: [(String, JMIAction)] = [
            (XEP0353.propose, .propose(sid: sid, media: [.audio])),
            (XEP0353.videoPropose, .propose(sid: "9a1b", media: [.audio, .video])),
            (XEP0353.ringing, .ringing(sid: sid)),
            (
                XEP0353.retract,
                .retract(
                    sid: sid, reason: JingleReason(condition: "cancel", text: "Retracted"),
                    tieBreak: false)
            ),
            (XEP0353.accept, .accept(sid: sid)),
            (
                XEP0353.reject,
                .reject(
                    sid: sid, reason: JingleReason(condition: "busy", text: "Busy"), tieBreak: false
                )
            ),
            (
                XEP0353.tieBreakReject,
                .reject(
                    sid: "fecbea35-08d3-404f-9ec7-2b57c566fa74",
                    reason: JingleReason(condition: "expired", text: "Tie-Break"), tieBreak: true)
            ),
            (
                XEP0353.tieBreakRetract,
                .retract(
                    sid: "fecbea35-08d3-404f-9ec7-2b57c566fa74",
                    reason: JingleReason(condition: "expired", text: "Tie-Break"), tieBreak: true)
            ),
            (XEP0353.proceed, .proceed(sid: sid)),
            (
                XEP0353.finish,
                .finish(
                    sid: sid, reason: JingleReason(condition: "success", text: "Success"),
                    migratedTo: nil)
            ),
            (
                XEP0353.migrated,
                .finish(
                    sid: sid, reason: JingleReason(condition: "expired", text: "Session migrated"),
                    migratedTo: "989a46a6-f202-4910-a7c3-83c6ba3f3947")
            ),
        ]
        for (xml, expected) in cases {
            let action = JMI.parse(try parseElement(xml))
            #expect(action == expected)
            #expect(action?.sid == expected.sid)
        }
    }

    @Test func builtMessagesParseBack() throws {
        let to = try JID("juliet@capulet.example")
        let payloads: [(Element, JMIAction)] = [
            (
                JMI.propose(sid: "s", media: [.audio, .video]),
                .propose(sid: "s", media: [.audio, .video])
            ),
            (JMI.ringing(sid: "s"), .ringing(sid: "s")),
            (
                JMI.retract(sid: "s"),
                .retract(sid: "s", reason: JingleReason(condition: "cancel"), tieBreak: false)
            ),
            (JMI.accept(sid: "s"), .accept(sid: "s")),
            (
                JMI.reject(sid: "s"),
                .reject(sid: "s", reason: JingleReason(condition: "busy"), tieBreak: false)
            ),
            (
                JMI.reject(sid: "s", reason: JingleReason(condition: "expired"), tieBreak: true),
                .reject(sid: "s", reason: JingleReason(condition: "expired"), tieBreak: true)
            ),
            (JMI.proceed(sid: "s"), .proceed(sid: "s")),
            (
                JMI.finish(sid: "s", reason: JingleReason(condition: "success")),
                .finish(sid: "s", reason: JingleReason(condition: "success"), migratedTo: nil)
            ),
            (
                JMI.finish(sid: "s", reason: JingleReason(condition: "expired"), migratedTo: "t"),
                .finish(sid: "s", reason: JingleReason(condition: "expired"), migratedTo: "t")
            ),
        ]
        for (payload, expected) in payloads {
            let message = JMI.message(to: to, payload: payload, id: "m1")
            #expect(JMI.parse(message) == expected)
            // Over the wire too.
            #expect(JMI.parse(try parseElement(message.xml())) == expected)
        }
    }

    @Test func messageIsAStoredChat() throws {
        let message = JMI.message(
            to: try JID("juliet@capulet.example"), payload: JMI.proceed(sid: "s"), id: "m1")
        #expect(message.name == "message")
        #expect(message[attribute: "type"] == "chat")
        #expect(message[attribute: "to"] == "juliet@capulet.example")
        #expect(message[attribute: "id"] == "m1")
        #expect(message.child("store", namespace: "urn:xmpp:hints") != nil)
        #expect(
            JMI.propose(sid: "s", media: [.video]).xml()
                == "<propose xmlns='urn:xmpp:jingle-message:0' id='s'>"
                + "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='video'/></propose>")
        #expect(
            JMI.finish(sid: "s", reason: JingleReason(condition: "success")).xml()
                == "<finish xmlns='urn:xmpp:jingle-message:0' id='s'>"
                + "<reason xmlns='urn:xmpp:jingle:1'><success/></reason></finish>")
    }

    @Test(arguments: [
        // groupchat is not one-to-one signalling
        "<message type='groupchat'><proceed xmlns='urn:xmpp:jingle-message:0' id='s'/></message>",
        // an error bounce
        "<message type='error'><proceed xmlns='urn:xmpp:jingle-message:0' id='s'/></message>",
        // no id
        "<message type='chat'><proceed xmlns='urn:xmpp:jingle-message:0'/></message>",
        // empty id
        "<message type='chat'><proceed xmlns='urn:xmpp:jingle-message:0' id=''/></message>",
        // a propose for nothing a call carries
        "<message type='chat'><propose xmlns='urn:xmpp:jingle-message:0' id='s'><description xmlns='urn:xmpp:jingle:apps:file-transfer:5'/></propose></message>",
        // an element JMI does not define
        "<message type='chat'><wave xmlns='urn:xmpp:jingle-message:0' id='s'/></message>",
        // the old namespace
        "<message type='chat'><proceed xmlns='urn:xmpp:jingle-message:1' id='s'/></message>",
        // not a message
        "<iq type='set' id='x'><proceed xmlns='urn:xmpp:jingle-message:0' id='s'/></iq>",
        // a plain chat message
        "<message type='chat'><body>hi</body></message>",
    ])
    func notJMI(_ xml: String) throws {
        #expect(JMI.parse(try parseElement(xml)) == nil)
    }

    @Test func messageWithoutTypeIsAccepted() throws {
        let xml = "<message><proceed xmlns='urn:xmpp:jingle-message:0' id='s'/></message>"
        #expect(JMI.parse(try parseElement(xml)) == .proceed(sid: "s"))
    }
}
