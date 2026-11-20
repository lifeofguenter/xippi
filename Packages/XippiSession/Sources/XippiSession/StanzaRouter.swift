import XMPPCore
import os

/// Hands incoming IQ requests and messages to the handlers registered for them.
///
/// - IQs: a `get` or `set` goes to the handlers registered for its first child element, by
///   name and namespace, then to those registered for the namespace alone, in the order they
///   were registered. The first handler that returns a reply answers it; a handler returns nil
///   to leave the request to the next one. A request no handler answers gets
///   `service-unavailable` (RFC 6120 8.4), one whose handler throws gets
///   `internal-server-error`, and one without a child element `bad-request`. Results and
///   errors are never answered (RFC 6120 8.2.3), so two entities cannot bounce errors back
///   and forth.
/// - Messages: offered to the handlers registered for any of their child elements, in the
///   order they were registered, until one takes it.
public struct StanzaRouter: Sendable {
    /// Returns the reply to send, or nil to leave the request to the next handler.
    public typealias IQHandler = @Sendable (Element) async throws -> Element?
    /// Returns whether it took the message.
    public typealias MessageHandler = @Sendable (Element) async -> Bool

    struct Key: Hashable, Sendable {
        var name: String?
        var namespace: String

        func matches(_ element: Element) -> Bool {
            element.namespace == namespace && (name == nil || element.name == name)
        }
    }

    private var iqHandlers: [Key: [IQHandler]] = [:]
    private var messageHandlers: [(key: Key, handler: MessageHandler)] = []

    private static let log = Logger(subsystem: "eu.xippi.Xippi", category: "session")

    public init() {}

    /// Handles IQ requests whose first child is `name` in `namespace`; a nil name takes every
    /// child in the namespace.
    public mutating func register(
        iq name: String?, namespace: String, handler: @escaping IQHandler
    ) {
        iqHandlers[Key(name: name, namespace: namespace), default: []].append(handler)
    }

    /// Offers messages with a child `name` in `namespace` (any name when nil).
    public mutating func register(
        message name: String?, namespace: String, handler: @escaping MessageHandler
    ) {
        messageHandlers.append((Key(name: name, namespace: namespace), handler))
    }

    /// The reply to an incoming IQ; nil when it must not be answered (a result or an error).
    public func route(iq: Element) async -> Element? {
        guard iq.name == "iq", iq.type == IQType.get.rawValue || iq.type == IQType.set.rawValue
        else { return nil }
        guard let payload = iq.elements.first, let namespace = payload.namespace else {
            return iq.errorResponse(StanzaError(type: .modify, condition: .badRequest))
        }
        let handlers =
            (iqHandlers[Key(name: payload.name, namespace: namespace)] ?? [])
            + (iqHandlers[Key(name: nil, namespace: namespace)] ?? [])
        for handler in handlers {
            do {
                if let reply = try await handler(iq) { return reply }
            } catch {
                Self.log.error(
                    "Handler for \(namespace, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)"
                )
                return iq.errorResponse(StanzaError(type: .cancel, condition: .internalServerError))
            }
        }
        return iq.errorResponse(StanzaError(type: .cancel, condition: .serviceUnavailable))
    }

    /// Offers a message to the handlers registered for its children; true when one took it.
    public func route(message: Element) async -> Bool {
        let children = message.elements
        for (key, handler) in messageHandlers where children.contains(where: key.matches) {
            if await handler(message) { return true }
        }
        return false
    }
}
