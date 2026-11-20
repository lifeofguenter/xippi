/// A host and port to connect to, and whether TLS starts before the first byte (XEP-0368) or
/// after STARTTLS.
public struct ServerEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var directTLS: Bool

    public init(host: String, port: Int, directTLS: Bool) {
        self.host = host
        self.port = port
        self.directTLS = directTLS
    }
}
