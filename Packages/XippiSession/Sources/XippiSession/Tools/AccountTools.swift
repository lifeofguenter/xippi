import Foundation
import XMPPCore
import XippiStore

/// What the power tools (XML console, service discovery, ad-hoc commands) and the channel
/// sheets ask of an account, beside the session's own commands.
extension AccountSession {
    /// How long a channel service lookup waits for each item's disco#info.
    static let serviceLookupTimeout: Duration = .seconds(10)
    /// Items of the server looked at for channel services.
    static let maxServiceItems = 50

    /// What service discovery, ad-hoc commands and the channel sheets ask the account's
    /// server: IQ requests only. Its `send` refuses; the XML console sends through
    /// `sendConsoleStanza(_:)`.
    public nonisolated var toolRequests: any StanzaSending {
        ToolRequests(connection: connection)
    }

    /// Sends what the XML console's send box holds, as the user, past the session's own
    /// bookkeeping (nothing is stored, no outbox waits for it). Only one `message`,
    /// `presence` or `iq` of the client namespace goes out (`StreamTapInput`), checked here
    /// whatever the caller checked: anything else would put the connection's state (Stream
    /// Management, client state) out of step with the server.
    public func sendConsoleStanza(_ text: String) async throws(ConsoleSendError) {
        let stanza: Element
        do {
            stanza = try StreamTapInput.stanza(from: text)
        } catch {
            throw .invalid(error)
        }
        do {
            try await connection.send(stanza)
        } catch {
            throw .notConnected
        }
    }

    /// The MIX services of the account's server (XEP-0369 6.1): the server's disco#items that
    /// list the MIX core feature. An item that does not answer within 10 s is left out.
    public func channelServices() async throws(SessionError) -> [JID] {
        let items: [DiscoItem]
        do {
            items = try await Disco.items(domain, via: connection)
        } catch {
            throw SessionError(error)
        }
        var seen = Set<JID>()
        let candidates = items.filter {
            $0.node == nil && $0.jid.localpart == nil && seen.insert($0.jid).inserted
        }
        .map(\.jid).prefix(Self.maxServiceItems)
        let sender = connection
        let found = await withTaskGroup(of: (Int, JID?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let query = Element.iq(
                        type: .get, to: candidate,
                        payload: Element("query", namespace: Disco.infoNamespace))
                    guard
                        let answer = try? await sender.request(
                            query, timeout: Self.serviceLookupTimeout),
                        let info = answer.child("query", namespace: Disco.infoNamespace)
                            .flatMap(DiscoInfo.init(element:)),
                        info.features.contains(MIX.coreNamespace)
                    else { return (index, nil) }
                    return (index, candidate)
                }
            }
            var found: [(Int, JID)] = []
            for await case (let index, let service?) in group {
                found.append((index, service))
            }
            return found
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Creates a channel on `service` (named `name`, or named by the service when empty) and
    /// joins it as `nick`. Returns the channel's chat id. The service's refusal comes back as
    /// `.refused`, and then nothing is stored.
    @discardableResult
    public func createChannel(on service: JID, name: String?, nick: String)
        async throws(SessionError) -> Int64
    {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty, service.localpart == nil, service.resourcepart == nil else {
            throw .invalidInput
        }
        let channel: JID
        do {
            channel = try await MIX.create(
                service: service, channel: name?.isEmpty == false ? name : nil, via: connection)
        } catch {
            throw SessionError(error)
        }
        return try await joinChannel(jid: channel, nick: nick)
    }

    /// Who is in the channel, from its participants node, with the nicks the channel shows;
    /// never a participant id. The account itself comes first.
    public func channelMembers(chatID: Int64) async throws(SessionError) -> [ChannelMember] {
        let chat = try chat(chatID)
        guard chat.kind == .channel, let channel = try? JID(chat.jid) else { throw .notAllowed }
        // In a channel that hides addresses the account is found by the id it joined with.
        let ownID = await rooms?.ownOccupant(in: chatID)?.jid.resourcepart
        let participants: [MIXParticipant]
        do {
            participants = try await MIX.participants(channel: channel.bare, via: connection)
        } catch {
            throw SessionError(error)
        }
        return MIXManager.members(from: participants, ownJID: jid, ownID: ownID)
    }
}

/// Why the XML console's text was not sent.
public enum ConsoleSendError: Error, Equatable, Sendable {
    /// Not one stanza the console may send.
    case invalid(StreamTapInput.Problem)
    case notConnected
}

/// The account's connection for requests only: what the power tools need.
struct ToolRequests: StanzaSending {
    let connection: XMPPConnection

    /// Not for the tools: a stanza the user writes goes through `sendConsoleStanza(_:)`.
    func send(_ stanza: Element) async throws(SendError) {
        throw .notConnected
    }

    func request(_ iq: Element, timeout: Duration) async throws(IQError) -> Element {
        try await connection.request(iq, timeout: timeout)
    }

    var boundJID: JID? {
        get async { await connection.boundJID }
    }
}
