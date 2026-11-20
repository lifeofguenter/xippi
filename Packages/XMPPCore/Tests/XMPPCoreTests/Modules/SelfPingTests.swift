import Testing
import XMPPTestSupport

@testable import XMPPCore

@Suite struct SelfPingTests {
    static let file = "xep-0410-1.1.0"

    static func occupant() throws -> JID { try JID("characters@chat.shakespeare.lit/JuliC") }

    /// The XEP's answer to a non-occupant, with `condition` in place of `not-acceptable`.
    static func errorAnswer(_ condition: StanzaError.Condition) throws -> Element {
        var answer = try ModuleFixtures.stanza(file, "not-occupant")
        answer.children = answer.children.map { node in
            guard case .element(var error) = node, error.name == "error" else { return node }
            error.children = [
                .element(Element(condition.rawValue, namespace: StanzaError.namespace))
            ]
            return .element(error)
        }
        return answer
    }

    static func check(answer: Element) async throws -> SelfPingResult {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(answer, for: "ping")
        return await SelfPing.check(occupant: try occupant(), via: sender)
    }

    static func check(failure: IQError) async throws -> SelfPingResult {
        let sender = FakeStanzaSender()
        sender.enqueueError(failure, for: "ping")
        return await SelfPing.check(occupant: try occupant(), via: sender)
    }

    @Test func pingMatchesTheXEP() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(
            ModuleFixtures.iqResult(from: "characters@chat.shakespeare.lit/JuliC"), for: "ping")
        #expect(await SelfPing.check(occupant: try Self.occupant(), via: sender) == .joined)
        let expected = try ModuleFixtures.stanza(Self.file, "self-ping")
        #expect(
            sender.sent.first?.normalized(dropping: ["id"])
                == expected.normalized(dropping: ["id", "from"]))
    }

    // The rows of the spec's section 7.4 table.

    @Test func notAcceptableIsNotJoined() async throws {
        let answer = try ModuleFixtures.stanza(Self.file, "not-occupant")
        #expect(try await Self.check(answer: answer) == .notJoined)
    }

    /// XEP-0410 3.2 (ruling R35): the user is joined, but another of the user's clients has
    /// just changed the occupant's nick.
    @Test func itemNotFoundIsJoined() async throws {
        #expect(try await Self.check(answer: try Self.errorAnswer(.itemNotFound)) == .joined)
    }

    @Test func serviceUnavailableIsJoined() async throws {
        #expect(try await Self.check(answer: try Self.errorAnswer(.serviceUnavailable)) == .joined)
    }

    @Test func featureNotImplementedIsJoined() async throws {
        #expect(
            try await Self.check(answer: try Self.errorAnswer(.featureNotImplemented)) == .joined)
    }

    @Test func aResultIsJoined() async throws {
        let result = ModuleFixtures.iqResult(from: "characters@chat.shakespeare.lit/JuliC")
        #expect(try await Self.check(answer: result) == .joined)
    }

    @Test func aTimeoutIsUnreachable() async throws {
        let sender = FakeStanzaSender()
        #expect(await SelfPing.check(occupant: try Self.occupant(), via: sender) == .unreachable)
        #expect(sender.sent.count == 1)
    }

    // XEP-0410 section 3.2 beyond the table.

    @Test(arguments: [StanzaError.Condition.remoteServerNotFound, .remoteServerTimeout])
    func anUnreachableServerIsUnreachable(_ condition: StanzaError.Condition) async throws {
        #expect(try await Self.check(answer: try Self.errorAnswer(condition)) == .unreachable)
    }

    @Test(arguments: [
        StanzaError.Condition.notAllowed, .badRequest, .forbidden, .notAuthorized,
        .internalServerError, .gone,
    ])
    func anyOtherErrorIsNotJoined(_ condition: StanzaError.Condition) async throws {
        #expect(try await Self.check(answer: try Self.errorAnswer(condition)) == .notJoined)
    }

    @Test func aResultFromAnotherJIDIsNotAnAnswer() async throws {
        for from in ["characters@chat.shakespeare.lit", "mallory@evil/x"] {
            let result = ModuleFixtures.iqResult(from: from)
            #expect(try await Self.check(answer: result) == .unreachable, "\(from)")
        }
    }

    @Test(arguments: [IQError.sessionEnded, .notConnected])
    func noSessionIsNoAnswer(_ failure: IQError) async throws {
        #expect(try await Self.check(failure: failure) == .noSession)
    }

    @Test func aMalformedErrorIsNotJoined() async throws {
        #expect(try await Self.check(failure: .malformedResponse) == .notJoined)
    }

    @Test func aBareRoomJIDIsNeverPinged() async throws {
        let sender = FakeStanzaSender()
        sender.enqueueResponse(ModuleFixtures.iqResult(), for: "ping")
        #expect(
            await SelfPing.check(occupant: try JID("characters@chat.shakespeare.lit"), via: sender)
                == .notJoined)
        #expect(sender.sent.isEmpty)
    }

    @Test func classify() throws {
        let occupant = try Self.occupant()
        let result = ModuleFixtures.iqResult(from: occupant.description)
        #expect(SelfPing.classify(.success(result), occupant: occupant) == .joined)
        #expect(SelfPing.classify(.failure(.timeout), occupant: occupant) == .unreachable)
        #expect(
            SelfPing.classify(
                .failure(.error(StanzaError(type: .cancel, condition: .notAcceptable))),
                occupant: occupant) == .notJoined)
    }
}
