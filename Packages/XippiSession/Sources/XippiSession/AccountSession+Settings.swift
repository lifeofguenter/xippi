import Foundation
import XMPPCore
import XippiStore
import os

/// What the account settings change on the server: the presence priority, the archiving
/// preferences (XEP-0441) and the account's own profile (XEP-0292, XEP-0054).
extension AccountSession {
    /// The presence priority: sent at once when online, and with every later presence.
    func setPriority(_ priority: Int) async {
        guard priority != self.priority else { return }
        self.priority = priority
        await sendPresence()
    }

    /// Whether the account's server keeps a blocklist (XEP-0191); false while offline.
    public var supportsBlocking: Bool {
        live && serverFeatures.contains(Blocking.namespace)
    }

    // MARK: Archive

    /// The account's archiving preferences. `.unavailable` when its server keeps no archive.
    public func archivePreferences() async throws(SessionError) -> MAMPreferences {
        try requireArchive()
        do {
            return try await MAM.preferences(via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// Sets the account's archiving preferences; returns them as the server now has them.
    @discardableResult
    public func setArchivePreferences(_ preferences: MAMPreferences) async throws(SessionError)
        -> MAMPreferences
    {
        try requireArchive()
        do {
            return try await MAM.setPreferences(preferences, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    private func requireArchive() throws(SessionError) {
        guard live else { throw .notConnected }
        guard accountFeatures.contains(MAM.namespace) else { throw .unavailable }
    }

    // MARK: Own profile

    /// The fields of the account's own profile as its server has it (vCard4, else
    /// vcard-temp), kept in the own profile row for when the account is offline. Nil when the
    /// account has published none.
    public func ownProfileFields() async throws(SessionError) -> ProfileFields? {
        guard let profile = try await fetchProfile() else { return nil }
        let fields = ProfileFields(profile)
        keepOwnProfile(fields)
        return fields
    }

    /// Publishes the edited fields into the account's vCard4 (XEP-0292), keeping everything
    /// else it holds, readable by those `visibility` names (R64). For everyone, and only on a
    /// server whose vcard-temp is its own store (no XEP-0398), into the vcard-temp too.
    /// `.invalidInput` when the fields have `problems`: nothing is sent. Fails when the node's
    /// audience could not be set; then nothing was published.
    public func updateOwnProfile(_ fields: ProfileFields, visibility: ProfileVisibility)
        async throws(SessionError)
    {
        guard fields.problems.isEmpty else { throw .invalidInput }
        // For everyone the vcard-temp may be written: only once the conversion is known.
        if visibility == .everyone, !conversionKnown { throw .unavailable }
        // The vCard4 keeps what else it holds; a profile read from vcard-temp was only a
        // prefill, and nothing of it but the editor's fields goes into the vCard4 (R70).
        // I9: only item-not-found means there is none; any other failed read refuses the
        // save, so the editor's fields never replace a vCard4 that could not be read.
        // m29: an item this app cannot read is no "no vCard4" either: the save is refused.
        var base = Profile()
        let items: [PubSubItem]
        do {
            items = try await PubSub.items(node: VCard4.node, max: 1, via: connection)
        } catch .request(.error(let error)) where error.condition == .itemNotFound {
            items = []
        } catch {
            throw SessionError(error)
        }
        if let item = items.last {
            guard let payload = item.payload, let current = VCard4.profile(from: payload) else {
                throw SessionError(IQError.malformedResponse)
            }
            base = current
        }
        do {
            try await VCard4.publish(
                fields.applied(to: base), access: visibility.access,
                accountFeatures: accountFeatures, via: connection)
        } catch {
            throw SessionError(error)
        }
        if visibility == .everyone, !convertsVCardTemp {
            try await writeVCardTemp(fields.normalized)
        }
        keepOwnProfile(fields.normalized)
    }

    /// Whether the server answers vcard-temp from the PEP nodes (XEP-0398): then this app
    /// never writes or clears it (Prosody's `mod_vcard_legacy` turns a vcard-temp write into
    /// PEP writes and purges the picture), and the nodes' access model decides. Only
    /// meaningful while `conversionKnown`.
    var convertsVCardTemp: Bool { Avatars.serverConverts(accountFeatures) }

    /// Whether this session's account disco answered (R68): until it has, whether the server
    /// converts is not known, and nothing reads or writes the vcard-temp.
    var conversionKnown: Bool { featuresGeneration == generation }

    /// Asks for the account's features again when the session's own request failed.
    private func refreshAccountFeatures() async -> Bool {
        guard live else { return false }
        if conversionKnown { return true }
        let asked = generation
        guard let features = try? await PubSub.accountFeatures(via: connection),
            asked == generation, live
        else { return false }
        accountFeatures = features
        featuresGeneration = asked
        return true
    }

    /// Who can read the profile and picture now (R64; R68 (a), (c), (d); R70).
    ///
    /// - The setting: the access model of the vCard4 node and both picture nodes that exist;
    ///   nothing published reads as contacts, the default.
    /// - On a server without XEP-0398, our own vcard-temp is public storage: any field with
    ///   text in it (`publicCopy`) makes the audience Everyone, whatever the setting.
    /// - On a server that converts: Prosody answers vcard-temp from the nodes with the
    ///   requester's access checked (XEP-0398 5.2), so it is not read. ejabberd's `mod_avatar`
    ///   copies the picture into a public vcard-temp of its own: what it shows is
    ///   `serverCopy`, for certain. Any other server, or one that names no software, is read
    ///   the same way, and what it shows it only may show.
    ///
    /// Nil until the session is set up and its account disco answered (asked again here);
    /// `.unknown` when a read fails or is refused.
    public func profileAudience() async -> ProfileAudienceReading? {
        guard live, await refreshAccountFeatures() else { return nil }
        var accesses: Set<PEPAccess> = []
        for node in [VCard4.node, Avatars.dataNode, Avatars.metadataNode] {
            do {
                if let access = try await PubSub.access(of: node, via: connection) {
                    accesses.insert(access)
                }
            } catch {
                return ProfileAudienceReading(audience: .unknown)
            }
        }
        let setting: ProfileVisibility? =
            switch (accesses.contains(.open), accesses.contains(.presence)) {
            case (true, true): nil
            case (true, false): .everyone
            case (false, _): .contacts
            }
        var publicCopy: [PublicField] = []
        var snapshot: PublicCopySnapshot?
        var serverCopy: [PublicField] = []
        var certain = false
        let software = convertsVCardTemp ? await serverSoftware() : nil
        if software != "prosody" {
            let read: PublicCopySnapshot
            do {
                read = PublicCopySnapshot.of(try await ownVCardTemp())
            } catch {
                return ProfileAudienceReading(audience: .unknown)
            }
            if convertsVCardTemp {
                serverCopy = read.fields
                certain = software == "ejabberd"
            } else {
                publicCopy = read.fields
                snapshot = read
            }
        }
        let audience: ProfileAudience =
            if !publicCopy.isEmpty || !serverCopy.isEmpty {
                .everyone
            } else {
                switch setting {
                case .contacts?: .contacts
                case .everyone?: .everyone
                case nil: .mixed
                }
            }
        return ProfileAudienceReading(
            audience: audience, setting: setting, publicCopy: publicCopy, serverCopy: serverCopy,
            serverCopyCertain: certain, publicCopySnapshot: snapshot)
    }

    /// The server's software name (XEP-0092), lowercased; nil when it gives none.
    private func serverSoftware() async -> String? {
        let request = Element.iq(
            type: .get, to: domain, payload: Element("query", namespace: SoftwareVersion.namespace))
        guard let result = try? await connection.request(request),
            let name = result.child("query", namespace: SoftwareVersion.namespace)?
                .child("name", namespace: SoftwareVersion.namespace)?.text
        else { return nil }
        return name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The account's own vcard-temp as the server gives it, raw; nil when it has none.
    private func ownVCardTemp() async throws(SessionError) -> Element? {
        let result: Element
        do {
            result = try await connection.request(
                .iq(type: .get, payload: Element("vCard", namespace: VCardTemp.namespace)))
        } catch .error(let error)
            where error.condition == .itemNotFound || error.condition == .serviceUnavailable
        {
            return nil
        } catch {
            throw SessionError(error)
        }
        return result.child("vCard", namespace: VCardTemp.namespace)
    }

    /// Sets who can read the profile and picture (R64): the access model of the vCard4 node
    /// and both avatar nodes that exist. The vcard-temp is never touched (R70): a public copy
    /// there stays until "Remove public copy". `.unavailable` while the server's conversion is
    /// not known. Fails at the first node that does not take it; read `profileAudience()`
    /// again either way.
    public func setProfileVisibility(_ visibility: ProfileVisibility) async throws(SessionError) {
        guard live else { throw .notConnected }
        guard conversionKnown else { throw .unavailable }
        for (node, persistent) in [
            (VCard4.node, true), (Avatars.dataNode, false), (Avatars.metadataNode, false),
        ] {
            do {
                try await PubSub.setAccess(
                    visibility.access, node: node, persistent: persistent, via: connection)
            } catch {
                throw SessionError(error)
            }
        }
    }

    /// "Remove public copy" (R70): deletes the vcard-temp, exactly as `shown`: its raw
    /// `<vCard/>` must still have the digest shown (m26). When it changed, nothing is deleted
    /// and it comes back as it is now, to be shown again. Only on a server without XEP-0398, whose vcard-temp is a store
    /// of its own; `.unavailable` elsewhere and while that is not known.
    public func removePublicCopy(_ shown: PublicCopySnapshot) async throws(SessionError)
        -> PublicCopyRemoval
    {
        guard live else { throw .notConnected }
        guard conversionKnown, !convertsVCardTemp else { throw .unavailable }
        let current = PublicCopySnapshot.of(try await ownVCardTemp())
        guard current == shown else { return .changed(current) }
        guard !current.fields.isEmpty else { return .removed }
        do {
            try await VCardTemp.publish(Profile(), via: connection)
        } catch {
            throw SessionError(error)
        }
        if ownAvatarHash != .noAvatar {
            ownAvatarHash = .noAvatar
            await sendPresence()
        }
        return .removed
    }

    /// Writes the profile's fields into the vcard-temp, keeping what else it holds, its
    /// picture included (a profile save changes no picture, R70).
    private func writeVCardTemp(_ fields: ProfileFields) async throws(SessionError) {
        guard conversionKnown, !convertsVCardTemp else { return }
        var profile: Profile
        do {
            profile = try await VCardTemp.fetch(via: connection) ?? Profile()
        } catch {
            throw SessionError(error)
        }
        profile = fields.applied(to: profile)
        do {
            try await VCardTemp.publish(profile, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    private func keepOwnProfile(_ fields: ProfileFields) {
        do {
            try database.storeOwnProfile(
                accountID: accountID, jid: jid.description,
                fullName: fields.fullName.isEmpty ? nil : fields.fullName,
                nickname: fields.nickname.isEmpty ? nil : fields.nickname, data: fields.stored)
        } catch {
            Self.log.error("Own profile not stored")
        }
    }
}
