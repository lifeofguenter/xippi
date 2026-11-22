import Foundation
import Testing
import XMPPCore

@testable import XippiSession

/// Deleting the account on its server from the app (XEP-0077 section 3.2): Xippi only removed
/// accounts from the Mac.
@Suite("AccountDeletion")
struct AccountDeletionTests {
    /// Answers the account's own `<remove/>` with `reply`, counting the requests.
    static func answerRemove(
        _ server: SessionServer, _ reply: @escaping @Sendable (Element) -> String
    )
        -> Locked<[Element]>
    {
        let removes = Locked<[Element]>([])
        server.setResponder { iq in
            guard iq[attribute: "type"] == "set",
                let query = iq.child("query", namespace: Registration.namespace),
                query.child("remove", namespace: Registration.namespace) != nil
            else { return nil }
            removes.withLock { $0.append(iq) }
            return [reply(iq)]
        }
        return removes
    }

    @Test(.timeLimit(.minutes(1)))
    func theAccountsOwnServerIsAskedToDeleteIt() async throws {
        let harness = try await SessionHarness()
        let removes = Self.answerRemove(harness.server) {
            "<iq type='result' id='\($0.id ?? "")'/>"
        }
        try await harness.goOnline()

        try await harness.session.deleteFromServer()

        let sent = try #require(removes.value.first)
        #expect(removes.value.count == 1)
        // To the account's own server: no `to`, as XEP-0077 section 3.2 has it.
        #expect(sent[attribute: "to"] == nil)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aServerThatRefusesSaysWhy() async throws {
        let harness = try await SessionHarness()
        _ = Self.answerRemove(harness.server) {
            SessionServer.error($0, condition: "not-allowed")
        }
        try await harness.goOnline()

        await #expect {
            try await harness.session.deleteFromServer()
        } throws: { error in
            guard case .refused(let stanza) = error as? SessionError else { return false }
            return stanza.condition == .notAllowed
        }
        await harness.stop()
    }
}
