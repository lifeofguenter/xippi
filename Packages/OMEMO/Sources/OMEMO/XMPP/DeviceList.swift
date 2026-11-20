import XMPPCore

/// The device list each account publishes over PEP, one per OMEMO version:
///
/// - legacy: node `eu.siacs.conversations.axolotl.devicelist`,
///   `<list xmlns='eu.siacs.conversations.axolotl'><device id='1'/></list>`
/// - OMEMO 2: node `urn:xmpp:omemo:2:devices`,
///   `<devices xmlns='urn:xmpp:omemo:2'><device id='1'/></devices>`
///
/// Both are published as item `current` with open access (XEP-0384 requires it, or contacts
/// cannot read the list). OMEMO 2 labels are not read: a label counts only with a valid
/// `labelsig`, which needs the device's identity key, and nothing here shows them yet.
public enum DeviceList {
    public static let itemID = "current"

    /// The most device ids read from one list: bounds the work a hostile list can cause.
    public static let maxDevices = 1_000

    /// XEP-0060 publish-options for the device list node.
    public static let publishOptions: KeyValuePairs<String, [String]> = [
        "pubsub#access_model": ["open"]
    ]

    public static func node(version: OMEMOVersion) -> String {
        switch version {
        case .v03: "eu.siacs.conversations.axolotl.devicelist"
        case .v2: "urn:xmpp:omemo:2:devices"
        }
    }

    static func rootName(version: OMEMOVersion) -> String {
        switch version {
        case .v03: "list"
        case .v2: "devices"
        }
    }

    /// The list element with `devices` in order, each once.
    public static func element(version: OMEMOVersion, devices: [UInt32]) -> Element {
        var list = Element(rootName(version: version), namespace: version.rawValue)
        for id in devices.uniquedInOrder() {
            list.append(
                Element("device", namespace: version.rawValue, attributes: ["id": String(id)]))
        }
        return list
    }

    /// The device ids in a list, in order, each once; nil when `element` is not a device list of
    /// this version. Ids that are not numbers from 1 to 2^32 - 1 are skipped, and at most
    /// `maxDevices` are read. Ids above 2^31 - 1, which XEP-0384 does not allow, are accepted
    /// from others.
    public static func deviceIDs(in element: Element, version: OMEMOVersion) -> [UInt32]? {
        guard element.name == rootName(version: version), element.namespace == version.rawValue
        else { return nil }
        let ids = element.children("device", namespace: version.rawValue).lazy
            .compactMap { $0[attribute: "id"].flatMap(UInt32.init) }
            .filter { $0 != 0 }
        return Array(Array(ids).uniquedInOrder().prefix(maxDevices))
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each only the first time it appears.
    func uniquedInOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
