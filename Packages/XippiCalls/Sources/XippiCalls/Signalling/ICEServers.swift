import Foundation
import XMPPCore

/// One STUN or TURN server for the WebRTC engine (`RTCIceServer`).
public struct ICEServerConfig: Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

extension ICEServerConfig: CustomStringConvertible, CustomDebugStringConvertible {
    /// Without the credential, so the configuration can be logged.
    public var description: String {
        "ICEServerConfig(\(urls.joined(separator: " "))\(credential == nil ? "" : " with credentials"))"
    }

    public var debugDescription: String { description }
}

/// The ICE servers among some XEP-0215 services, and the restricted ones that first need
/// credentials.
public struct ICEServerResolution: Sendable, Equatable {
    public var servers: [ICEServerConfig]
    /// Restricted TURN services without credentials, or with expired ones: ask the server with
    /// `credentialsRequest`, then resolve what `credentials(from:)` returns.
    public var needsCredentials: [ExternalService]

    public init(servers: [ICEServerConfig] = [], needsCredentials: [ExternalService] = []) {
        self.servers = servers
        self.needsCredentials = needsCredentials
    }
}

/// Turns XEP-0215 services into ICE servers.
public enum ICEServers {
    /// The STUN and TURN servers among `services`; `resolve(_:now:).servers`.
    public static func from(_ services: [ExternalService], now: Date = Date()) -> [ICEServerConfig]
    {
        resolve(services, now: now).servers
    }

    /// The STUN and TURN servers among `services`, as RFC 7064 and RFC 7065 URIs, and the
    /// restricted TURN services still waiting for credentials. Left out: other service types,
    /// `stuns` (libwebrtc reads it as plain STUN over UDP, so it would only probe the TLS port),
    /// TURN without a username and password (libwebrtc refuses the whole configuration over
    /// one), credentials that expired before `now`, STUN over TCP, and hosts or ports that do
    /// not form a URI.
    public static func resolve(_ services: [ExternalService], now: Date = Date())
        -> ICEServerResolution
    {
        var resolution = ICEServerResolution()
        for service in services {
            if let config = config(for: service, now: now) {
                resolution.servers.append(config)
            } else if service.restricted, service.type.lowercased().hasPrefix("turn"),
                url(for: service) != nil
            {
                resolution.needsCredentials.append(service)
            }
        }
        return resolution
    }

    static func config(for service: ExternalService, now: Date) -> ICEServerConfig? {
        guard let url = url(for: service) else { return nil }
        if let expires = service.expires, expires <= now { return nil }
        // libwebrtc does not authenticate to STUN servers.
        if service.type.lowercased() == "stun" { return ICEServerConfig(urls: [url]) }
        guard let username = service.username, !username.isEmpty,
            let password = service.password, !password.isEmpty
        else { return nil }
        return ICEServerConfig(urls: [url], username: username, credential: password)
    }

    /// The URI for a STUN or TURN service, or nil when it is another type or does not form one.
    static func url(for service: ExternalService) -> String? {
        let scheme = service.type.lowercased()
        let defaultPort: Int
        switch scheme {
        case "stun", "turn": defaultPort = 3478
        case "turns": defaultPort = 5349
        default: return nil
        }
        guard let host = uriHost(service.host) else { return nil }
        let port = service.port ?? defaultPort
        guard (1...65535).contains(port) else { return nil }
        let transport = service.transport?.lowercased()
        if let transport, transport != "udp", transport != "tcp" { return nil }
        let url = "\(scheme):\(host):\(port)"
        if scheme == "stun" {
            // RFC 7064 has no transport parameter, and plain STUN is UDP only.
            return transport == "tcp" ? nil : url
        }
        return transport.map { url + "?transport=" + $0 } ?? url
    }

    /// The host as it goes into a URI: a name or IPv4 address as is, an IPv6 address in
    /// brackets. Nil for anything else, so a host cannot add a path or query.
    static func uriHost(_ host: String) -> String? {
        let hex = Set("0123456789abcdefABCDEF:.")
        var address = Substring(host)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = address.dropFirst().dropLast()
            guard !address.isEmpty, address.allSatisfy(hex.contains) else { return nil }
            return "[\(address)]"
        }
        if address.contains(":") {
            guard address.allSatisfy(hex.contains) else { return nil }
            return "[\(address)]"
        }
        let name = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !address.isEmpty, address.allSatisfy(name.contains) else { return nil }
        return String(address)
    }
}
