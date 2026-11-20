import Foundation
import XMPPCore

/// Toxiproxy's HTTP API (compose.yaml: localhost:8474), and the proxies integration tests make
/// on it.
///
/// Every test that needs a network fault makes a proxy of its own, on a port of `ports` (which
/// compose.yaml publishes), and deletes it when it ends: tests running at the same time, here or
/// in another process, never share a proxy or its toxics.
public enum Toxiproxy {
    public static let api = "http://127.0.0.1:8474"
    /// The ports compose.yaml publishes for proxies tests make for themselves.
    public static let ports = 26000...26099

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// A new proxy in front of `server`'s direct TLS or STARTTLS port.
    public static func proxy(to server: TestServer, directTLS: Bool = true) async throws
        -> TestProxy
    {
        try await proxy(to: server.upstream(directTLS: directTLS), directTLS: directTLS)
    }

    /// A new proxy from a free port of `ports` to `upstream`, a compose service and its port
    /// (`prosody:5223`). `directTLS` says what the upstream port speaks.
    public static func proxy(to upstream: String, directTLS: Bool) async throws -> TestProxy {
        var lastAnswer = ""
        for _ in 0..<20 {
            let port = Int.random(in: ports)
            let name = "test-" + UUID().uuidString.lowercased().prefix(13)
            let (status, body) = try await call(
                "POST", "proxies",
                body: ProxyRequest(
                    name: String(name), listen: "0.0.0.0:\(port)", upstream: upstream,
                    enabled: true))
            if status == 201 {
                return TestProxy(
                    name: String(name),
                    endpoint: ServerEndpoint(host: "localhost", port: port, directTLS: directTLS))
            }
            // Most likely the port is another test's: try another.
            lastAnswer = "HTTP \(status): \(body)"
        }
        throw Failure(description: "No proxy to \(upstream): \(lastAnswer)")
    }

    struct ProxyRequest: Encodable {
        var name: String
        var listen: String
        var upstream: String
        var enabled: Bool
    }

    struct ToxicRequest: Encodable {
        var name: String
        var type: String
        var stream: String
        var toxicity: Double = 1
        var attributes: [String: Int]
    }

    static func call(_ method: String, _ path: String, body: some Encodable) async throws -> (
        status: Int, body: String
    ) {
        try await send(method, path, data: try JSONEncoder().encode(body))
    }

    static func call(_ method: String, _ path: String) async throws -> (status: Int, body: String) {
        try await send(method, path, data: nil)
    }

    private static func send(_ method: String, _ path: String, data: Data?) async throws -> (
        status: Int, body: String
    ) {
        guard let url = URL(string: "\(api)/\(path)") else {
            throw Failure(description: "Bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let data {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, String(decoding: data, as: UTF8.self))
    }
}

/// One test's proxy in front of a server, and the faults it can put on the connections through
/// it. Faults apply to the connections open now and to every new one, until removed.
public struct TestProxy: Sendable {
    public let name: String
    /// Where the client connects instead of the server.
    public let endpoint: ServerEndpoint

    /// Toxic names, each one per direction.
    private static let blackholeName = "blackhole"
    private static let holdName = "hold"
    private static let cutName = "cut"
    private static let resetName = "reset"

    /// Nothing passes in either direction and nothing is closed: the connection looks alive,
    /// and what is sent meanwhile is lost (toxiproxy `timeout` without a timeout).
    public func blackhole() async throws {
        try await addBothWays(Self.blackholeName, type: "timeout", attributes: ["timeout": 0])
    }

    public func liftBlackhole() async throws {
        try await removeBothWays(Self.blackholeName)
    }

    /// Nothing passes in either direction, and nothing is closed, but nothing is lost either:
    /// every byte waits until `release()`, as packets do while a network is down and TCP sends
    /// them again (toxiproxy `latency` of ten minutes).
    public func hold() async throws {
        try await addBothWays(Self.holdName, type: "latency", attributes: ["latency": 600_000])
    }

    /// Lets everything `hold()` kept go through, in order.
    public func release() async throws {
        try await removeBothWays(Self.holdName)
    }

    /// The network is gone: nothing passes, and every connection is closed `after` (toxiproxy
    /// `timeout`), so the server sees the client go.
    public func cut(closingAfter after: Duration) async throws {
        let milliseconds = Int(after.components.seconds * 1_000)
        try await addBothWays(Self.cutName, type: "timeout", attributes: ["timeout": milliseconds])
    }

    public func restore() async throws {
        try await removeBothWays(Self.cutName)
    }

    /// The next bytes the server sends on each connection reset it (RST): toxiproxy
    /// `reset_peer`, which resets a connection when data comes through it.
    public func resetOnServerData() async throws {
        try await add(
            Toxiproxy.ToxicRequest(
                name: Self.resetName, type: "reset_peer", stream: "downstream",
                attributes: ["timeout": 0]))
    }

    public func stopResetting() async throws {
        try await remove(Self.resetName)
    }

    /// Removes the proxy, closing every connection through it.
    public func delete() async throws {
        let (status, body) = try await Toxiproxy.call("DELETE", "proxies/\(name)")
        guard status == 204 || status == 404 else {
            throw Toxiproxy.Failure(description: "Deleting \(name): HTTP \(status) \(body)")
        }
    }

    private func addBothWays(_ name: String, type: String, attributes: [String: Int])
        async throws
    {
        for stream in ["upstream", "downstream"] {
            try await add(
                Toxiproxy.ToxicRequest(
                    name: "\(name)-\(stream)", type: type, stream: stream,
                    attributes: attributes))
        }
    }

    private func removeBothWays(_ name: String) async throws {
        for stream in ["upstream", "downstream"] {
            try await remove("\(name)-\(stream)")
        }
    }

    private func add(_ toxic: Toxiproxy.ToxicRequest) async throws {
        let (status, body) = try await Toxiproxy.call(
            "POST", "proxies/\(name)/toxics", body: toxic)
        guard status == 200 else {
            throw Toxiproxy.Failure(description: "Adding \(toxic.name): HTTP \(status) \(body)")
        }
    }

    private func remove(_ toxic: String) async throws {
        let (status, body) = try await Toxiproxy.call(
            "DELETE", "proxies/\(name)/toxics/\(toxic)")
        guard status == 204 || status == 404 else {
            throw Toxiproxy.Failure(description: "Removing \(toxic): HTTP \(status) \(body)")
        }
    }
}
