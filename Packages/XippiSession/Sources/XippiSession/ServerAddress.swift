import Foundation
import XMPPCore

/// A server typed in by hand for an account or a registration: `host`, `host:port`,
/// `[IPv6]` or `[IPv6]:port`. Port 5222 is STARTTLS, any other port direct TLS (5223 when none
/// is given), as servers lay them out.
public struct ServerAddress: Sendable, Equatable {
    public var host: String
    public var port: Int?

    public init(host: String, port: Int?) {
        self.host = host
        self.port = port
    }

    /// nil for an empty text: look the domain up. Throws for a text that is not one host with
    /// at most one port from 1 to 65535; a bare IPv6 address needs its brackets.
    public static func parse(_ text: String) throws(ServerAddressError) -> ServerAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var host: Substring
        var portText: Substring?
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { throw ServerAddressError() }
            host = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { throw ServerAddressError() }
                portText = rest.dropFirst()
            }
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." })
            else { throw ServerAddressError() }
        } else {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw ServerAddressError() }
            host = parts[0]
            portText = parts.count == 2 ? parts[1] : nil
            guard !host.isEmpty,
                !host.contains(where: { $0.isWhitespace || "/@[]".contains($0) })
            else { throw ServerAddressError() }
        }
        var port: Int?
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy(\.isASCIIDigit),
                let number = Int(portText), (1...65535).contains(number)
            else { throw ServerAddressError() }
            port = number
        }
        return ServerAddress(host: String(host), port: port)
    }

    public var directTLS: Bool { port != 5222 }

    public var endpoint: ServerEndpoint {
        ServerEndpoint(host: host, port: port ?? (directTLS ? 5223 : 5222), directTLS: directTLS)
    }
}

/// The server typed in is not a host with an optional port.
public struct ServerAddressError: Error, Equatable {
    public init() {}
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
