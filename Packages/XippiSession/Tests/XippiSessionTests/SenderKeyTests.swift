import Foundation
import Testing
import XMPPCore
import XippiStore

@testable import XippiSession

/// Who wrote a message, as the transcript groups runs: a nick never equals an identity key
/// (Task 26b m8).
@Suite struct SenderKeyTests {
    /// A participant whose nick is another participant's full address does not join that
    /// participant's run.
    @Test func aNickThatIsAnotherParticipantsAddressIsAnotherSender() async throws {
        let harness = try await ChannelToolsTests.harness()
        try await harness.goOnline()
        try harness.deliver(
            ChannelToolsTests.channelMessage(from: "pid-a", id: "real", stamp: ""))
        let spoof = "\(ChannelToolsTests.channel)/pid-a"
        try harness.deliver(
            ChannelToolsTests.channelMessage(
                from: "pid-eve", id: "spoof",
                stamp: "<mix xmlns='urn:xmpp:mix:core:1'><nick>\(spoof)</nick></mix>"))
        try await waitUntil("stored") { try harness.messages().count == 2 }
        let items = try harness.database.transcriptItems(for: try harness.messages())
        let keys = items.map { $0.senderKey(inRoom: true) }
        #expect(Set(keys).count == 2, "\(keys)")
        #expect(items.map(\.message.senderNick).contains(spoof))
        await harness.stop()
    }
}
