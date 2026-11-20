/// XEP-0045 Multi-User Chat: joining, configuring and administering rooms, invitations
/// (with XEP-0249 direct invitations), and XEP-0425 moderation. What a room says about an
/// occupant in presence is `MUCPresence`.
public enum MUC {
    public static let namespace = "http://jabber.org/protocol/muc"
    public static let adminNamespace = "http://jabber.org/protocol/muc#admin"
    public static let ownerNamespace = "http://jabber.org/protocol/muc#owner"
    /// XEP-0249 direct invitations.
    public static let directInvitationNamespace = "jabber:x:conference"
    /// XEP-0425; a room that advertises it lets moderators retract messages.
    public static let moderationNamespace = "urn:xmpp:message-moderate:1"
    /// XEP-0410: the room answers a self-ping itself, without asking the user's other clients.
    public static let selfPingOptimizationFeature =
        "http://jabber.org/protocol/muc#self-ping-optimization"
    static let roomInfoFormType = "http://jabber.org/protocol/muc#roominfo"
    static let retractNamespace = "urn:xmpp:message-retract:1"

    /// Why the room refused a join (the error in its presence of type `error`, XEP-0045 7.2).
    public enum JoinError: Sendable, Hashable {
        /// Someone else has the nick (`conflict`).
        case nickConflict
        /// The room is members-only and the user is not a member (`registration-required`).
        case membersOnly
        /// The user is banned (`forbidden`).
        case banned
        /// No password, or the wrong one (`not-authorized`).
        case passwordRequired
        /// The room does not exist, or is locked until its owner configures it
        /// (`item-not-found`).
        case notFound
        /// The room is full (`service-unavailable`).
        case full
        /// The room does not exist and the user may not create it (`not-allowed`).
        case creationNotAllowed
        /// The join named no nick (`jid-malformed`).
        case nickRequired
        case other(StanzaError.Condition)
    }

    /// What a room's disco#info says about it (XEP-0045 6.4, with the `muc#roominfo` form).
    public struct RoomInfo: Sendable, Hashable {
        public var name: String?
        public var description: String?
        public var subject: String?
        public var occupantCount: Int?
        /// The SHA-1 hashes of the room's vCard avatar (`muc#roominfo_avatarhash`, XEP-0486).
        public var avatarHashes: [String]
        public var features: Set<String>

        /// Nil unless `info` is a room's: it lists `http://jabber.org/protocol/muc`.
        public init?(info: DiscoInfo) {
            guard info.features.contains(MUC.namespace) else { return nil }
            features = info.features
            name =
                info.identities.first { $0.category == "conference" }?.name?.nonEmpty
            let form = info.forms.first { $0.formType == MUC.roomInfoFormType }
            description = form?.field("muc#roominfo_description")?.value?.nonEmpty
            subject = form?.field("muc#roominfo_subject")?.value?.nonEmpty
            occupantCount = form?.field("muc#roominfo_occupants")?.value.flatMap(RSM.count)
            avatarHashes =
                form?.field("muc#roominfo_avatarhash")?.values.compactMap(Avatars.sha1Hex) ?? []
        }

        public var isMembersOnly: Bool { features.contains("muc_membersonly") }
        public var isPasswordProtected: Bool { features.contains("muc_passwordprotected") }
        /// Every occupant may see every other occupant's real JID.
        public var isNonAnonymous: Bool { features.contains("muc_nonanonymous") }
        public var isPersistent: Bool { features.contains("muc_persistent") }
        public var isModerated: Bool { features.contains("muc_moderated") }
        public var isPublic: Bool { features.contains("muc_public") }
        /// XEP-0421: occupant ids in this room can be trusted.
        public var hasOccupantIDs: Bool { features.contains(MUCPresence.occupantIDNamespace) }
        /// The room keeps a XEP-0313 archive.
        public var hasArchive: Bool { features.contains(MAM.namespace) }
        /// The room stamps messages with XEP-0359 stanza ids that can be trusted.
        public var hasStanzaIDs: Bool { features.contains(ChatMessage.stanzaIDNamespace) }
        public var supportsModeration: Bool { features.contains(MUC.moderationNamespace) }
        public var supportsSelfPingOptimization: Bool {
            features.contains(MUC.selfPingOptimizationFeature)
        }
    }

    /// One entry of an affiliation list (XEP-0045 sections 9 and 10).
    public struct AffiliationItem: Sendable, Hashable {
        /// The user's bare JID.
        public var jid: JID
        public var affiliation: MUCPresence.Affiliation
        /// The nick reserved for a member.
        public var nick: String?
        public var reason: String?

        public init(
            jid: JID, affiliation: MUCPresence.Affiliation, nick: String? = nil,
            reason: String? = nil
        ) {
            self.jid = jid
            self.affiliation = affiliation
            self.nick = nick
            self.reason = reason
        }

        var element: Element {
            var item = Element(
                "item", namespace: MUC.adminNamespace,
                attributes: ["affiliation": affiliation.rawValue, "jid": jid.description])
            item[attribute: "nick"] = nick
            if let reason { item.append(MUC.text("reason", reason, namespace: MUC.adminNamespace)) }
            return item
        }
    }

    /// An invitation to a room.
    public struct Invitation: Sendable, Hashable {
        /// The room's bare JID.
        public var room: JID
        /// Who invited: the sender of a direct invitation, as the room says for a mediated one.
        public var inviter: JID?
        public var reason: String?
        public var password: String?
        /// XEP-0249 (sent by the inviter) rather than mediated by the room.
        public var isDirect: Bool
        /// The one-to-one thread the room continues (XEP-0249 `continue`).
        public var thread: String?

        public init(
            room: JID, inviter: JID?, reason: String? = nil, password: String? = nil,
            isDirect: Bool, thread: String? = nil
        ) {
            self.room = room
            self.inviter = inviter
            self.reason = reason
            self.password = password
            self.isDirect = isDirect
            self.thread = thread
        }
    }

    // MARK: Presence

    /// The presence that joins the room as `occupant` (`room@service/nick`), asking for
    /// `maxStanzas` messages of history (0 by default: history comes from the archive, spec
    /// 7.4; nil leaves it to the room). `children` are added as they are (caps, show, status).
    public static func joinPresence(
        occupant: JID, password: String? = nil, maxStanzas: Int? = 0, children: [Element] = []
    ) -> Element {
        var x = Element("x", namespace: namespace)
        if let maxStanzas {
            x.append(
                Element(
                    "history", namespace: namespace,
                    attributes: ["maxstanzas": String(max(0, maxStanzas))]))
        }
        if let password { x.append(text("password", password, namespace: namespace)) }
        return .presence(to: occupant, children: [x] + children)
    }

    /// Leaves the room `occupant` is in.
    public static func leavePresence(occupant: JID, status: String? = nil) -> Element {
        .presence(
            type: Presence.PresenceType.unavailable.rawValue, to: occupant,
            children: status.map { [Element("status", children: [.text($0)])] } ?? [])
    }

    /// Changes the user's nick in the room to the resource of `occupant` (XEP-0045 7.6).
    public static func nickChangePresence(occupant: JID, children: [Element] = []) -> Element {
        .presence(to: occupant, children: children)
    }

    /// The reason for a join error.
    public static func joinError(_ error: StanzaError) -> JoinError {
        switch error.condition {
        case .conflict: .nickConflict
        case .registrationRequired: .membersOnly
        case .forbidden: .banned
        case .notAuthorized: .passwordRequired
        case .itemNotFound: .notFound
        case .serviceUnavailable: .full
        case .notAllowed: .creationNotAllowed
        case .jidMalformed: .nickRequired
        default: .other(error.condition)
        }
    }

    /// `id` when the room advertises XEP-0421 occupant ids (`roomFeatures`), nil otherwise:
    /// for presences and messages alike.
    public static func trustedOccupantID(_ id: String?, roomFeatures: Set<String>) -> String? {
        roomFeatures.contains(MUCPresence.occupantIDNamespace) ? id : nil
    }

    // MARK: Owner

    /// The room's configuration form (XEP-0045 10.2).
    public static func config(room: JID, via sender: any StanzaSending) async throws(IQError)
        -> DataForm
    {
        let result = try await sender.request(
            .iq(type: .get, to: room.bare, payload: Element("query", namespace: ownerNamespace)))
        guard
            let form = try result.resultPayload("query", namespace: ownerNamespace)
                .child("x", namespace: DataForm.namespace).flatMap(DataForm.init(element:))
        else { throw .malformedResponse }
        return form
    }

    /// Submits the configuration: `form` filled in with `DataForm.submit(values:)`. A form
    /// that is not a submission (the fetched one, unchanged) is submitted with its defaults.
    public static func submitConfig(room: JID, _ form: DataForm, via sender: any StanzaSending)
        async throws(IQError)
    {
        let submission = form.type == .submit ? form : form.submit(values: [:])
        try await owner(room, submission.element, via: sender)
    }

    /// Cancels configuring a new room, which the service then destroys (XEP-0045 10.1.3).
    public static func cancelConfig(room: JID, via sender: any StanzaSending) async throws(IQError)
    {
        try await owner(room, DataForm(type: .cancel).element, via: sender)
    }

    /// Accepts the default configuration of a room the join just created (status 201).
    public static func createInstantRoom(room: JID, via sender: any StanzaSending)
        async throws(IQError)
    {
        try await owner(room, DataForm(type: .submit).element, via: sender)
    }

    /// Destroys the room, naming where it moved (XEP-0045 10.9).
    public static func destroy(
        room: JID, alternate: JID? = nil, reason: String? = nil, via sender: any StanzaSending
    ) async throws(IQError) {
        var destroy = Element("destroy", namespace: ownerNamespace)
        destroy[attribute: "jid"] = alternate?.bare.description
        if let reason { destroy.append(text("reason", reason, namespace: ownerNamespace)) }
        try await owner(room, destroy, via: sender)
    }

    // MARK: Admin

    /// Everyone with `affiliation` in the room. Entries without a valid JID or with an unknown
    /// affiliation are skipped.
    public static func affiliations(
        room: JID, affiliation: MUCPresence.Affiliation, via sender: any StanzaSending
    ) async throws(IQError) -> [AffiliationItem] {
        let query = Element(
            "query", namespace: adminNamespace,
            children: [
                .element(
                    Element(
                        "item", namespace: adminNamespace,
                        attributes: ["affiliation": affiliation.rawValue]))
            ])
        let result = try await sender.request(.iq(type: .get, to: room.bare, payload: query))
        return try result.resultPayload("query", namespace: adminNamespace)
            .children("item", namespace: adminNamespace).compactMap { item in
                guard let jid = item[attribute: "jid"].flatMap({ try? JID($0) }),
                    let affiliation = item[attribute: "affiliation"].flatMap(
                        MUCPresence.Affiliation.init(rawValue:))
                else { return nil }
                return AffiliationItem(
                    jid: jid, affiliation: affiliation, nick: item[attribute: "nick"]?.nonEmpty,
                    reason: item.child("reason", namespace: adminNamespace)?.trimmedText)
            }
    }

    /// Gives `jid` the `affiliation`: `.outcast` bans, `.none` takes it away.
    public static func setAffiliation(
        room: JID, jid: JID, affiliation: MUCPresence.Affiliation, reason: String? = nil,
        via sender: any StanzaSending
    ) async throws(IQError) {
        try await setAffiliations(
            room: room,
            [AffiliationItem(jid: jid.bare, affiliation: affiliation, reason: reason)],
            via: sender)
    }

    /// Changes several affiliations in one request (XEP-0045 9.2, 9.5, 10.5, 10.8).
    public static func setAffiliations(
        room: JID, _ items: [AffiliationItem], via sender: any StanzaSending
    ) async throws(IQError) {
        guard !items.isEmpty else { return }
        let query = Element(
            "query", namespace: adminNamespace, children: items.map { .element($0.element) })
        _ = try await sender.request(.iq(type: .set, to: room.bare, payload: query))
    }

    /// Gives the occupant `nick` the `role`: `.none` kicks, `.participant` grants voice,
    /// `.visitor` revokes it.
    public static func setRole(
        room: JID, nick: String, role: MUCPresence.Role, reason: String? = nil,
        via sender: any StanzaSending
    ) async throws(IQError) {
        var item = Element(
            "item", namespace: adminNamespace, attributes: ["nick": nick, "role": role.rawValue])
        if let reason { item.append(text("reason", reason, namespace: adminNamespace)) }
        let query = Element("query", namespace: adminNamespace, children: [.element(item)])
        _ = try await sender.request(.iq(type: .set, to: room.bare, payload: query))
    }

    // MARK: Messages

    /// A XEP-0249 direct invitation, sent to `invitee` itself.
    public static func invite(
        direct invitee: JID, to room: JID, password: String? = nil, reason: String? = nil
    ) -> Element {
        var x = Element(
            "x", namespace: directInvitationNamespace,
            attributes: ["jid": room.bare.description])
        x[attribute: "password"] = password
        x[attribute: "reason"] = reason
        return .message(type: nil, to: invitee, children: [x])
    }

    /// An invitation the room passes on to `invitee` (XEP-0045 7.8.2).
    public static func invite(mediated invitee: JID, to room: JID, reason: String? = nil)
        -> Element
    {
        var invite = Element(
            "invite", namespace: MUCPresence.userNamespace,
            attributes: ["to": invitee.description])
        if let reason {
            invite.append(text("reason", reason, namespace: MUCPresence.userNamespace))
        }
        return .message(
            type: nil, to: room.bare,
            children: [
                Element("x", namespace: MUCPresence.userNamespace, children: [.element(invite)])
            ])
    }

    /// Declines a mediated invitation from `inviter` to `room`.
    public static func decline(room: JID, inviter: JID, reason: String? = nil) -> Element {
        var decline = Element(
            "decline", namespace: MUCPresence.userNamespace,
            attributes: ["to": inviter.description])
        if let reason {
            decline.append(text("reason", reason, namespace: MUCPresence.userNamespace))
        }
        return .message(
            type: nil, to: room.bare,
            children: [
                Element("x", namespace: MUCPresence.userNamespace, children: [.element(decline)])
            ])
    }

    /// The invitation in `message`, direct or mediated. Nil when there is none, when the room
    /// is not a bare JID with a local part, and for a mediated invitation that does not come
    /// from the room's bare JID: only the room passes them on.
    public static func invitation(in message: Element) -> Invitation? {
        guard message.name == "message", let from = message.from else { return nil }
        if let x = message.child("x", namespace: directInvitationNamespace) {
            guard let room = x[attribute: "jid"].flatMap({ try? JID($0) }), isRoom(room) else {
                return nil
            }
            return Invitation(
                room: room, inviter: from, reason: x[attribute: "reason"]?.nonEmpty,
                password: x[attribute: "password"]?.nonEmpty, isDirect: true,
                thread: x[attribute: "thread"]?.nonEmpty)
        }
        guard isRoom(from),
            let x = message.child("x", namespace: MUCPresence.userNamespace),
            let invite = x.child("invite", namespace: MUCPresence.userNamespace)
        else { return nil }
        return Invitation(
            room: from, inviter: invite[attribute: "from"].flatMap { try? JID($0) },
            reason: invite.child("reason", namespace: MUCPresence.userNamespace)?.trimmedText,
            password: x.child("password", namespace: MUCPresence.userNamespace)?.text.nonEmpty,
            isDirect: false)
    }

    /// Sets the room's subject; an empty one clears it.
    public static func setSubject(room: JID, _ subject: String) -> Element {
        .message(
            type: "groupchat", to: room.bare,
            children: [Element("subject", children: subject.isEmpty ? [] : [.text(subject)])])
    }

    /// Retracts the message the room archived as `stanzaID`, for everyone (XEP-0425). Only a
    /// moderator may, in a room that advertises `moderationNamespace`.
    public static func moderate(
        room: JID, stanzaID: String, reason: String? = nil, via sender: any StanzaSending
    ) async throws(IQError) {
        var moderate = Element(
            "moderate", namespace: moderationNamespace, attributes: ["id": stanzaID],
            children: [.element(Element("retract", namespace: retractNamespace))])
        if let reason { moderate.append(text("reason", reason, namespace: moderationNamespace)) }
        _ = try await sender.request(.iq(type: .set, to: room.bare, payload: moderate))
    }

    /// The `muc#user` status codes of a message from the room, such as 104 (the configuration
    /// changed) or 170 (the room is now logged).
    public static func statusCodes(in message: Element) -> Set<Int> {
        guard let x = message.child("x", namespace: MUCPresence.userNamespace) else { return [] }
        return Set(
            x.children("status", namespace: MUCPresence.userNamespace).compactMap {
                $0[attribute: "code"].flatMap(RSM.count).flatMap {
                    (100...999).contains($0) ? $0 : nil
                }
            })
    }

    // MARK: Helpers

    private static func owner(_ room: JID, _ payload: Element, via sender: any StanzaSending)
        async throws(IQError)
    {
        let query = Element("query", namespace: ownerNamespace, children: [.element(payload)])
        _ = try await sender.request(.iq(type: .set, to: room.bare, payload: query))
    }

    /// A room's JID: bare, with a local part.
    private static func isRoom(_ jid: JID) -> Bool { jid.isBare && jid.localpart != nil }

    static func text(_ name: String, _ text: String, namespace: String) -> Element {
        Element(name, namespace: namespace, children: [.text(text)])
    }
}
