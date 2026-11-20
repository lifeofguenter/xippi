import CryptoKit
import Foundation
import Testing

@testable import XMPPCore

@Suite struct CapsTests {
    static func query(_ name: String) throws -> Element {
        let iq = try ModuleFixtures.stanza("xep-0115-1.6.0-generation", name)
        return try #require(iq.child("query", namespace: Disco.infoNamespace))
    }

    static func info(_ name: String) throws -> DiscoInfo {
        try #require(DiscoInfo(element: try query(name)))
    }

    static func sha1(_ s: String) -> String {
        Data(Insecure.SHA1.hash(data: Data(s.utf8))).base64EncodedString()
    }

    @Test func simpleGenerationExample() throws {
        #expect(Caps.verificationString(try Self.info("simple")) == "QgayPKawpkPSDYmwT/WM94uAlu0=")
    }

    @Test func complexGenerationExample() throws {
        #expect(Caps.verificationString(try Self.info("complex")) == "q07IKJEyjvHSyhy//CH0CxmKi8w=")
    }

    @Test func identitiesSortByCategoryTypeAndLangInOctetOrder() {
        // By tuple, "a" sorts before "a-b"; by the formatted string ("a/" vs "a-b/") it would not.
        let info = DiscoInfo(
            identities: [
                DiscoInfo.Identity(category: "a-b", type: "x"),
                DiscoInfo.Identity(category: "a", type: "z"),
                DiscoInfo.Identity(category: "a", type: "y", lang: "en"),
                DiscoInfo.Identity(category: "a", type: "y", lang: "de"),
            ],
            features: ["é", "z", "Z"])
        #expect(
            Caps.verificationString(info)
                == Self.sha1("a/y/de/<a/y/en/<a/z//<a-b/x//<Z<z<é<"))
    }

    @Test func entityTextIsHashedLiterally() {
        let info = DiscoInfo(
            identities: [
                DiscoInfo.Identity(
                    category: "client", type: "pc",
                    name: "SomeClient&lt;http://jabber.org/protocol/muc")
            ],
            features: [Disco.infoNamespace])
        #expect(
            Caps.verificationString(info)
                == Self.sha1(
                    "client/pc//SomeClient&lt;http://jabber.org/protocol/muc<"
                        + "http://jabber.org/protocol/disco#info<"))
    }

    @Test func formsWithoutAHiddenFormTypeAreLeftOut() throws {
        var info = try Self.info("simple")
        info.forms.append(
            DataForm(type: .result, fields: [DataForm.Field(variable: "FORM_TYPE", values: ["x"])]))
        info.forms.append(
            DataForm(type: .result, fields: [DataForm.Field(variable: "a", values: ["b"])]))
        #expect(Caps.verificationString(info) == "QgayPKawpkPSDYmwT/WM94uAlu0=")
    }

    @Test func advertisementRoundTrips() throws {
        let presence = try ModuleFixtures.stanza("xep-0115-1.6.0", "presence-caps")
        let c = try #require(presence.child("c", namespace: Caps.namespace))
        let caps = try #require(Caps.Advertisement(element: c))
        #expect(caps.hash == "sha-1")
        #expect(caps.node == "http://code.google.com/p/exodus")
        #expect(caps.ver == "QgayPKawpkPSDYmwT/WM94uAlu0=")
        #expect(caps.element.normalized == c.normalized)
        #expect(Caps.Advertisement(element: Element("c", namespace: Caps.namespace)) == nil)
    }

    @Test func presenceElement() throws {
        let info = try Self.info("simple")
        let c = Caps.presenceElement(node: "http://code.google.com/p/exodus", info: info)
        let expected = try ModuleFixtures.stanza("xep-0115-1.6.0", "presence-caps")
        #expect(c.normalized == expected.child("c")?.normalized)
    }

    @Test func verifiesAMatchingAnswer() throws {
        let caps = Caps.Advertisement(
            node: "http://code.google.com/p/exodus", ver: "QgayPKawpkPSDYmwT/WM94uAlu0=")
        #expect(Caps.verify(caps, query: try Self.query("simple")))
        let complex = Caps.Advertisement(
            node: "http://psi-im.org", ver: "q07IKJEyjvHSyhy//CH0CxmKi8w=")
        #expect(Caps.verify(complex, query: try Self.query("complex")))
    }

    @Test func refusesAWrongHashOrAnUnknownFunction() throws {
        let query = try Self.query("simple")
        #expect(!Caps.verify(Caps.Advertisement(node: "n", ver: "AAAA"), query: query))
        #expect(
            !Caps.verify(
                Caps.Advertisement(hash: "md5", node: "n", ver: "QgayPKawpkPSDYmwT/WM94uAlu0="),
                query: query))
        #expect(
            !Caps.verify(
                Caps.Advertisement(hash: nil, node: "n", ver: "QgayPKawpkPSDYmwT/WM94uAlu0="),
                query: query))
    }

    @Test func refusesIllFormedAnswers() throws {
        let caps = Caps.Advertisement(node: "n", ver: "QgayPKawpkPSDYmwT/WM94uAlu0=")
        let query = try Self.query("simple")

        var duplicateFeature = query
        duplicateFeature.append(
            Element(
                "feature", namespace: Disco.infoNamespace,
                attributes: ["var": "http://jabber.org/protocol/muc"]))
        #expect(!Caps.verify(caps, query: duplicateFeature))

        var duplicateIdentity = query
        duplicateIdentity.append(
            Element(
                "identity", namespace: Disco.infoNamespace,
                attributes: ["category": "client", "type": "pc", "name": "Exodus 0.9.1"]))
        #expect(!Caps.verify(caps, query: duplicateIdentity))

        let complex = Caps.Advertisement(node: "n", ver: "q07IKJEyjvHSyhy//CH0CxmKi8w=")
        var twoForms = try Self.query("complex")
        if let form = twoForms.child("x", namespace: DataForm.namespace) { twoForms.append(form) }
        #expect(!Caps.verify(complex, query: twoForms))
    }

    /// A '<' inside a factor could make two different answers hash alike, so it is refused.
    @Test func refusesALessThanInsideAFactor() {
        // Both answers produce S = "client/pc//x<http://jabber.org/protocol/muc<".
        let forged = DiscoInfo(
            identities: [
                DiscoInfo.Identity(
                    category: "client", type: "pc", name: "x<http://jabber.org/protocol/muc")
            ])
        let honest = DiscoInfo(
            identities: [DiscoInfo.Identity(category: "client", type: "pc", name: "x")],
            features: ["http://jabber.org/protocol/muc"])
        let ver = Caps.verificationString(honest)
        #expect(Caps.verificationString(forged) == ver)
        let caps = Caps.Advertisement(node: "n", ver: ver)
        #expect(Caps.verify(caps, query: honest.element()))
        #expect(!Caps.verify(caps, query: forged.element()))
    }
}
