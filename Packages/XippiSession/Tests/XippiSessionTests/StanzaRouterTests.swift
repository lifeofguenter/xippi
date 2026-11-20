import Foundation
import Testing
import XMPPCore

@testable import XippiSession

@Suite struct StanzaRouterTests {
    struct Failure: Error {}

    static func iq(_ type: String, _ payload: String, id: String = "q1") -> Element {
        SessionServer.elements(
            "<iq type='\(type)' id='\(id)' from='bob@example.test/phone'"
                + " to='alice@example.test/test'>\(payload)</iq>"
        )[0]
    }

    static func condition(_ reply: Element?) -> StanzaError.Condition? {
        reply?.child("error").flatMap(StanzaError.init(element:))?.condition
    }

    @Test func unknownIQGetAnsweredServiceUnavailable() async throws {
        let router = StanzaRouter()
        let request = Self.iq("get", "<query xmlns='jabber:iq:version'/>")

        let reply = try #require(await router.route(iq: request))

        #expect(reply.name == "iq")
        #expect(reply.type == "error")
        #expect(reply.id == "q1")
        #expect(reply[attribute: "to"] == "bob@example.test/phone")
        #expect(Self.condition(reply) == .serviceUnavailable)
        let unknownSet = await router.route(iq: Self.iq("set", "<x xmlns='urn:example:x'/>"))
        #expect(Self.condition(unknownSet) == .serviceUnavailable)
    }

    @Test func throwingHandlerAnswersInternalServerError() async throws {
        var router = StanzaRouter()
        router.register(iq: "query", namespace: "jabber:iq:version") { _ in throw Failure() }

        let reply = try #require(
            await router.route(iq: Self.iq("get", "<query xmlns='jabber:iq:version'/>")))

        #expect(reply.type == "error")
        #expect(reply.id == "q1")
        #expect(Self.condition(reply) == .internalServerError)
    }

    @Test func resultsAndErrorsAreNeverAnswered() async {
        var router = StanzaRouter()
        router.register(iq: nil, namespace: "urn:xmpp:ping") { iq in iq.iqResult() }
        #expect(await router.route(iq: Self.iq("result", "<ping xmlns='urn:xmpp:ping'/>")) == nil)
        #expect(await router.route(iq: Self.iq("error", "<ping xmlns='urn:xmpp:ping'/>")) == nil)
        #expect(await router.route(iq: Self.iq("result", "")) == nil)
    }

    @Test func handlersAreFoundByChildNameAndNamespace() async throws {
        var router = StanzaRouter()
        router.register(iq: "query", namespace: "jabber:iq:version") { iq in
            iq.iqResult(payload: Element("query", namespace: "jabber:iq:version"))
        }
        router.register(iq: nil, namespace: "urn:xmpp:ping") { iq in iq.iqResult() }

        let version = try #require(
            await router.route(iq: Self.iq("get", "<query xmlns='jabber:iq:version'/>")))
        let ping = try #require(
            await router.route(iq: Self.iq("get", "<ping xmlns='urn:xmpp:ping'/>")))
        let otherName = await router.route(iq: Self.iq("get", "<other xmlns='jabber:iq:version'/>"))

        #expect(version.type == "result")
        #expect(version.child("query", namespace: "jabber:iq:version") != nil)
        #expect(ping.type == "result")
        #expect(Self.condition(otherName) == .serviceUnavailable)
    }

    @Test func handlerReturningNilPassesToTheNextOne() async throws {
        var router = StanzaRouter()
        let calls = Locked<[String]>([])
        router.register(iq: "jingle", namespace: "urn:xmpp:jingle:1") { _ in
            calls.withLock { $0.append("calls") }
            return nil
        }
        router.register(iq: "jingle", namespace: "urn:xmpp:jingle:1") { iq in
            calls.withLock { $0.append("files") }
            return iq.iqResult()
        }

        let reply = await router.route(iq: Self.iq("set", "<jingle xmlns='urn:xmpp:jingle:1'/>"))

        #expect(reply?.type == "result")
        #expect(calls.value == ["calls", "files"])
    }

    @Test func requestWithoutPayloadIsABadRequest() async {
        let router = StanzaRouter()
        let reply = await router.route(iq: Self.iq("get", ""))
        #expect(Self.condition(reply) == .badRequest)
    }

    @Test func messagesGoToTheHandlerOfAChild() async {
        var router = StanzaRouter()
        let seen = Locked<[String]>([])
        router.register(message: "result", namespace: "urn:xmpp:mam:2") { message in
            seen.withLock { $0.append(message.id ?? "") }
            return true
        }
        let archived = SessionServer.elements(
            "<message id='m1' from='alice@example.test'><result xmlns='urn:xmpp:mam:2'"
                + " queryid='q' id='a1'/></message>")[0]
        let plain = SessionServer.elements("<message id='m2'><body>hi</body></message>")[0]

        #expect(await router.route(message: archived))
        #expect(await router.route(message: plain) == false)
        #expect(seen.value == ["m1"])
    }
}
