import Foundation
import XMPPCore
import XippiStore
import os

/// The account's avatar and profile (XEP-0084, XEP-0153, XEP-0398, XEP-0292, XEP-0054).
extension AccountSession {
    /// Publishes the image (any format ImageIO reads) as the account's avatar, encoded again
    /// small enough for any server (ruling R36), readable by those `visibility` names (R64).
    /// For everyone, and without XEP-0398 conversion on the server, the vCard photo is set
    /// too, so clients that only read vCards see it; for contacts the vCard is left alone,
    /// since anyone can read it.
    public func publishAvatar(imageData: Data, visibility: ProfileVisibility)
        async throws(SessionError)
    {
        // For everyone the vCard photo may be written: only once the server's conversion is
        // known (R68).
        if visibility == .everyone, !conversionKnown { throw .unavailable }
        let avatar: Avatars.Prepared
        do {
            avatar = try Avatars.prepareForPublishing(imageData: imageData)
            try await Avatars.publish(
                avatar, access: visibility.access, accountFeatures: accountFeatures,
                via: connection)
        } catch {
            throw SessionError(error)
        }
        do {
            try await avatars.storeOwn(avatar.data, type: avatar.type)
        } catch {
            Self.log.error("Own avatar not stored")
        }
        if visibility == .everyone, !Avatars.serverConverts(accountFeatures) {
            try await setVCardPhoto(.data(avatar.data, type: avatar.type))
            ownAvatarHash = .hash(avatar.sha1)
        }
        // XEP-0398 5.1: the presence goes out again, so rooms see the new hash too.
        await sendPresence()
    }

    /// Removes the account's avatar.
    public func removeAvatar() async throws(SessionError) {
        do {
            try await Avatars.disable(via: connection)
        } catch {
            throw SessionError(error)
        }
        let removed = await avatars.ownPictureHash()
        // I10: the picture's own copy in a vcard-temp of the server's own (published there for
        // Everyone) goes with it, and so does the presence hash. Any other PHOTO stays, for
        // "Remove public copy" (R70). The picture is forgotten here only once that step went
        // through or had nothing to do (I11): a failed step is tried again by the next removal.
        if conversionKnown, !convertsVCardTemp, let removed {
            try await removeOwnVCardPhoto(hash: removed)
        }
        await avatars.ownRemoved()
        await sendPresence()
    }

    /// Takes the vcard-temp PHOTO out when it is the picture with SHA-1 `hash`, keeping every
    /// other field; the presence hash then names no picture. A PHOTO that is another picture
    /// stays, and the presence names it.
    private func removeOwnVCardPhoto(hash: String) async throws(SessionError) {
        let stored: Profile?
        do {
            stored = try await VCardTemp.fetch(via: connection)
        } catch {
            throw SessionError(error)
        }
        guard var profile = stored, let photo = profile.avatar else { return }
        guard case .data(let data, _) = photo, Avatars.sha1(data) == hash else {
            ownAvatarHash = VCardTemp.photoHash(of: profile).map(Presence.AvatarHash.hash)
            return
        }
        profile.avatar = nil
        do {
            try await VCardTemp.publish(profile, via: connection)
        } catch {
            throw SessionError(error)
        }
        ownAvatarHash = .noAvatar
    }

    private func setVCardPhoto(_ photo: Profile.Photo?) async throws(SessionError) {
        var profile: Profile
        do {
            profile = try await VCardTemp.fetch(via: connection) ?? Profile()
        } catch {
            throw SessionError(error)
        }
        // Nothing to take away: the vcard-temp is not written.
        if photo == nil, profile.avatar == nil { return }
        profile.avatar = photo
        do {
            try await VCardTemp.publish(profile, via: connection)
        } catch {
            throw SessionError(error)
        }
    }

    /// The profile of `contact`, or of the account when nil: the vCard4 (XEP-0292) when there
    /// is one, else the vcard-temp (XEP-0054).
    public func fetchProfile(of contact: JID? = nil) async throws(SessionError) -> Profile? {
        do {
            if let profile = try await VCard4.fetch(contact?.bare, via: connection) {
                return profile
            }
        } catch .request(let error)
            where error == .timeout || error == .notConnected
            || error == .sessionEnded
        {
            throw SessionError(error)
        } catch .request(.error(let error)) where error.condition == .itemNotFound {
            // No vCard4 node: the vcard-temp is next.
        } catch {
            // The account's own (I9): only item-not-found means there is no vCard4; a read
            // that failed otherwise must not let the vcard-temp stand in for it. A contact's
            // (forbidden to strangers, or no PEP) falls back to the vcard-temp.
            if contact == nil { throw SessionError(error) }
        }
        do {
            return try await VCardTemp.fetch(contact, via: connection)
        } catch {
            throw SessionError(error)
        }
    }
}

extension SessionError {
    init(_ error: PubSubError) {
        switch error {
        case .preconditionNotMet:
            self = .refused(StanzaError(type: .cancel, condition: .conflict))
        case .notSupported:
            self = .unavailable
        case .forbidden:
            self = .refused(StanzaError(type: .auth, condition: .forbidden))
        case .request(let request):
            self = SessionError(request)
        }
    }

    init(_ error: AvatarError) {
        switch error {
        case .notFound: self = .unavailable
        case .pubsub(let pubsub): self = SessionError(pubsub)
        default: self = .invalidInput
        }
    }
}
