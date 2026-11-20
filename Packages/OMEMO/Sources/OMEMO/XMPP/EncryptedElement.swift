import Foundation
import XMPPCore

/// The `<encrypted/>` element of an OMEMO message.
///
/// Legacy:
///
/// ```xml
/// <encrypted xmlns='eu.siacs.conversations.axolotl'>
///   <header sid='27183'>
///     <key rid='31415'>...</key>
///     <key prekey='true' rid='12321'>...</key>
///     <iv>...</iv>
///   </header>
///   <payload>...</payload>
/// </encrypted>
/// ```
///
/// OMEMO 2, keys grouped by the recipient's bare JID and no IV:
///
/// ```xml
/// <encrypted xmlns='urn:xmpp:omemo:2'>
///   <header sid='27183'>
///     <keys jid='juliet@capulet.lit'><key rid='31415'>...</key></keys>
///     <keys jid='romeo@montague.lit'><key kex='true' rid='12321'>...</key></keys>
///   </header>
///   <payload>...</payload>
/// </encrypted>
/// ```
///
/// Without `<payload/>` it is an empty OMEMO message.
struct EncryptedElement: Sendable {
    struct Key: Sendable, Equatable {
        /// The recipient's bare JID (OMEMO 2); nil in legacy messages.
        var jid: JID?
        var deviceID: UInt32
        var isKeyExchange: Bool
        /// Nil when the text is not base64.
        var data: Data?
    }

    var version: OMEMOVersion
    var senderDeviceID: UInt32
    var keys: [Key]
    /// Legacy only.
    var iv: Data?
    var payload: Data?

    init(
        version: OMEMOVersion, senderDeviceID: UInt32, keys: [Key], iv: Data?, payload: Data?
    ) {
        self.version = version
        self.senderDeviceID = senderDeviceID
        self.keys = keys
        self.iv = iv
        self.payload = payload
    }

    /// Nil unless `element` is an `<encrypted/>` element of this version with a header naming a
    /// sender device, and (when present) a payload in base64. Keys with a recipient that cannot
    /// be read are skipped; keys whose text is not base64 are kept without data.
    init?(parsing element: Element, version: OMEMOVersion) {
        let ns = version.rawValue
        guard element.name == "encrypted", element.namespace == ns,
            let header = element.child("header", namespace: ns),
            let sid = header[attribute: "sid"].flatMap(UInt32.init), sid != 0
        else { return nil }
        var keys: [Key] = []
        switch version {
        case .v03:
            for key in header.children("key", namespace: ns) {
                if let parsed = Self.key(key, jid: nil, flag: "prekey") { keys.append(parsed) }
            }
            iv = header.child("iv", namespace: ns).flatMap(OMEMOBundle.base64)
        case .v2:
            for group in header.children("keys", namespace: ns) {
                guard let jid = group[attribute: "jid"].flatMap({ try? JID($0) }) else { continue }
                for key in group.children("key", namespace: ns) {
                    if let parsed = Self.key(key, jid: jid.bare, flag: "kex") {
                        keys.append(parsed)
                    }
                }
            }
            iv = nil
        }
        if let payloadElement = element.child("payload", namespace: ns) {
            guard let payload = OMEMOBundle.base64(payloadElement) else { return nil }
            self.payload = payload
        } else {
            payload = nil
        }
        self.version = version
        senderDeviceID = sid
        self.keys = keys
    }

    private static func key(_ element: Element, jid: JID?, flag: String) -> Key? {
        guard let rid = element[attribute: "rid"].flatMap(UInt32.init), rid != 0 else {
            return nil
        }
        let marked = element[attribute: flag]
        return Key(
            jid: jid, deviceID: rid, isKeyExchange: marked == "true" || marked == "1",
            data: OMEMOBundle.base64(element))
    }

    /// The key for one device of `jid`; legacy keys name no JID, so only the device id counts.
    func key(for jid: JID, deviceID: UInt32) -> Key? {
        keys.first { $0.deviceID == deviceID && ($0.jid == nil || $0.jid == jid.bare) }
    }

    var element: Element {
        let ns = version.rawValue
        var header = Element("header", namespace: ns, attributes: ["sid": String(senderDeviceID)])
        func keyElement(_ key: Key) -> Element {
            var element = Element("key", namespace: ns, attributes: ["rid": String(key.deviceID)])
            if key.isKeyExchange {
                element[attribute: version == .v03 ? "prekey" : "kex"] = "true"
            }
            element.append(text: key.data?.base64EncodedString() ?? "")
            return element
        }
        switch version {
        case .v03:
            for key in keys { header.append(keyElement(key)) }
            if let iv {
                header.append(
                    Element("iv", namespace: ns, children: [.text(iv.base64EncodedString())]))
            }
        case .v2:
            var order: [JID] = []
            for key in keys {
                if let jid = key.jid, !order.contains(jid) { order.append(jid) }
            }
            for jid in order {
                header.append(
                    Element(
                        "keys", namespace: ns, attributes: ["jid": jid.description],
                        children: keys.filter { $0.jid == jid }.map { .element(keyElement($0)) }))
            }
        }
        var encrypted = Element("encrypted", namespace: ns, children: [.element(header)])
        if let payload {
            encrypted.append(
                Element("payload", namespace: ns, children: [.text(payload.base64EncodedString())]))
        }
        return encrypted
    }
}
