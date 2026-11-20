import Testing
import XMPPCore
import XMPPTestSupport

@Test func moduleLoads() {
    #expect(XMPPCoreModule.name == "XMPPCore")
}

@Test func testSupportLoads() {
    #expect(XMPPTestSupportModule.name == "XMPPTestSupport")
    #expect(XMPPTestSupportModule.coreName == "XMPPCore")
}
