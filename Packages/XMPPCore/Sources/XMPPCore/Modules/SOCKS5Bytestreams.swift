import CryptoKit
import Foundation

/// XEP-0065 SOCKS5 Bytestreams and the candidates of XEP-0260.
public enum SOCKS5Bytestreams {
    public static let namespace = "http://jabber.org/protocol/bytestreams"
    public static let jingleNamespace = "urn:xmpp:jingle:transports:s5b:1"

    public struct Candidate: Sendable, Hashable {
        public enum Kind: String, Sendable {
            case assisted, direct, proxy, tunnel
        }

        public var cid: String
        public var jid: JID
        public var host: String
        public var port: Int
        /// Higher is tried first.
        public var priority: Int
        public var type: Kind

        public init(
            cid: String, jid: JID, host: String, port: Int = 1080, priority: Int,
            type: Kind = .direct
        ) {
            self.cid = cid
            self.jid = jid
            self.host = host
            self.port = port
            self.priority = priority
            self.type = type
        }

        /// Reads a XEP-0260 `<candidate/>`; nil when a part is missing or the port is not 1...65535.
        public init?(element: Element) {
            guard element.name == "candidate", element.namespace == jingleNamespace,
                let cid = element[attribute: "cid"]?.nonEmpty,
                let jid = element[attribute: "jid"].flatMap({ try? JID($0) }),
                let host = element[attribute: "host"]?.nonEmpty,
                let priority = element[attribute: "priority"].flatMap({ Int($0) })
            else { return nil }
            var port = 1080
            if let text = element[attribute: "port"] {
                guard let value = Int(text), (1...65535).contains(value) else { return nil }
                port = value
            }
            var kind = Kind.direct
            if let text = element[attribute: "type"] {
                guard let value = Kind(rawValue: text) else { return nil }
                kind = value
            }
            self.init(cid: cid, jid: jid, host: host, port: port, priority: priority, type: kind)
        }

        public var element: Element {
            Element(
                "candidate", namespace: jingleNamespace,
                attributes: [
                    "cid": cid, "jid": jid.description, "host": host, "port": String(port),
                    "priority": String(priority), "type": type.rawValue,
                ])
        }

        /// The XEP-0065 `<streamhost/>` for this candidate.
        public var streamhost: Element {
            Element(
                "streamhost", namespace: SOCKS5Bytestreams.namespace,
                attributes: ["jid": jid.description, "host": host, "port": String(port)])
        }
    }

    /// The candidates of a XEP-0260 `<transport/>`, best first.
    public static func candidates(in transport: Element) -> [Candidate] {
        transport.children("candidate", namespace: jingleNamespace)
            .compactMap(Candidate.init(element:))
            .sorted { $0.priority > $1.priority }
    }

    /// The hex SHA-1 of `sid + candidateOwner + peer`, the SOCKS5 destination address (XEP-0065
    /// section 5.3.2, XEP-0260 section 2.2). `candidateOwner` is the party that offered the
    /// candidate being connected to: for the initiator's candidates it is the initiator and
    /// `peer` the responder, for the responder's candidates the two swap. `sid` is the
    /// `<transport/>` sid, not the Jingle session sid.
    public static func destinationAddress(sid: String, candidateOwner: JID, peer: JID) -> String {
        let input = Data((sid + candidateOwner.description + peer.description).utf8)
        return Insecure.SHA1.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    /// The XEP-0065 `<query/>` offering `streamhosts` to the target.
    public static func query(sid: String, streamhosts: [Candidate]) -> Element {
        Element(
            "query", namespace: namespace, attributes: ["sid": sid, "mode": "tcp"],
            children: streamhosts.map { .element($0.streamhost) })
    }

    /// The XEP-0260 `<transport/>`: the offer (candidates) or one of the transport-info answers.
    public struct Transport: Sendable, Equatable {
        public enum Mode: String, Sendable { case tcp, udp }

        /// What a transport-info carries instead of candidates.
        public enum Info: Sendable, Equatable {
            case candidateUsed(cid: String)
            case candidateError
            case activated(cid: String)
            case proxyError
        }

        public var sid: String
        public var mode: Mode
        public var dstaddr: String?
        public var candidates: [Candidate]
        public var info: Info?

        public init(
            sid: String, mode: Mode = .tcp, dstaddr: String? = nil, candidates: [Candidate] = [],
            info: Info? = nil
        ) {
            self.sid = sid
            self.mode = mode
            self.dstaddr = dstaddr
            self.candidates = candidates
            self.info = info
        }

        /// Nil without a sid or with an unknown mode. Candidates that cannot be read are
        /// skipped; the first transport-info child wins.
        public init?(element: Element) {
            guard element.name == "transport",
                element.namespace == SOCKS5Bytestreams.jingleNamespace,
                let sid = element[attribute: "sid"]?.nonEmpty
            else { return nil }
            var mode = Mode.tcp
            if let text = element[attribute: "mode"] {
                guard let value = Mode(rawValue: text) else { return nil }
                mode = value
            }
            let namespace = SOCKS5Bytestreams.jingleNamespace
            var info: Info?
            if let used = element.child("candidate-used", namespace: namespace),
                let cid = used[attribute: "cid"]?.nonEmpty
            {
                info = .candidateUsed(cid: cid)
            } else if element.child("candidate-error", namespace: namespace) != nil {
                info = .candidateError
            } else if let activated = element.child("activated", namespace: namespace),
                let cid = activated[attribute: "cid"]?.nonEmpty
            {
                info = .activated(cid: cid)
            } else if element.child("proxy-error", namespace: namespace) != nil {
                info = .proxyError
            }
            self.init(
                sid: sid, mode: mode, dstaddr: element[attribute: "dstaddr"]?.nonEmpty,
                candidates: element.children("candidate", namespace: namespace)
                    .compactMap(Candidate.init(element:)),
                info: info)
        }

        public var element: Element {
            let namespace = SOCKS5Bytestreams.jingleNamespace
            var transport = Element("transport", namespace: namespace, attributes: ["sid": sid])
            if info == nil {
                transport[attribute: "mode"] = mode.rawValue
                transport[attribute: "dstaddr"] = dstaddr
                for candidate in candidates { transport.append(candidate.element) }
            }
            switch info {
            case .candidateUsed(let cid):
                transport.append(
                    Element("candidate-used", namespace: namespace, attributes: ["cid": cid]))
            case .candidateError:
                transport.append(Element("candidate-error", namespace: namespace))
            case .activated(let cid):
                transport.append(
                    Element("activated", namespace: namespace, attributes: ["cid": cid]))
            case .proxyError:
                transport.append(Element("proxy-error", namespace: namespace))
            case nil: break
            }
            return transport
        }
    }

    // MARK: SOCKS5 bytes (RFC 1928)

    /// Version 5, one method, no authentication.
    public static let greeting: [UInt8] = [0x05, 0x01, 0x00]

    /// CONNECT to `destination` as a domain name, port 0.
    public static func connectRequest(destination: String) -> [UInt8] {
        let name = Array(destination.utf8)
        return [0x05, 0x01, 0x00, 0x03, UInt8(truncatingIfNeeded: name.count)] + name + [
            0x00, 0x00,
        ]
    }

    /// True for the server's answer to `greeting`: version 5, no authentication.
    public static func isGreetingAccepted(_ reply: [UInt8]) -> Bool { reply == [0x05, 0x00] }

    /// True when a CONNECT reply says success (version 5, status 0).
    public static func isConnectSuccess(_ reply: [UInt8]) -> Bool {
        reply.count >= 2 && reply[0] == 0x05 && reply[1] == 0x00
    }
}
