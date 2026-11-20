import Foundation
import OMEMO
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// OMEMO between our own clients on Prosody (`make up`), with XIPPI_INTEGRATION=1.
@Suite(
    .enabled(if: TestServers.enabled, "XIPPI_INTEGRATION=1"),
    .enabled(if: TestServers.testCAAvailable, "make certs writes dev/certs"),
    .timeLimit(.minutes(3)),
    .serialized
)
struct OMEMOIntegrationTests {
    @Test func omemoBetweenAliceAndBobBothVersions() async throws {
        // Accounts of this run's own: the servers keep what earlier runs published.
        let alice = try await TestServers.newProsodyAccount("alice")
        let bob = try await TestServers.newProsodyAccount("bob")
        let endpoint = TestServers.prosodyDirectTLS
        // Alice's second Mac and Bob first: Alice's first Mac then finds both listed.
        let alice2 = try await TestClient(alice, resource: "omemo-2", endpoint: endpoint)
        let bobClient = try await TestClient(bob, resource: "omemo", endpoint: endpoint)
        let alice1 = try await TestClient(alice, resource: "omemo-1", endpoint: endpoint)
        let clients = [alice1, alice2, bobClient]
        do {
            try await Self.exchange(
                alice: alice, bob: bob, alice1: alice1, alice2: alice2, bobClient: bobClient)
        } catch {
            for client in clients { await client.session.stop() }
            throw error
        }
        for client in clients { await client.session.stop() }
    }

    /// Alice and Bob write to each other in each version in turn; Alice's second Mac reads
    /// both directions too, her own message from its sent carbon.
    static func exchange(
        alice: String, bob: String, alice1: TestClient, alice2: TestClient,
        bobClient: TestClient
    ) async throws {
        for client in [alice2, bobClient, alice1] { try await client.comeOnline() }
        let aliceChat = try alice1.omemoChat(with: bob)
        let bobChat = try bobClient.omemoChat(with: alice)
        let account = try JID(alice)
        try await poll("both of Alice's Macs listed") {
            let ownDevices = await alice1.session.omemoDevices(of: account)
            return OMEMO.OMEMOVersion.allCases.allSatisfy { version in
                ownDevices.filter { $0.version == version && $0.isActive }.count == 2
            }
        }

        let bobAccount = try JID(bob)
        // Each device's fingerprint, as its own account shows it.
        func fingerprints(of client: TestClient, _ jid: JID) async -> Set<String> {
            Set(
                await client.session.omemoDevices(of: jid).filter(\.isThisDevice).compactMap(
                    \.fingerprint))
        }
        let alice1Keys = await fingerprints(of: alice1, account)
        let bobKeys = await fingerprints(of: bobClient, bobAccount)

        // Left to choose, two Xippi clients speak OMEMO 2.
        let unforced = "Hello Bob, as chosen"
        try await alice1.session.send(text: unforced, chatID: aliceChat)
        #expect(try await bobClient.message(unforced).encryption == .omemo)
        #expect(alice1.log.outgoing.contains { $0.contains(unforced) } == false)
        #expect(
            alice1.log.outgoing.contains {
                $0.contains("<encrypted xmlns='\(OMEMO.OMEMOVersion.v2.rawValue)'")
            })

        for version in OMEMO.OMEMOVersion.allCases {
            for client in [alice1, alice2, bobClient] {
                await client.session.omemo.setForcedVersion(version)
            }
            let tag = version == .v2 ? "OMEMO 2" : "legacy OMEMO"

            // Alice to Bob; Alice's other Mac reads its copy from the sent carbon.
            let toBob = "Hello Bob, over \(tag)"
            try await alice1.session.send(text: toBob, chatID: aliceChat)
            let received = try await bobClient.message(toBob)
            #expect(received.direction == .incoming)
            #expect(received.encryption == .omemo)
            #expect(received.senderDeviceFingerprint.map(alice1Keys.contains) == true)
            let copy = try await alice2.message(toBob)
            #expect(copy.direction == .outgoing)
            #expect(copy.encryption == .omemo)

            // Bob to Alice, read on both of her Macs.
            let toAlice = "Hello Alice, over \(tag)"
            try await bobClient.session.send(text: toAlice, chatID: bobChat)
            for client in [alice1, alice2] {
                let message = try await client.message(toAlice)
                #expect(message.direction == .incoming)
                #expect(message.encryption == .omemo)
                #expect(message.senderDeviceFingerprint.map(bobKeys.contains) == true)
            }

            // The text never went over the wire, and these went in this version.
            let wire = alice1.log.outgoing + bobClient.log.outgoing
            #expect(!wire.contains { $0.contains(toBob) || $0.contains(toAlice) })
            let fromBob = try await alice1.message(toAlice)
            for (log, id) in [(alice1.log, received.originID), (bobClient.log, fromBob.originID)] {
                let id = try #require(id)
                #expect(
                    log.outgoing.contains {
                        $0.contains("id='\(id)'")
                            && $0.contains("<encrypted xmlns='\(version.rawValue)'")
                    })
            }
        }
    }
}
