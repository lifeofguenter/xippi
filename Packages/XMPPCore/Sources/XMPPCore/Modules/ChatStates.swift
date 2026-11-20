/// A XEP-0085 chat state.
public enum ChatState: String, Sendable, CaseIterable {
    case active, composing, paused, inactive, gone
}

/// XEP-0085 Chat State Notifications.
public enum ChatStates {
    public static let namespace = "http://jabber.org/protocol/chatstates"

    public static func element(_ state: ChatState) -> Element {
        Element(state.rawValue, namespace: namespace)
    }

    /// The chat state a message carries; nil for none or an unknown one.
    public static func state(in message: Element) -> ChatState? {
        for child in message.elements where child.namespace == namespace {
            if let state = ChatState(rawValue: child.name) { return state }
        }
        return nil
    }

    /// A message that carries only a chat state.
    public static func message(
        _ state: ChatState, to: JID, type: ChatMessage.MessageType = .chat,
        id: String = .stanzaID()
    ) -> Element {
        var message = Element("message", attributes: ["id": id, "to": to.description])
        if type != .normal { message[attribute: "type"] = type.rawValue }
        message.append(element(state))
        return message
    }
}
