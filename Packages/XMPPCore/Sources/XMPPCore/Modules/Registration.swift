import Foundation

/// Data sent by XEP-0231 Bits of Binary, such as a CAPTCHA image.
public struct BitsOfBinary: Sendable, Equatable {
    public var contentID: String
    public var mediaType: String?
    public var data: Data
}

/// What a server asks for to register (XEP-0077).
public struct RegistrationForm: Sendable, Equatable {
    public var instructions: String?
    /// The legacy fields, in the order given, with their current values (empty when new).
    public var fields: [(name: String, value: String)]
    /// The data form that replaces the legacy fields, when the server sends one.
    public var form: DataForm?
    /// The account is registered already (`<registered/>`).
    public var registered: Bool
    /// Images that form fields point to with `cid:` addresses (XEP-0158 CAPTCHA over XEP-0221).
    public var media: [BitsOfBinary]

    public static func == (a: RegistrationForm, b: RegistrationForm) -> Bool {
        a.instructions == b.instructions && a.form == b.form && a.registered == b.registered
            && a.media == b.media && a.fields.map(\.name) == b.fields.map(\.name)
            && a.fields.map(\.value) == b.fields.map(\.value)
    }

    /// The media for a `cid:` address of a form field.
    public func media(for uri: String) -> BitsOfBinary? {
        guard uri.lowercased().hasPrefix("cid:") else { return nil }
        let id = String(uri.dropFirst(4))
        return media.first { $0.contentID == id }
    }
}

/// XEP-0077 In-Band Registration, with XEP-0445 pre-authentication.
public enum Registration {
    public static let namespace = "jabber:iq:register"
    public static let preauthNamespace = "urn:xmpp:pars:0"
    public static let bobNamespace = "urn:xmpp:bob"
    static let metaElements: Set<String> = ["instructions", "registered", "x", "data", "remove"]

    /// Sends a XEP-0445 invite token (from a XEP-0401 invite) to `server`, before `fetch`.
    /// An unknown or used token comes back as `item-not-found`.
    public static func preauth(token: String, server: JID, via sender: any StanzaSending)
        async throws(IQError)
    {
        _ = try await sender.request(
            .iq(
                type: .set, to: server,
                payload: Element(
                    "preauth", namespace: preauthNamespace, attributes: ["token": token])))
    }

    /// The fields `server` asks for.
    public static func fetch(server: JID, via sender: any StanzaSending) async throws(IQError)
        -> RegistrationForm
    {
        let result = try await sender.request(
            .iq(type: .get, to: server, payload: Element("query", namespace: namespace)))
        return form(from: try result.resultPayload("query", namespace: namespace), in: result)
    }

    /// Reads a registration `<query/>`; `iq` supplies a Bits of Binary `<data/>` sent beside it.
    public static func form(from query: Element, in iq: Element? = nil) -> RegistrationForm {
        let legacy = query.elements.filter {
            $0.namespace == namespace && !metaElements.contains($0.name)
        }.map { (name: $0.name, value: $0.text) }
        let data =
            query.children("data", namespace: bobNamespace)
            + (iq?.children("data", namespace: bobNamespace) ?? [])
        let media = data.compactMap { item -> BitsOfBinary? in
            guard let cid = item[attribute: "cid"]?.nonEmpty,
                let bytes = Data(
                    base64Encoded: item.text.filter { !$0.isWhitespace })
            else { return nil }
            return BitsOfBinary(contentID: cid, mediaType: item[attribute: "type"], data: bytes)
        }
        return RegistrationForm(
            instructions: query.child("instructions", namespace: namespace)?.text,
            fields: legacy,
            form: query.child("x", namespace: DataForm.namespace).flatMap(DataForm.init(element:)),
            registered: query.child("registered", namespace: namespace) != nil, media: media)
    }

    /// Submits the legacy fields.
    public static func submit(
        server: JID, fields: [(name: String, value: String)], via sender: any StanzaSending
    ) async throws(IQError) {
        var query = Element("query", namespace: namespace)
        for field in fields {
            query.append(Element(field.name, namespace: namespace, children: [.text(field.value)]))
        }
        _ = try await sender.request(.iq(type: .set, to: server, payload: query))
    }

    /// Submits a filled in data form (`DataForm.submit(values:)` of the fetched one).
    public static func submit(server: JID, form: DataForm, via sender: any StanzaSending)
        async throws(IQError)
    {
        var query = Element("query", namespace: namespace)
        query.append(form.element)
        _ = try await sender.request(.iq(type: .set, to: server, payload: query))
    }

    /// Sets a new password for the account the session is signed in as (XEP-0077 section 3.3),
    /// sent to the account's own server. Only send it over a verified, encrypted stream.
    public static func changePassword(_ password: String, via sender: any StanzaSending)
        async throws(IQError)
    {
        guard let username = await sender.boundJID?.localpart else { throw .notConnected }
        var query = Element("query", namespace: namespace)
        query.append(Element("username", namespace: namespace, children: [.text(username)]))
        query.append(Element("password", namespace: namespace, children: [.text(password)]))
        _ = try await sender.request(.iq(type: .set, payload: query))
    }

    /// Deletes the account from its server.
    public static func cancel(via sender: any StanzaSending) async throws(IQError) {
        var query = Element("query", namespace: namespace)
        query.append(Element("remove", namespace: namespace))
        _ = try await sender.request(.iq(type: .set, payload: query))
    }
}
