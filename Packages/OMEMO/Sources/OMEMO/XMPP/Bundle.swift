import Foundation
import XMPPCore

/// The key bundle each device publishes over PEP, so that others can start sessions with it.
///
/// Legacy, node `eu.siacs.conversations.axolotl.bundles:<device id>`, item `current`, keys with
/// their 0x05 type byte:
///
/// ```xml
/// <bundle xmlns='eu.siacs.conversations.axolotl'>
///   <signedPreKeyPublic signedPreKeyId='1'>...</signedPreKeyPublic>
///   <signedPreKeySignature>...</signedPreKeySignature>
///   <identityKey>...</identityKey>
///   <prekeys><preKeyPublic preKeyId='1'>...</preKeyPublic></prekeys>
/// </bundle>
/// ```
///
/// OMEMO 2, node `urn:xmpp:omemo:2:bundles`, item `<device id>`, the node holding every
/// device's bundle (`pubsub#max_items` = `max`):
///
/// ```xml
/// <bundle xmlns='urn:xmpp:omemo:2'>
///   <spk id='1'>...</spk><spks>...</spks><ik>...</ik>
///   <prekeys><pk id='1'>...</pk></prekeys>
/// </bundle>
/// ```
public enum OMEMOBundle {
    /// The most pre keys read from one bundle: XEP-0384 asks for about 100.
    public static let maxPreKeys = 1_000

    public static func node(version: OMEMOVersion, deviceID: UInt32) -> String {
        switch version {
        case .v03: "eu.siacs.conversations.axolotl.bundles:\(deviceID)"
        case .v2: "urn:xmpp:omemo:2:bundles"
        }
    }

    public static func itemID(version: OMEMOVersion, deviceID: UInt32) -> String {
        switch version {
        case .v03: "current"
        case .v2: String(deviceID)
        }
    }

    /// XEP-0060 publish-options for the bundle node: open access, and for OMEMO 2, whose node
    /// keeps one item per device, as many items as the service allows.
    public static func publishOptions(version: OMEMOVersion) -> KeyValuePairs<String, [String]> {
        switch version {
        case .v03: ["pubsub#access_model": ["open"]]
        case .v2: ["pubsub#access_model": ["open"], "pubsub#max_items": ["max"]]
        }
    }

    /// The bundle of this device: its identity key, the current signed pre key, and every
    /// one-time pre key.
    public static func element(
        version: OMEMOVersion, identityKey: Data, signedPreKey: SignedPreKey,
        preKeys: [OneTimePreKey]
    ) -> Element {
        let ns = version.rawValue
        func keyElement(_ name: String, _ attributes: [String: String], _ bytes: Data) -> Element {
            Element(
                name, namespace: ns, attributes: attributes,
                children: [.text(bytes.base64EncodedString())])
        }
        let names = Names(version: version)
        var bundle = Element("bundle", namespace: ns)
        bundle.append(
            keyElement(
                names.signedPreKey, [names.signedPreKeyID: String(signedPreKey.id)],
                version.encodePublicKey(signedPreKey.keyPair.publicKey)))
        bundle.append(keyElement(names.signature, [:], signedPreKey.signature))
        bundle.append(keyElement(names.identityKey, [:], version.encodePublicKey(identityKey)))
        var list = Element("prekeys", namespace: ns)
        for preKey in preKeys {
            list.append(
                keyElement(
                    names.preKey, [names.preKeyID: String(preKey.id)],
                    version.encodePublicKey(preKey.keyPair.publicKey)))
        }
        bundle.append(list)
        return bundle
    }

    /// Reads another device's bundle. Nil when it is not a bundle of this version, or when the
    /// identity key, the signed pre key or its signature is missing or of the wrong length.
    /// Pre keys that cannot be read are skipped, and nil is returned when none is left. The
    /// signature is not checked here: X3DH checks it before using the bundle.
    public static func parse(_ element: Element, version: OMEMOVersion) -> PreKeyBundle? {
        let ns = version.rawValue
        let names = Names(version: version)
        guard element.name == "bundle", element.namespace == ns,
            let signedPreKeyElement = element.child(names.signedPreKey, namespace: ns),
            let signedPreKeyID = signedPreKeyElement[attribute: names.signedPreKeyID].flatMap(
                UInt32.init),
            let signedPreKey = key(signedPreKeyElement, version: version),
            let signature = element.child(names.signature, namespace: ns).flatMap(base64),
            signature.count == 64,
            let identityKey = element.child(names.identityKey, namespace: ns).flatMap({
                key($0, version: version)
            })
        else { return nil }
        var preKeys: [(id: UInt32, key: Data)] = []
        var seen = Set<UInt32>()
        let candidates =
            element.child("prekeys", namespace: ns)?.children(
                names.preKey, namespace: ns) ?? []
        for candidate in candidates.prefix(maxPreKeys) {
            guard let id = candidate[attribute: names.preKeyID].flatMap(UInt32.init),
                let key = key(candidate, version: version), seen.insert(id).inserted
            else { continue }
            preKeys.append((id, key))
        }
        guard !preKeys.isEmpty else { return nil }
        return PreKeyBundle(
            identityKey: identityKey, signedPreKeyID: signedPreKeyID, signedPreKey: signedPreKey,
            signedPreKeySignature: signature, preKeys: preKeys)
    }

    private static func key(_ element: Element, version: OMEMOVersion) -> Data? {
        base64(element).flatMap { try? version.decodePublicKey($0) }
    }

    /// The element's text as base64, surrounding whitespace ignored.
    static func base64(_ element: Element) -> Data? {
        Data(base64Encoded: element.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Names {
        let signedPreKey: String
        let signedPreKeyID: String
        let signature: String
        let identityKey: String
        let preKey: String
        let preKeyID: String

        init(version: OMEMOVersion) {
            switch version {
            case .v03:
                signedPreKey = "signedPreKeyPublic"
                signedPreKeyID = "signedPreKeyId"
                signature = "signedPreKeySignature"
                identityKey = "identityKey"
                preKey = "preKeyPublic"
                preKeyID = "preKeyId"
            case .v2:
                signedPreKey = "spk"
                signedPreKeyID = "id"
                signature = "spks"
                identityKey = "ik"
                preKey = "pk"
                preKeyID = "id"
            }
        }
    }
}
