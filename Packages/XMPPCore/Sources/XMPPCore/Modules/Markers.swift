/// XEP-0333 Displayed Markers. `ChatMessage` reads them and `ChatMessage.displayed(...)` sends
/// them.
public enum Markers {
    public static let namespace = "urn:xmpp:chat-markers:0"

    /// Asks to be told when the message has been displayed.
    public static let markable = Element("markable", namespace: namespace)

    /// Everything up to the message with this id has been displayed. In a room the id is the
    /// room's stanza id of the message.
    public static func displayed(id: String) -> Element {
        Element("displayed", namespace: namespace, attributes: ["id": id])
    }
}
