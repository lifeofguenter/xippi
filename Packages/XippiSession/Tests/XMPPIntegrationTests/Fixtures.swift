import Foundation
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// A room on Prosody that bob made (he owns it) and alice is in, as "bob" and "alice".
struct SharedRoom: Sendable {
    let jid: JID
    let aliceChat: Int64
    let bobChat: Int64

    /// alice in the room.
    var aliceOccupant: JID {
        get throws { try jid.withResource(Self.aliceNick) }
    }

    static let aliceNick = "alice"
    static let bobNick = "bob"
}

/// `count` new rooms on Prosody that bob makes and alice joins. `persistent` rooms outlive a
/// restart of the server. With `history`, bob writes that many messages in each room before
/// alice joins, and the room's archive has them when she does.
func shareRooms(
    _ count: Int, alice: TestClient, bob: TestClient, persistent: Bool = false,
    history: Int = 0, sourceLocation: SourceLocation = #_sourceLocation
) async throws -> [SharedRoom] {
    var rooms: [SharedRoom] = []
    for _ in 0..<count {
        let jid = try TestServers.newRoom(on: .prosody, "room")
        let bobChat = try await bob.session.createRoom(
            jid: jid, nick: SharedRoom.bobNick, persistent: false
        ).chatID
        try await bob.joined(bobChat, sourceLocation: sourceLocation)
        if persistent {
            let connection = bob.session.connection
            let form = try await MUC.config(room: jid, via: connection)
            try await MUC.submitConfig(
                room: jid, form.submit(values: ["muc#roomconfig_persistentroom": ["1"]]),
                via: connection)
        }
        for number in 0..<history {
            let text = "bob's history \(number) in \(jid) \(UUID().uuidString)"
            try await bob.session.send(text: text, chatID: bobChat)
            try await poll("bob's message archived", sourceLocation: sourceLocation) {
                try bob.rows(text).first?.state == .sent
            }
        }
        let aliceChat = try await alice.session.joinRoom(jid: jid, nick: SharedRoom.aliceNick)
        try await alice.joined(aliceChat, sourceLocation: sourceLocation)
        rooms.append(SharedRoom(jid: jid, aliceChat: aliceChat, bobChat: bobChat))
    }
    return rooms
}

/// bob writes in the room, and alice's client stores it: messages flow both ways once more.
func expectMessagesFlow(
    in room: SharedRoom, alice: TestClient, bob: TestClient,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let fromBob = "bob in \(room.jid) \(UUID().uuidString)"
    try await bob.session.send(text: fromBob, chatID: room.bobChat)
    let received = try await alice.message(fromBob, sourceLocation: sourceLocation)
    #expect(received.direction == .incoming, sourceLocation: sourceLocation)
    let fromAlice = "alice in \(room.jid) \(UUID().uuidString)"
    try await alice.session.send(text: fromAlice, chatID: room.aliceChat)
    _ = try await bob.message(fromAlice, sourceLocation: sourceLocation)
    #expect(try alice.rows(fromBob).count == 1, sourceLocation: sourceLocation)
}

// MARK: Server access

/// Integration suites share the test servers. A suite that restarts one needs them to itself:
/// `.restartsTestServers` waits until no `.sharesTestServers` suite of this process runs, and
/// holds the others off until it is done. (Tests in other processes are kept off by running
/// it only through `make test-integration-disruptive`.)
struct ServerAccess: SuiteTrait, TestScoping {
    let exclusive: Bool

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ServerAccessLock.shared.run(exclusive: exclusive, function)
    }
}

extension Trait where Self == ServerAccess {
    static var sharesTestServers: Self { ServerAccess(exclusive: false) }
    static var restartsTestServers: Self { ServerAccess(exclusive: true) }
}

/// A first-come, first-served readers-writer lock over the test servers.
actor ServerAccessLock {
    static let shared = ServerAccessLock()

    private var sharing = 0
    private var exclusive = false
    private var waiting: [(exclusive: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func run(exclusive wantsExclusive: Bool, _ body: @Sendable () async throws -> Void)
        async throws
    {
        if waiting.isEmpty && canGrant(wantsExclusive) {
            grant(wantsExclusive)
        } else {
            await withCheckedContinuation { waiting.append((wantsExclusive, $0)) }
        }
        defer { release(wantsExclusive) }
        try await body()
    }

    private func canGrant(_ wantsExclusive: Bool) -> Bool {
        !exclusive && (!wantsExclusive || sharing == 0)
    }

    private func grant(_ wantsExclusive: Bool) {
        if wantsExclusive { exclusive = true } else { sharing += 1 }
    }

    private func release(_ wasExclusive: Bool) {
        if wasExclusive { exclusive = false } else { sharing -= 1 }
        while let next = waiting.first, canGrant(next.exclusive) {
            waiting.removeFirst()
            grant(next.exclusive)
            next.continuation.resume()
        }
    }
}
