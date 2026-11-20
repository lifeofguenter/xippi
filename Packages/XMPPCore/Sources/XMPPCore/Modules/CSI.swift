/// XEP-0352 Client State Indication: nonzas sent when the user starts or stops looking at the
/// app, when the server offers the `csi` stream feature.
public enum CSI {
    public static let namespace = "urn:xmpp:csi:0"
    public static let active = Element("active", namespace: namespace)
    public static let inactive = Element("inactive", namespace: namespace)
}
