import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

@Suite("ChatStateSupport")
struct ChatStateSupportTests {
    static let bob = "bob@example.test"
    private let phone = ChatStateSupport.Device(
        jid: "bob@example.test/phone",
        caps: Caps.Advertisement(node: "https://client.example", ver: "v1"))
    private let tablet = ChatStateSupport.Device(
        jid: "bob@example.test/tablet",
        caps: Caps.Advertisement(node: "https://client.example", ver: "v1"))
    private let laptop = ChatStateSupport.Device(jid: "bob@example.test/laptop", caps: nil)

    @Test func nothingKnownAsksTheDevices() {
        let support = ChatStateSupport()
        #expect(support.answer(for: Self.bob, devices: [phone, laptop]) == .unknown)
        #expect(support.undiscovered([phone, laptop], at: Self.now) == [phone, laptop])
    }

    @Test func nobodyOnlineTakesNoStates() {
        #expect(ChatStateSupport().answer(for: Self.bob, devices: []) == .unsupported)
    }

    @Test func aChatStateFromThePeerShowsSupport() {
        var support = ChatStateSupport()
        support.received(from: Self.bob, chatState: true, content: false)
        #expect(support.answer(for: Self.bob, devices: []) == .supported)
    }

    @Test func aReplyWithoutChatStatesWithdrawsSupportUntilTheyComeBack() {
        var support = ChatStateSupport()
        support.received(from: Self.bob, chatState: true, content: true)
        support.received(from: Self.bob, chatState: false, content: true)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .unsupported)
        support.received(from: Self.bob, chatState: true, content: false)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .supported)
    }

    @Test func aMessageWithNeitherChangesNothing() {
        var support = ChatStateSupport()
        support.received(from: Self.bob, chatState: true, content: true)
        // A receipt or a marker.
        support.received(from: Self.bob, chatState: false, content: false)
        #expect(support.answer(for: Self.bob, devices: []) == .supported)
    }

    @Test func aVerifiedCapsAnswerServesEveryDeviceWithThatVer() {
        var support = ChatStateSupport()
        support.learned(phone, supports: true, verified: true)
        #expect(support.answer(for: Self.bob, devices: [tablet]) == .supported)
        #expect(support.undiscovered([tablet, laptop], at: Self.now) == [laptop])
    }

    @Test func anUnverifiedAnswerServesThatDeviceOnly() {
        var support = ChatStateSupport()
        support.learned(phone, supports: true, verified: false)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .supported)
        #expect(support.answer(for: Self.bob, devices: [tablet]) == .unknown)
    }

    @Test func oneDeviceWithChatStatesIsEnough() {
        var support = ChatStateSupport()
        support.learned(laptop, supports: false, verified: false)
        support.learned(phone, supports: true, verified: true)
        #expect(support.answer(for: Self.bob, devices: [laptop, phone]) == .supported)
    }

    @Test func devicesWithoutChatStatesGetNone() {
        var support = ChatStateSupport()
        support.learned(laptop, supports: false, verified: false)
        #expect(support.answer(for: Self.bob, devices: [laptop]) == .unsupported)
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aDeviceThatDidNotAnswerIsNotTakenForNo() {
        var support = ChatStateSupport()
        support.unanswered(phone, at: Self.now)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .unknown)
        // Not asked again at once; asked again later.
        #expect(support.undiscovered([phone, laptop], at: Self.now + 60) == [laptop])
        #expect(
            support.undiscovered([phone], at: Self.now + ChatStateSupport.askAgainAfter)
                == [phone])
        // An answer that comes later counts.
        support.learned(phone, supports: true, verified: false)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .supported)
    }

    @Test func onlyAReplyWithoutStatesTakesTheActiveOutOfMessages() {
        var support = ChatStateSupport()
        #expect(!support.withdrawn(by: Self.bob))
        support.learned(phone, supports: false, verified: true)
        #expect(!support.withdrawn(by: Self.bob))
        support.received(from: Self.bob, chatState: false, content: true)
        #expect(support.withdrawn(by: Self.bob))
        support.received(from: Self.bob, chatState: true, content: false)
        #expect(!support.withdrawn(by: Self.bob))
    }

    @Test func thePeersMessagesOutweighItsCaps() {
        var support = ChatStateSupport()
        support.learned(phone, supports: true, verified: true)
        support.received(from: Self.bob, chatState: false, content: true)
        #expect(support.answer(for: Self.bob, devices: [phone]) == .unsupported)
    }
}

/// XEP-0085 5.1 through the session: standalone states go only to a contact that showed
/// support, by its own messages or its devices' capabilities, and stop when its replies
/// stop carrying states.
@Suite struct ChatStateNegotiationTests {
    static let bob = "bob@example.test"
    static let phone = "bob@example.test/phone"
    static let me = SessionServer.fullJID
    static let node = "https://client.example"
    static let chatStates = "http://jabber.org/protocol/chatstates"

    static func harness(settings: SessionSettings = SessionSettings()) async throws
        -> SessionHarness
    {
        try await SessionHarness(
            options: .init(
                roster: .items([AccountSessionTests.rosterItem(Self.bob, "both")], version: "v1")),
            settings: settings
        ) { database, accountID in
            _ = try database.ensureChat(accountID: accountID, jid: Self.bob, kind: .direct)
        }
    }

    static func sentStates(_ harness: SessionHarness, _ state: String) -> Int {
        harness.server.stanzas.filter {
            $0.name == "message" && $0.to?.bare.description == bob
                && $0.child(state, namespace: chatStates) != nil && $0.child("body") == nil
        }.count
    }

    static func discoRequests(_ harness: SessionHarness) -> Int {
        harness.server.stanzas.filter {
            $0.name == "iq" && $0.to?.description == phone
                && $0.child("query", namespace: Disco.infoNamespace) != nil
        }.count
    }

    /// A client with these features, and the caps ver they hash to.
    static func client(features: Set<String>) -> (ver: String, query: String) {
        let info = DiscoInfo(
            identities: [.init(category: "client", type: "pc")],
            features: features.union([Disco.infoNamespace]))
        let ver = Caps.verificationString(info)
        let list = info.features.sorted().map { "<feature var='\($0)'/>" }.joined()
        return (
            ver,
            "<query xmlns='\(Disco.infoNamespace)' node='\(node)#\(ver)'>"
                + "<identity category='client' type='pc'/>\(list)</query>"
        )
    }

    static func online(_ harness: SessionHarness, features: Set<String>?) throws {
        guard let features else {
            try harness.deliver("<presence from='\(phone)' to='\(me)'/>")
            return
        }
        let client = Self.client(features: features)
        harness.server.setResponder { element in
            guard element.name == "iq", element[attribute: "to"] == phone,
                element.child("query", namespace: Disco.infoNamespace) != nil
            else { return nil }
            return [
                "<iq type='result' id='\(element.id ?? "")' from='\(phone)'>\(client.query)</iq>"
            ]
        }
        try harness.deliver(
            "<presence from='\(phone)' to='\(me)'><c xmlns='\(Caps.namespace)' hash='sha-1'"
                + " node='\(node)' ver='\(client.ver)'/></presence>")
    }

    static func reply(_ harness: SessionHarness, id: String, state: String?) throws {
        let extra = state.map { "<\($0) xmlns='\(chatStates)'/>" } ?? ""
        try harness.deliver(
            AccountSessionTests.chat(phone, id: id, body: "Reply \(id)", extra: extra))
    }

    @Test func aPeerWhoseRepliesCarryStatesGetsThem() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: nil)
        try Self.reply(harness, id: "r1", state: "active")
        try await harness.barrier()

        try await harness.session.setChatState(.composing, chatID: chatID)
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 1)
        await harness.stop()
    }

    @Test func aReplyWithoutStatesStopsThemAndAStateBringsThemBack() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: nil)
        try Self.reply(harness, id: "r1", state: "active")
        try await harness.barrier()
        try await harness.session.setChatState(.composing, chatID: chatID)

        try Self.reply(harness, id: "r2", state: nil)
        try await harness.barrier()
        try await harness.session.setChatState(.paused, chatID: chatID)
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await harness.barrier()
        #expect(Self.sentStates(harness, "paused") == 0)
        #expect(Self.sentStates(harness, "composing") == 1)

        try harness.deliver(
            "<message from='\(Self.phone)' to='\(Self.me)' type='chat' id='r3'>"
                + "<active xmlns='\(Self.chatStates)'/></message>")
        try await harness.barrier()
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 2)
        await harness.stop()
    }

    @Test func capsAreAskedOnceBeforeTheFirstComposing() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: [Self.chatStates])
        try await harness.barrier()

        try await harness.session.setChatState(.composing, chatID: chatID)
        try await waitUntil("composing") { Self.sentStates(harness, "composing") == 1 }
        try await harness.session.setChatState(.paused, chatID: chatID)
        try await harness.barrier()
        #expect(Self.discoRequests(harness) == 1)
        #expect(Self.sentStates(harness, "composing") == 1)
        #expect(Self.sentStates(harness, "paused") == 1)
        await harness.stop()
    }

    @Test func devicesWithoutChatStatesGetNone() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: ["urn:xmpp:receipts"])
        try await harness.barrier()

        // The devices are asked in the background; the answer is no.
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await waitUntil("asked") { Self.discoRequests(harness) == 1 }
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 0)
        await harness.stop()
    }

    @Test func aPeerThatAnswersNoDiscoGetsNone() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        // Online without caps: the disco#info goes to the device, which the test server
        // refuses (service-unavailable).
        try Self.online(harness, features: nil)
        try await harness.barrier()

        // The devices are asked in the background; the answer is no.
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await waitUntil("asked") { Self.discoRequests(harness) == 1 }
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 0)
        await harness.stop()
    }

    @Test func withTheSettingOffNothingTellsTheChat() async throws {
        let harness = try await Self.harness(settings: SessionSettings(chatStates: false))
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: nil)
        try Self.reply(harness, id: "r1", state: "active")
        try await harness.barrier()

        try await harness.session.setChatState(.composing, chatID: chatID)
        // A new chat: the message goes once its encryption default is known.
        let id = try await harness.session.send(text: "Hi", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        let sent = try await OMEMOPipelineTests.sent(originID, by: harness)
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 0)
        #expect(sent.child("active", namespace: Self.chatStates) == nil)
        await harness.stop()
    }

    static func available(_ device: String) -> String {
        "<presence from='\(device)' to='\(me)'/>"
    }

    /// Disco#info requests to any of bob's devices.
    static func discoRequestsToBob(_ harness: SessionHarness) -> [Element] {
        harness.server.stanzas.filter {
            $0.name == "iq" && $0.to?.bare.description == bob
                && $0.child("query", namespace: Disco.infoNamespace) != nil
        }
    }

    /// Bob's devices take their time: their disco#info is answered only by the test.
    static func devicesHoldTheirAnswers(_ harness: SessionHarness) {
        harness.server.setResponder { element in
            guard element.name == "iq", element.to?.bare.description == Self.bob,
                element.child("query", namespace: Disco.infoNamespace) != nil
            else { return nil }
            return []
        }
    }

    static func answer(_ request: Element, features: Set<String>, _ harness: SessionHarness)
        throws
    {
        let list = features.union([Disco.infoNamespace]).sorted()
            .map { "<feature var='\($0)'/>" }.joined()
        try harness.deliver(
            "<iq type='result' id='\(request.id ?? "")' from='\(request.to?.description ?? "")'"
                + " to='\(me)'><query xmlns='\(Disco.infoNamespace)'>"
                + "<identity category='client' type='pc'/>\(list)</query></iq>")
    }

    @Test func aComposingHeldForTheDevicesNeverFollowsTheMessage() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        Self.devicesHoldTheirAnswers(harness)
        try harness.deliver(Self.available(Self.phone))
        try await harness.barrier()

        let typing = Task { try await harness.session.setChatState(.composing, chatID: chatID) }
        try await waitUntil("devices asked") { Self.discoRequestsToBob(harness).count == 1 }
        let id = try await harness.session.send(text: "Hi", chatID: chatID)
        let originID = try #require(try harness.database.message(id: id)?.originID)
        try await waitUntil("sent") { !harness.server.messages(id: originID).isEmpty }
        let request = try #require(Self.discoRequestsToBob(harness).first)
        try Self.answer(request, features: [Self.chatStates], harness)
        try await typing.value
        try await harness.barrier()
        // The message went first: the composing that announced it never follows.
        #expect(Self.sentStates(harness, "composing") == 0)

        // The answer is in: the next composing goes out, once, and nothing else follows.
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await waitUntil("composing") { Self.sentStates(harness, "composing") == 1 }
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 1)
        await harness.stop()
    }

    @Test func aComposingHeldForTheDevicesGoesWhenNothingWasSent() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        Self.devicesHoldTheirAnswers(harness)
        try harness.deliver(Self.available(Self.phone))
        try await harness.barrier()

        // It does not wait for the devices.
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await waitUntil("devices asked") { Self.discoRequestsToBob(harness).count == 1 }
        #expect(Self.sentStates(harness, "composing") == 0)
        let request = try #require(Self.discoRequestsToBob(harness).first)
        try Self.answer(request, features: [Self.chatStates], harness)
        try await waitUntil("composing") { Self.sentStates(harness, "composing") == 1 }
        await harness.stop()
    }

    @Test func theDevicesAreAskedTogether() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        Self.devicesHoldTheirAnswers(harness)
        try harness.deliver(Self.available(Self.phone))
        try harness.deliver(Self.available("bob@example.test/tablet"))
        try await harness.barrier()

        let typing = Task { try await harness.session.setChatState(.composing, chatID: chatID) }
        try await waitUntil("both asked") { Self.discoRequestsToBob(harness).count == 2 }
        for request in Self.discoRequestsToBob(harness) {
            try Self.answer(request, features: [], harness)
        }
        try await typing.value
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 0)
        await harness.stop()
    }

    @Test func afterAReplyWithoutStatesMessagesCarryNoActive() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: nil)
        try Self.reply(harness, id: "r1", state: nil)
        try await harness.barrier()

        let first = try await harness.session.send(text: "One", chatID: chatID)
        let firstID = try #require(try harness.database.message(id: first)?.originID)
        let one = try await OMEMOPipelineTests.sent(firstID, by: harness)
        #expect(one.child("active", namespace: Self.chatStates) == nil)

        // A state from bob brings them back, the `active` in messages too.
        try harness.deliver(
            "<message from='\(Self.phone)' to='\(Self.me)' type='chat' id='r3'>"
                + "<active xmlns='\(Self.chatStates)'/></message>")
        try await harness.barrier()
        let second = try await harness.session.send(text: "Two", chatID: chatID)
        let secondID = try #require(try harness.database.message(id: second)?.originID)
        let two = try await OMEMOPipelineTests.sent(secondID, by: harness)
        #expect(two.child("active", namespace: Self.chatStates) != nil)
        await harness.stop()
    }

    @Test func aReactionOrARetractionIsNoReplyWithoutStates() async throws {
        let harness = try await Self.harness()
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(Self.bob)?.id)
        try Self.online(harness, features: nil)
        try Self.reply(harness, id: "r1", state: "active")
        try await harness.barrier()

        try harness.deliver(
            "<message from='\(Self.phone)' to='\(Self.me)' type='chat' id='x1'>"
                + "<reactions xmlns='urn:xmpp:reactions:0' id='r1'><reaction>👍</reaction>"
                + "</reactions></message>")
        try harness.deliver(
            "<message from='\(Self.phone)' to='\(Self.me)' type='chat' id='x2'>"
                + "<body>This person attempted to retract a previous message.</body>"
                + "<retract xmlns='urn:xmpp:message-retract:1' id='r1'/>"
                + "<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>"
                + "</message>")
        try await harness.barrier()
        try await harness.session.setChatState(.composing, chatID: chatID)
        try await harness.barrier()
        #expect(Self.sentStates(harness, "composing") == 1)
        await harness.stop()
    }

    @Test func aJoinedRoomTakesStatesWithoutNegotiation() async throws {
        let harness = try await RoomMessageTests.harness(state: .joined)
        try await harness.goOnline()
        let chatID = try #require(try harness.chat(RoomMessageTests.room)?.id)

        try await harness.session.setChatState(.composing, chatID: chatID)
        try await harness.barrier()
        #expect(
            harness.server.stanzas.contains {
                $0.name == "message" && $0.to?.description == RoomMessageTests.room
                    && $0.child("composing", namespace: Self.chatStates) != nil
            })
        await harness.stop()
    }
}
