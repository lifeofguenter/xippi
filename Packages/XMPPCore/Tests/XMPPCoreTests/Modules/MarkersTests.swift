import Testing

@testable import XMPPCore

@Suite struct MarkersTests {
    @Test func elements() throws {
        let markable = try ModuleFixtures.stanza("xep-0333-1.0.0", "markable")
        #expect(Markers.markable == markable.child("markable", namespace: Markers.namespace))
        let displayed = try ModuleFixtures.stanza("xep-0333-1.0.0", "displayed")
        #expect(
            Markers.displayed(id: "the-msg-1")
                == displayed.child("displayed", namespace: Markers.namespace))
    }
}
