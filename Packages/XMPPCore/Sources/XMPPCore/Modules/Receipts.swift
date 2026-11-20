/// XEP-0184 Message Delivery Receipts. `ChatMessage` reads them and `ChatMessage.receipt(for:)`
/// answers them.
public enum Receipts {
    public static let namespace = "urn:xmpp:receipts"

    /// Asks for a receipt.
    public static let request = Element("request", namespace: namespace)

    /// Confirms delivery of the message with this id.
    public static func received(id: String) -> Element {
        Element("received", namespace: namespace, attributes: ["id": id])
    }
}
