import Testing

@testable import XMPPCore

@Suite struct ReceiptsTests {
    @Test func elements() throws {
        let request = try ModuleFixtures.stanza("xep-0184-1.4.0", "request")
        #expect(Receipts.request == request.child("request", namespace: Receipts.namespace))
        let receipt = try ModuleFixtures.stanza("xep-0184-1.4.0", "receipt")
        #expect(
            Receipts.received(id: "richard2-4.1.247")
                == receipt.child("received", namespace: Receipts.namespace))
    }
}
