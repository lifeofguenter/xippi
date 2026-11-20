import Foundation

/// A `<service/>` of a XEP-0215 services list.
public struct ExternalService: Sendable, Equatable {
    /// "stun", "stuns", "turn", "turns", or another registered service type.
    public var type: String
    public var host: String
    public var port: Int?
    /// "udp" or "tcp".
    public var transport: String?
    public var username: String?
    public var password: String?
    /// When the credentials stop working.
    public var expires: Date?
    /// Credentials are needed and, when missing or expired, have to be asked for with
    /// `credentialsRequest`.
    public var restricted: Bool

    public init(
        type: String, host: String, port: Int? = nil, transport: String? = nil,
        username: String? = nil, password: String? = nil, expires: Date? = nil,
        restricted: Bool = false
    ) {
        self.type = type
        self.host = host
        self.port = port
        self.transport = transport
        self.username = username
        self.password = password
        self.expires = expires
        self.restricted = restricted
    }

    /// Nil when `type` or `host` is missing, or `port`, `expires` or `restricted` cannot be read.
    public init?(element: Element) {
        guard element.name == "service", element.namespace == ExternalServices.namespace,
            let type = element[attribute: "type"], !type.isEmpty,
            let host = element[attribute: "host"], !host.isEmpty
        else { return nil }
        var port: Int?
        if let text = element[attribute: "port"] {
            guard let value = Int(text) else { return nil }
            port = value
        }
        var expires: Date?
        if let text = element[attribute: "expires"] {
            guard let date = XMPPDateTime.parse(text) else { return nil }
            expires = date
        }
        var restricted = false
        switch element[attribute: "restricted"] {
        case nil, "false", "0": break
        case "true", "1": restricted = true
        default: return nil
        }
        self.init(
            type: type, host: host, port: port, transport: element[attribute: "transport"],
            username: element[attribute: "username"], password: element[attribute: "password"],
            expires: expires, restricted: restricted)
    }

    /// The `<credentials/>` payload asking for this service's credentials (XEP-0215 section
    /// 3.3), for an IQ get to the server that listed it.
    public var credentialsRequest: Element {
        let namespace = ExternalServices.namespace
        return Element(
            "credentials", namespace: namespace,
            children: [
                .element(
                    Element(
                        "service", namespace: namespace, attributes: ["host": host, "type": type]))
            ])
    }

    /// This service with the credentials of a `<credentials/>` result (the IQ or the element).
    /// The result names services by host and type, and port when several share those; what it
    /// leaves out, such as port and transport, stays as listed. Empty when the result has no
    /// service matching this one.
    public func credentials(from result: Element) -> [ExternalService] {
        let namespace = ExternalServices.namespace
        let credentials: Element
        if result.name == "credentials", result.namespace == namespace {
            credentials = result
        } else if let child = result.child("credentials", namespace: namespace) {
            credentials = child
        } else {
            return []
        }
        return credentials.children("service", namespace: namespace)
            .compactMap(ExternalService.init(element:))
            .filter { answer in
                answer.host.lowercased() == host.lowercased()
                    && answer.type.lowercased() == type.lowercased()
                    && (answer.port == nil || port == nil || answer.port == port)
            }
            .map { answer in
                var completed = self
                completed.port = answer.port ?? port
                completed.transport = answer.transport ?? transport
                completed.username = answer.username
                completed.password = answer.password
                completed.expires = answer.expires
                return completed
            }
    }
}

extension ExternalService: CustomStringConvertible, CustomDebugStringConvertible {
    /// Without the password, so the service can be logged.
    public var description: String {
        "ExternalService(\(type) \(host):\(port.map(String.init) ?? "-")"
            + "\(transport.map { " " + $0 } ?? "")\(password == nil ? "" : " with credentials"))"
    }

    public var debugDescription: String { description }
}

/// XEP-0215 External Service Discovery.
public enum ExternalServices {
    public static let namespace = "urn:xmpp:extdisco:2"

    /// The services `server` lists, of one `type` when given. Services that cannot be read are
    /// skipped.
    public static func fetch(server: JID, type: String? = nil, via sender: any StanzaSending)
        async throws(IQError) -> [ExternalService]
    {
        var payload = Element("services", namespace: namespace)
        payload[attribute: "type"] = type
        let result = try await sender.request(.iq(type: .get, to: server, payload: payload))
        let list = try result.resultPayload("services", namespace: namespace)
        return list.children("service", namespace: namespace).compactMap(
            ExternalService.init(element:))
    }

    /// `service` with the credentials `server` issues for it; nil when the answer has none for
    /// that service.
    public static func credentials(
        for service: ExternalService, server: JID, via sender: any StanzaSending
    ) async throws(IQError) -> ExternalService? {
        let result = try await sender.request(
            .iq(type: .get, to: server, payload: service.credentialsRequest))
        return service.credentials(from: result).first
    }
}
