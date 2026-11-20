import Foundation

/// Who may read a node the account publishes in its PEP service (XEP-0060 4.5, XEP-0163):
/// its contacts (`presence`, those subscribed to its presence) or anyone (`open`).
public enum PEPAccess: String, Sendable, CaseIterable {
    case presence
    case open
}

extension PubSub {
    /// Publishes `item` to `node` so that `access` decides who reads it (ruling R64).
    ///
    /// - With publish-options on the account's server (`accountFeatures` from
    ///   `accountFeatures(via:)`), the access model goes as a publish-option, and a node that
    ///   exists with another configuration is configured first.
    /// - Without, the node gets its audience first (an existing node is configured, a missing
    ///   one created with its configuration, XEP-0060 8.1.3), and only then is the item
    ///   published: nothing goes out under another audience. When that fails, the error is
    ///   thrown and nothing is published.
    ///
    /// `persistent` adds the configuration of XEP-0222 (kept, pushed only on change).
    static func publish(
        node: String, item: PubSubItem, access: PEPAccess, persistent: Bool,
        accountFeatures: Set<String>, via sender: any StanzaSending
    ) async throws(PubSubError) {
        let options = accessOptions(access, persistent: persistent)
        if accountFeatures.contains(publishOptionsFeature) {
            try await publishConfiguring(node: node, item: item, options: options, via: sender)
        } else {
            do {
                try await configure(node: node, options: options, via: sender)
            } catch .request(.error(let error)) where error.condition == .itemNotFound {
                try await create(node: node, options: options, via: sender)
            }
            try await publish(node: node, item: item, via: sender)
        }
    }

    /// Sets the access model of the account's existing `node`; a node that does not exist
    /// yet is left alone (it gets the model with its first publish).
    public static func setAccess(
        _ access: PEPAccess, node: String, persistent: Bool, via sender: any StanzaSending
    ) async throws(PubSubError) {
        do {
            try await configure(
                node: node, options: accessOptions(access, persistent: persistent), via: sender)
        } catch .request(.error(let error)) where error.condition == .itemNotFound {
            return
        }
    }

    /// Creates the account's `node` with `options` as its configuration (XEP-0060 8.1.3).
    static func create(
        node: String, options: KeyValuePairs<String, [String]>, via sender: any StanzaSending
    ) async throws(PubSubError) {
        let form = DataForm.submission(formType: nodeConfigFormType, options)
        let request = Element.iq(
            type: .set,
            payload: Element(
                "pubsub", namespace: namespace,
                children: [
                    .element(Element("create", namespace: namespace, attributes: ["node": node])),
                    .element(
                        Element(
                            "configure", namespace: namespace, children: [.element(form.element)])),
                ]))
        do {
            _ = try await sender.request(request)
        } catch {
            throw PubSubError(error)
        }
    }

    /// The access model of the account's `node`, from its configuration (XEP-0060 8.2): `open`,
    /// or `presence` for any narrower model (`presence`, `roster`, `authorize`, `whitelist`);
    /// nil when the node does not exist. A configuration that does not say is an error.
    public static func access(of node: String, via sender: any StanzaSending)
        async throws(PubSubError) -> PEPAccess?
    {
        let configure = Element(
            "configure", namespace: ownerNamespace, attributes: ["node": node])
        let result: Element
        do {
            result = try await sender.request(
                .iq(
                    type: .get,
                    payload: Element(
                        "pubsub", namespace: ownerNamespace, children: [.element(configure)])))
        } catch .error(let error) where error.condition == .itemNotFound {
            return nil
        } catch {
            throw PubSubError(error)
        }
        guard
            let x = result.child("pubsub", namespace: ownerNamespace)?
                .child("configure", namespace: ownerNamespace)?
                .child("x", namespace: DataForm.namespace),
            let form = DataForm(element: x),
            let value = form.fields.first(where: { $0.variable == "pubsub#access_model" })?
                .values.first, !value.isEmpty
        else { throw .request(.malformedResponse) }
        return value == PEPAccess.open.rawValue ? .open : .presence
    }

    /// The node configuration for `access` (publish-options and node configuration take the
    /// same fields). `KeyValuePairs` is built from literals only, hence the four.
    static func accessOptions(_ access: PEPAccess, persistent: Bool)
        -> KeyValuePairs<String, [String]>
    {
        switch (access, persistent) {
        case (.presence, false):
            ["pubsub#access_model": ["presence"]]
        case (.open, false):
            ["pubsub#access_model": ["open"]]
        case (.presence, true):
            [
                "pubsub#persist_items": ["true"],
                "pubsub#send_last_published_item": ["never"],
                "pubsub#access_model": ["presence"],
            ]
        case (.open, true):
            [
                "pubsub#persist_items": ["true"],
                "pubsub#send_last_published_item": ["never"],
                "pubsub#access_model": ["open"],
            ]
        }
    }
}

extension VCard4 {
    /// Publishes `profile` as the account's vCard (see `publish(_:via:)`), readable by those
    /// `access` names.
    public static func publish(
        _ profile: Profile, access: PEPAccess, accountFeatures: Set<String>,
        via sender: any StanzaSending
    ) async throws(PubSubError) {
        guard profile.photoFits(readingSourceWith: self.profile(from:)) else {
            throw .request(.error(StanzaError(type: .modify, condition: .notAcceptable)))
        }
        try await PubSub.publish(
            node: node, item: PubSubItem(id: "current", payload: vcard(profile)), access: access,
            persistent: true, accountFeatures: accountFeatures, via: sender)
    }
}

extension Avatars {
    /// Publishes a prepared avatar (see `publish(_:via:)`) with both its nodes readable by
    /// those `access` names. Returns the published metadata.
    @discardableResult
    public static func publish(
        _ avatar: Prepared, access: PEPAccess, accountFeatures: Set<String>,
        via sender: any StanzaSending
    ) async throws(AvatarError) -> Info {
        guard avatar.data.count <= maxPublishBytes else { throw .tooLarge }
        let info = Info(
            id: avatar.sha1, bytes: avatar.data.count, type: avatar.type, width: avatar.width,
            height: avatar.height)
        do {
            try await PubSub.publish(
                node: dataNode,
                item: PubSubItem(
                    id: avatar.sha1,
                    payload: Element(
                        "data", namespace: dataNode,
                        children: [.text(avatar.data.base64EncodedString())])),
                access: access, persistent: false, accountFeatures: accountFeatures, via: sender)
            try await PubSub.publish(
                node: metadataNode,
                item: PubSubItem(id: avatar.sha1, payload: Metadata(infos: [info]).element),
                access: access, persistent: false, accountFeatures: accountFeatures, via: sender)
        } catch {
            throw .pubsub(error)
        }
        return info
    }

    /// The avatar's two nodes, data first.
    public static let nodes = [dataNode, metadataNode]
}
