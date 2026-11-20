import Foundation

/// PLAIN (RFC 4616): the username and password in the clear, with no authorization identity.
/// Only for TLS connections; `SASLSelector` never picks it without TLS. It cannot authenticate
/// the server, so `verifySuccess` only checks that the initial response went out.
public struct Plain: SASLMechanism {
    public let name = "PLAIN"
    private let username: String
    private let password: String
    private var step = Step.start

    private enum Step: Sendable {
        case start, sent, failed
    }

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// message = [authzid] UTF8NUL authcid UTF8NUL passwd, both prepared with SASLprep as query
    /// strings (RFC 4616 sets no client rule), which also rules out NUL inside them.
    public mutating func initialResponse() throws(SASLError) -> Data? {
        guard case .start = step else {
            step = .failed
            throw .malformedChallenge
        }
        step = .failed
        let preparedUsername = try SASLPrep.prepare(username, as: .username, mode: .query)
        let preparedPassword = try SASLPrep.prepare(password, as: .password, mode: .query)
        var message = Data([0])
        message.append(Data(preparedUsername.utf8))
        message.append(0)
        message.append(Data(preparedPassword.utf8))
        step = .sent
        return message
    }

    /// PLAIN has no challenges: the initial response carries everything.
    public mutating func respond(to challenge: Data) throws(SASLError) -> Data {
        step = .failed
        throw .malformedChallenge
    }

    /// Success is only valid after the initial response was sent. Additional data, which PLAIN
    /// does not define, is ignored.
    public mutating func verifySuccess(_ additionalData: Data?) throws(SASLError) {
        guard case .sent = step else {
            step = .failed
            throw .malformedChallenge
        }
    }
}

extension Plain: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Only the name: the stored values include the password.
    public var description: String { name }
    public var debugDescription: String { "Plain(\(name))" }
    public var customMirror: Mirror { Mirror(self, children: ["name": name]) }
}
