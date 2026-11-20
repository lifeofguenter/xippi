import Testing

@testable import XMPPCore

@Suite struct CSITests {
    @Test func elements() throws {
        #expect(CSI.active == (try ModuleFixtures.stanza("xep-0352-1.0.0", "active")))
        #expect(CSI.inactive == (try ModuleFixtures.stanza("xep-0352-1.0.0", "inactive")))
        #expect(CSI.active.xml() == "<active xmlns='urn:xmpp:csi:0'/>")
    }
}
