import CoreGraphics
import Foundation
import Security
import Testing
import XMPPCore
import XMPPTestSupport
import XippiStore

@testable import XippiSession

/// What the profile's server holds, for `answerProfileRequests`.
private struct ProfileServer: Sendable {
    /// The nodes that exist, with their access model.
    var nodes = [
        VCard4.node: "presence", Avatars.dataNode: "presence", Avatars.metadataNode: "presence",
    ]
    var configureFails = false
    /// Nodes whose configuration is refused (a switch that fails halfway).
    var refusedNodes: Set<String> = []
    /// Every publish is refused.
    var publishFails = false
    /// The owner configuration cannot be read.
    var readFails = false
    var vcardTemp: String?
    /// The server's software name (XEP-0092); nil answers no version.
    var software: String?
    /// The account's disco#info fails this many times first.
    var discoFailures = 0
    /// A vcard-temp write is refused.
    var vcardTempWriteFails = false
    /// The vCard4 item read fails with this condition.
    var vcard4ReadError: String?
    /// The vCard4 node's item holds this payload.
    var vcard4Payload: String?
    /// The vcard-temp write with this number (1 for the first) is refused.
    var refusedVCardTempWrite: Int?
}

/// A server that takes the profile's publishes, node creations and configurations and
/// vcard-temp writes (`SessionServer.stanzas` has every IQ).
@discardableResult
private func answerProfileRequests(
    _ server: SessionServer, _ state: ProfileServer = ProfileServer()
) -> Locked<String?> {
    let vcardTemp = Locked(state.vcardTemp)
    let vcardTempWrites = Locked(0)
    let nodes = Locked(state.nodes)
    let discoFailures = Locked(state.discoFailures)
    server.setResponder { iq in
        let result = "<iq type='result' id='\(iq.id ?? "")'"
        if iq.child("query", namespace: Disco.infoNamespace) != nil,
            iq[attribute: "to"] == SessionServer.account,
            discoFailures.withLock({ count in
                defer { count = max(count - 1, 0) }
                return count > 0
            })
        {
            return [SessionServer.error(iq, condition: "internal-server-error", type: "wait")]
        }
        if iq.child("query", namespace: SoftwareVersion.namespace) != nil {
            guard let name = state.software else {
                return [SessionServer.error(iq, condition: "service-unavailable")]
            }
            return [
                result + "><query xmlns='jabber:iq:version'><name>\(name)</name>"
                    + "<version>1</version></query></iq>"
            ]
        }
        if let pubsub = iq.child("pubsub", namespace: PubSub.namespace) {
            if iq.type == "get" {
                let node =
                    pubsub.child("items", namespace: PubSub.namespace)?[attribute: "node"] ?? ""
                if node == VCard4.node, let payload = state.vcard4Payload {
                    return [
                        result + "><pubsub xmlns='\(PubSub.namespace)'><items node='\(node)'>"
                            + "<item id='current'>\(payload)</item></items></pubsub></iq>"
                    ]
                }
                if node == VCard4.node, let condition = state.vcard4ReadError {
                    return [
                        SessionServer.error(
                            iq, condition: condition,
                            type: condition == "internal-server-error" ? "wait" : "cancel")
                    ]
                }
                return [
                    result + "><pubsub xmlns='\(PubSub.namespace)'><items node='\(node)'/>"
                        + "</pubsub></iq>"
                ]
            }
            if let node = pubsub.child("create", namespace: PubSub.namespace)?[attribute: "node"] {
                nodes.withLock { $0[node] = accessModel(in: iq) ?? "presence" }
            }
            if state.publishFails, pubsub.child("publish", namespace: PubSub.namespace) != nil {
                return [SessionServer.error(iq, condition: "forbidden", type: "auth")]
            }
            return [result + "/>"]
        }
        if let owner = iq.child("pubsub", namespace: PubSub.ownerNamespace) {
            let node =
                owner.child("configure", namespace: PubSub.ownerNamespace)?[attribute: "node"] ?? ""
            guard let access = nodes.value[node] else {
                return [SessionServer.error(iq, condition: "item-not-found")]
            }
            if iq.type == "get" {
                if state.readFails {
                    return [SessionServer.error(iq, condition: "forbidden", type: "auth")]
                }
                return [
                    result + "><pubsub xmlns='\(PubSub.ownerNamespace)'><configure node='\(node)'>"
                        + "<x xmlns='jabber:x:data' type='form'><field var='FORM_TYPE' type='hidden'>"
                        + "<value>http://jabber.org/protocol/pubsub#node_config</value></field>"
                        + "<field var='pubsub#access_model' type='list-single'>"
                        + "<value>\(access)</value></field></x></configure></pubsub></iq>"
                ]
            }
            if state.configureFails || state.refusedNodes.contains(node) {
                return [SessionServer.error(iq, condition: "forbidden", type: "auth")]
            }
            nodes.withLock { $0[node] = accessModel(in: iq) ?? access }
            return [result + "/>"]
        }
        if iq.child("vCard", namespace: VCardTemp.namespace) != nil {
            guard iq.type == "get" else {
                let number = vcardTempWrites.withLock { count in
                    count += 1
                    return count
                }
                if state.vcardTempWriteFails || number == state.refusedVCardTempWrite {
                    return [SessionServer.error(iq, condition: "forbidden", type: "auth")]
                }
                vcardTemp.set(iq.child("vCard", namespace: VCardTemp.namespace)?.xml())
                return [result + "/>"]
            }
            return [result + ">" + (vcardTemp.value ?? "<vCard xmlns='vcard-temp'/>") + "</iq>"]
        }
        if iq.child("query", namespace: Registration.namespace) != nil {
            return [result + "/>"]
        }
        return nil
    }
    return vcardTemp
}

/// The access model a publish (its publish-options), a node creation or a node configuration
/// asks for.
private func accessModel(in iq: Element) -> String? {
    let dataForms = "jabber:x:data"
    let pubsub = iq.child("pubsub", namespace: PubSub.namespace)
    let forms = [
        pubsub?.child("publish-options", namespace: PubSub.namespace)?
            .child("x", namespace: dataForms),
        pubsub?.child("configure", namespace: PubSub.namespace)?.child("x", namespace: dataForms),
        iq.child("pubsub", namespace: PubSub.ownerNamespace)?
            .child("configure", namespace: PubSub.ownerNamespace)?.child("x", namespace: dataForms),
    ]
    for form in forms.compactMap({ $0 }) {
        for field in form.children("field", namespace: dataForms)
        where field[attribute: "var"] == "pubsub#access_model" {
            return field.child("value", namespace: dataForms)?.text
        }
    }
    return nil
}

/// One request the profile code made of the server, in order.
private enum ProfileRequest: Equatable {
    case publish(String, access: String?)
    case create(String, access: String?)
    case configure(String, access: String?)
    case vcardTempWrite
}

extension SessionServer {
    /// The profile requests, in the order they were made: the profile's nodes and the
    /// vcard-temp only (OMEMO publishes its own nodes in the background).
    fileprivate var profileRequests: [ProfileRequest] {
        allRequests.filter { request in
            switch request {
            case .publish(let node, _), .create(let node, _), .configure(let node, _):
                allNodes.contains(node)
            case .vcardTempWrite: true
            }
        }
    }

    private var allRequests: [ProfileRequest] {
        stanzas.compactMap { iq in
            guard iq.type == "set" else { return nil }
            if let pubsub = iq.child("pubsub", namespace: PubSub.namespace) {
                if let node = pubsub.child("create", namespace: PubSub.namespace)?[
                    attribute: "node"]
                {
                    return .create(node, access: accessModel(in: iq))
                }
                if let node = pubsub.child("publish", namespace: PubSub.namespace)?[
                    attribute: "node"]
                {
                    return .publish(node, access: accessModel(in: iq))
                }
            }
            if let node = iq.child("pubsub", namespace: PubSub.ownerNamespace)?
                .child("configure", namespace: PubSub.ownerNamespace)?[attribute: "node"]
            {
                return .configure(node, access: accessModel(in: iq))
            }
            if iq.child("vCard", namespace: VCardTemp.namespace) != nil { return .vcardTempWrite }
            return nil
        }
    }

    /// The nodes published to, with the access model each publish asked for, in order.
    fileprivate var publishes: [(node: String, access: String?)] {
        profileRequests.compactMap {
            if case .publish(let node, let access) = $0 { (node, access) } else { nil }
        }
    }

    /// The nodes configured, with the access model each configuration set, in order.
    fileprivate var configurations: [(node: String, access: String?)] {
        profileRequests.compactMap {
            if case .configure(let node, let access) = $0 { (node, access) } else { nil }
        }
    }

    /// The vcard-temp vCards written.
    fileprivate var vcardTempWrites: [Element] {
        stanzas.compactMap { iq in
            iq.type == "set" ? iq.child("vCard", namespace: VCardTemp.namespace) : nil
        }
    }
}

private func picture() throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
    let image = try #require(context.makeImage())
    return try #require(
        AvatarCrop.render(image, crop: AvatarCrop(imageSize: CGSize(width: 80, height: 80))))
}

private let avatarNodes = [Avatars.dataNode, Avatars.metadataNode]
private let allNodes = [VCard4.node, Avatars.dataNode, Avatars.metadataNode]

/// Ruling R64 (amended in fix round 2): who can read the profile and the picture.
@Suite("ProfileVisibility")
struct ProfileVisibilityTests {
    private static let fields = ProfileFields(
        fullName: "Alice", email: "alice@example.test", webPage: "https://example.test")

    private static let publicVCardTemp =
        "<vCard xmlns='vcard-temp'><FN>Alice</FN><NICKNAME>al</NICKNAME>"
        + "<EMAIL><USERID>alice@example.test</USERID></EMAIL><ORG><ORGNAME>ACME"
        + "</ORGNAME></ORG><PHOTO><TYPE>image/png</TYPE><BINVAL>iVBORw0KGgo=</BINVAL>"
        + "</PHOTO></vCard>"

    /// A session whose server converts PEP to vcard-temp (XEP-0398) or not.
    private static func harness(converts: Bool = false, publishOptions: Bool = true)
        async throws -> SessionHarness
    {
        var options = SessionServer.Options()
        options.accountFeatures = ["urn:xmpp:mam:2"]
        if publishOptions { options.accountFeatures.append(PubSub.publishOptionsFeature) }
        if converts { options.accountFeatures.append(Avatars.conversionFeature) }
        return try await SessionHarness(options: options)
    }

    // MARK: Publishing

    @Test(.timeLimit(.minutes(1)))
    func contactsPublishTheProfileWithPresenceAndNoVCardTemp() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server)
        try await harness.goOnline()

        try await harness.session.updateOwnProfile(Self.fields, visibility: .contacts)

        let vcard = harness.server.publishes.filter { $0.node == VCard4.node }
        #expect(vcard.map(\.access) == ["presence"])
        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func everyonePublishesTheProfileOpenAndWritesTheVCardTemp() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server)
        try await harness.goOnline()

        try await harness.session.updateOwnProfile(Self.fields, visibility: .everyone)

        let vcard = harness.server.publishes.filter { $0.node == VCard4.node }
        #expect(vcard.map(\.access) == ["open"])
        let written = try #require(harness.server.vcardTempWrites.last)
        #expect(VCardTemp.profile(from: written)?.fullName == "Alice")
        // A profile save writes the fields only: the picture is the picture's business.
        #expect(written.child("PHOTO", namespace: VCardTemp.namespace) == nil)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func thePictureNodesCarryTheChosenAccess() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server)
        try await harness.goOnline()
        let image = try picture()

        try await harness.session.publishAvatar(imageData: image, visibility: .contacts)
        #expect(
            harness.server.publishes.filter { avatarNodes.contains($0.node) }.map(\.access)
                == ["presence", "presence"])
        #expect(harness.server.vcardTempWrites.isEmpty)

        try await harness.session.publishAvatar(imageData: image, visibility: .everyone)
        #expect(
            harness.server.publishes.filter { avatarNodes.contains($0.node) }.map(\.access)
                == ["presence", "presence", "open", "open"])
        // Without the server's conversion (XEP-0398), the vCard carries the picture too.
        let written = try #require(harness.server.vcardTempWrites.last)
        #expect(VCardTemp.profile(from: written)?.avatar != nil)
        await harness.stop()
    }

    /// C1: a server that converts (Prosody's `mod_vcard_legacy`) turns a vcard-temp write
    /// into PEP writes and purges the picture: it is never written or cleared there.
    @Test(.timeLimit(.minutes(1)))
    func withConversionTheVCardTempIsNeverTouched() async throws {
        let harness = try await Self.harness(converts: true)
        answerProfileRequests(harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()

        try await harness.session.updateOwnProfile(Self.fields, visibility: .everyone)
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .everyone)
        try await harness.session.setProfileVisibility(.contacts)
        try await harness.session.setProfileVisibility(.everyone)
        try await harness.session.removeAvatar()

        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    /// m15: without publish-options the node gets its audience before anything is published:
    /// an existing node is configured, a missing one created with its configuration.
    @Test(.timeLimit(.minutes(1)))
    func withoutPublishOptionsTheAudienceIsSetBeforeThePublish() async throws {
        let harness = try await Self.harness(publishOptions: false)
        var state = ProfileServer()
        state.nodes = [VCard4.node: "presence"]
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        try await harness.session.updateOwnProfile(Self.fields, visibility: .everyone)
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .everyone)

        // Only the profile's nodes: OMEMO publishes its own in the background.
        let requests = harness.server.profileRequests.filter { request in
            switch request {
            case .publish(let node, _), .create(let node, _), .configure(let node, _):
                allNodes.contains(node)
            case .vcardTempWrite: false
            }
        }
        #expect(
            requests == [
                .configure(VCard4.node, access: "open"), .publish(VCard4.node, access: nil),
                .configure(Avatars.dataNode, access: "open"),
                .create(Avatars.dataNode, access: "open"), .publish(Avatars.dataNode, access: nil),
                .configure(Avatars.metadataNode, access: "open"),
                .create(Avatars.metadataNode, access: "open"),
                .publish(Avatars.metadataNode, access: nil),
            ])
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedAudienceIsAFailureAndNothingGoesOut() async throws {
        let harness = try await Self.harness(publishOptions: false)
        answerProfileRequests(harness.server, ProfileServer(configureFails: true))
        try await harness.goOnline()

        await #expect(throws: SessionError.self) {
            try await harness.session.updateOwnProfile(Self.fields, visibility: .contacts)
        }
        await #expect(throws: SessionError.self) {
            try await harness.session.publishAvatar(imageData: try picture(), visibility: .contacts)
        }
        await #expect(throws: SessionError.self) {
            try await harness.session.setProfileVisibility(.everyone)
        }
        #expect(harness.server.publishes.isEmpty)
        await harness.stop()
    }

    // MARK: Switching

    /// R70: switching the audience never touches the vcard-temp, either way.
    @Test(.timeLimit(.minutes(1)))
    func switchingTheAudienceNeverTouchesTheVCardTemp() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()

        try await harness.session.setProfileVisibility(.everyone)
        try await harness.session.setProfileVisibility(.contacts)

        #expect(harness.server.configurations.map(\.node) == allNodes + allNodes)
        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    /// m28: a save under Everyone writes the editor's fields into the vcard-temp and keeps
    /// everything else there as it was: a picture of its own, a TEL with types, an ORG.
    @Test(.timeLimit(.minutes(1)))
    func aSaveForEveryoneKeepsWhatTheVCardTempHeldBeyondTheFields() async throws {
        let harness = try await Self.harness()
        let seeded =
            "<vCard xmlns='vcard-temp'><TEL><WORK/><VOICE/><NUMBER>+1 555 0100</NUMBER></TEL>"
            + "<ORG><ORGNAME>ACME</ORGNAME></ORG><PHOTO><TYPE>image/png</TYPE>"
            + "<BINVAL>iVBORw0KGgo=</BINVAL></PHOTO></vCard>"
        answerProfileRequests(harness.server, ProfileServer(vcardTemp: seeded))
        try await harness.goOnline()
        // A picture of the account's own exists, published for contacts only.
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .contacts)

        try await harness.session.updateOwnProfile(Self.fields, visibility: .everyone)

        let written = try #require(harness.server.vcardTempWrites.last)
        #expect(VCardTemp.profile(from: written)?.fullName == "Alice")
        let original = try #require(
            SessionServer.elements(
                "<iq xmlns='jabber:client'>" + seeded + "</iq>"
            ).first?.elements.first)
        for name in ["TEL", "ORG", "PHOTO"] {
            #expect(
                written.child(name, namespace: VCardTemp.namespace)?.xml()
                    == original.child(name, namespace: VCardTemp.namespace)?.xml(), "\(name)")
        }
        await harness.stop()
    }

    /// I9: only item-not-found means there is no vCard4; any other failed read refuses the
    /// save, so the editor's fields never replace a vCard4 that could not be read.
    @Test(.timeLimit(.minutes(1)), arguments: ["forbidden", "internal-server-error"])
    func aVCard4ThatCannotBeReadRefusesTheSave(_ condition: String) async throws {
        let harness = try await Self.harness()
        var state = ProfileServer(vcardTemp: Self.publicVCardTemp)
        state.vcard4ReadError = condition
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        await #expect(throws: SessionError.self) {
            try await harness.session.updateOwnProfile(Self.fields, visibility: .contacts)
        }
        await #expect(throws: SessionError.self) {
            _ = try await harness.session.ownProfileFields()
        }
        #expect(!harness.server.publishes.contains { $0.node == VCard4.node })
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func noVCard4YetIsCreatedBySaving() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer()
        state.vcard4ReadError = "item-not-found"
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        try await harness.session.updateOwnProfile(Self.fields, visibility: .contacts)

        #expect(harness.server.publishes.filter { $0.node == VCard4.node }.count == 1)
        await harness.stop()
    }

    /// I10: removing the picture takes its own copy out of the vcard-temp (published there for
    /// Everyone) and the presence hash; the rest of the vcard-temp stays.
    @Test(.timeLimit(.minutes(1)))
    func removingThePictureRemovesItsOwnPublicCopy() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(
            harness.server,
            ProfileServer(
                vcardTemp: "<vCard xmlns='vcard-temp'><ORG><ORGNAME>ACME</ORGNAME></ORG></vCard>"))
        try await harness.goOnline()
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .everyone)
        let published = try #require(harness.server.vcardTempWrites.last)
        #expect(published.child("PHOTO", namespace: VCardTemp.namespace) != nil)

        try await harness.session.removeAvatar()

        let after = try #require(harness.server.vcardTempWrites.last)
        #expect(after.child("PHOTO", namespace: VCardTemp.namespace) == nil)
        #expect(after.child("ORG", namespace: VCardTemp.namespace) != nil)
        try await waitUntil("presence without the hash") {
            harness.server.stanzas.last { $0.name == "presence" }?
                .child("x", namespace: "vcard-temp:x:update")?
                .child("photo", namespace: "vcard-temp:x:update")?.text == ""
        }
        await harness.stop()
    }

    /// I11: when taking the picture's public copy out fails, the picture is not forgotten: a
    /// second "Remove picture" tries the copy again and takes it out.
    @Test(.timeLimit(.minutes(1)))
    func aFailedPhotoStepIsTriedAgain() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer(
            vcardTemp: "<vCard xmlns='vcard-temp'><ORG><ORGNAME>ACME</ORGNAME></ORG></vCard>")
        // The first write is the picture's, for Everyone; the second, its removal, fails.
        state.refusedVCardTempWrite = 2
        let vcard = answerProfileRequests(harness.server, state)
        try await harness.goOnline()
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .everyone)

        await #expect(throws: SessionError.self) { try await harness.session.removeAvatar() }
        #expect(vcard.value?.contains("<PHOTO") == true)

        try await harness.session.removeAvatar()
        #expect(vcard.value?.contains("<PHOTO") == false)
        #expect(vcard.value?.contains("ACME") == true)
        await harness.stop()
    }

    /// m29: a vCard4 item this app cannot read is no "no vCard4": the save is refused.
    @Test(.timeLimit(.minutes(1)))
    func anUnreadableVCard4RefusesTheSave() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer()
        state.vcard4Payload = "<vcard xmlns='urn:example:not-vcard4'><fn>Alice</fn></vcard>"
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        await #expect(throws: SessionError.self) {
            try await harness.session.updateOwnProfile(Self.fields, visibility: .contacts)
        }
        #expect(!harness.server.publishes.contains { $0.node == VCard4.node })
        await harness.stop()
    }

    /// I10: a vcard-temp PHOTO that is not the picture removed stays; the pane notes it.
    @Test(.timeLimit(.minutes(1)))
    func aPublicPhotoThatIsNotOursStays() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()
        try await harness.session.publishAvatar(imageData: try picture(), visibility: .contacts)

        try await harness.session.removeAvatar()

        #expect(harness.server.vcardTempWrites.isEmpty)
        let reading = await harness.session.profileAudience()
        #expect(reading?.publicCopy.contains { $0.name == "PHOTO" } == true)
        await harness.stop()
    }

    /// m26: the removal compares the raw vCard: a picture swapped after the dialog opened is
    /// not deleted unseen.
    @Test(.timeLimit(.minutes(1)))
    func aSwappedPhotoIsNotDeletedUnseen() async throws {
        let harness = try await Self.harness()
        let vcard = answerProfileRequests(
            harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()
        let shown = try #require(await harness.session.profileAudience()?.publicCopySnapshot)
        vcard.set(Self.publicVCardTemp.replacingOccurrences(of: "iVBORw0KGgo=", with: "AAAA"))

        let outcome = try await harness.session.removePublicCopy(shown)

        guard case .changed(let now) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(now.fields == shown.fields)
        #expect(now.digest != shown.digest)
        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    /// R70: "Remove public copy" deletes exactly the fields shown, and only those.
    @Test(.timeLimit(.minutes(1)))
    func removingThePublicCopyDeletesTheSnapshotShown() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()
        let shown = try #require(await harness.session.profileAudience()?.publicCopySnapshot)

        let outcome = try await harness.session.removePublicCopy(shown)

        #expect(outcome == .removed)
        let written = try #require(harness.server.vcardTempWrites.last)
        #expect(written.elements.isEmpty)
        await harness.stop()
    }

    /// m23: a public copy that changed since it was shown is shown again, not deleted.
    @Test(.timeLimit(.minutes(1)))
    func aPublicCopyThatChangedIsShownAgainNotDeleted() async throws {
        let harness = try await Self.harness()
        let vcard = answerProfileRequests(
            harness.server, ProfileServer(vcardTemp: Self.publicVCardTemp))
        try await harness.goOnline()
        let shown = try #require(await harness.session.profileAudience()?.publicCopySnapshot)
        vcard.set("<vCard xmlns='vcard-temp'><TEL><NUMBER>+31 20 555 0100</NUMBER></TEL></vCard>")

        let outcome = try await harness.session.removePublicCopy(shown)

        guard case .changed(let now) = outcome else {
            Issue.record("got \(outcome)")
            return
        }
        #expect(now.fields == [PublicField(name: "TEL", value: "+31 20 555 0100")])
        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedRemovalIsAFailure() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer(vcardTemp: Self.publicVCardTemp)
        state.vcardTempWriteFails = true
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()
        let shown = try #require(await harness.session.profileAudience()?.publicCopySnapshot)
        await #expect(throws: SessionError.self) {
            _ = try await harness.session.removePublicCopy(shown)
        }
        await harness.stop()
    }

    /// R70 prefill: a profile read from vcard-temp fills the editor; saving publishes only
    /// the editor's fields to the vCard4.
    @Test(.timeLimit(.minutes(1)))
    func aSaveAfterAPrefillPublishesOnlyTheEditorsFields() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer(
            vcardTemp: "<vCard xmlns='vcard-temp'><FN>Alice</FN><EMAIL><USERID>a@x.test</USERID>"
                + "</EMAIL><EMAIL><USERID>b@x.test</USERID></EMAIL><TEL><NUMBER>1</NUMBER></TEL>"
                + "<ORG><ORGNAME>ACME</ORGNAME></ORG></vCard>")
        state.nodes = [:]
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        let prefill = try #require(try await harness.session.ownProfileFields())
        #expect(prefill.fullName == "Alice")
        #expect(prefill.email == "a@x.test")
        try await harness.session.updateOwnProfile(prefill, visibility: .contacts)

        let published = harness.server.stanzas.compactMap { iq -> Element? in
            guard
                let publish = iq.child("pubsub", namespace: PubSub.namespace)?
                    .child("publish", namespace: PubSub.namespace),
                publish[attribute: "node"] == VCard4.node
            else { return nil }
            return publish.child("item", namespace: PubSub.namespace)?.elements.first
        }
        let vcard4 = try #require(published.last)
        let profile = try #require(VCard4.profile(from: vcard4))
        #expect(profile.fullName == "Alice")
        #expect(profile.emails == ["a@x.test"])
        #expect(profile.phones.isEmpty)
        #expect(vcard4.elements.allSatisfy { $0.namespace == VCard4.namespace })
        #expect(harness.server.vcardTempWrites.isEmpty)
        await harness.stop()
    }

    /// I4: without the account's disco the conversion is not known: nothing reads or writes
    /// the vcard-temp, and the audience stays not ready until a disco answers.
    @Test(.timeLimit(.minutes(1)))
    func aFailedAccountDiscoLeavesTheAudienceNotReady() async throws {
        let harness = try await Self.harness()
        answerProfileRequests(harness.server, ProfileServer(discoFailures: 2))
        try await harness.goOnline()

        #expect(await harness.session.profileAudience() == nil)
        await #expect(throws: SessionError.unavailable) {
            try await harness.session.setProfileVisibility(.contacts)
        }
        await #expect(throws: SessionError.unavailable) {
            try await harness.session.updateOwnProfile(Self.fields, visibility: .everyone)
        }
        #expect(harness.server.vcardTempWrites.isEmpty)
        // The next disco answers: the audience can be read.
        #expect(await harness.session.profileAudience()?.audience == .contacts)
        await harness.stop()
    }

    /// m20: a switch refused halfway reads back as what the server holds.
    @Test(.timeLimit(.minutes(1)))
    func aSwitchThatFailsHalfwayReadsBackAsMixed() async throws {
        let harness = try await Self.harness()
        var state = ProfileServer()
        state.refusedNodes = [Avatars.metadataNode]
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()

        await #expect(throws: SessionError.self) {
            try await harness.session.setProfileVisibility(.everyone)
        }
        let reading = await harness.session.profileAudience()
        #expect(reading?.audience == .mixed)
        #expect(reading?.setting == nil)
        await harness.stop()
    }

    // MARK: Reading the audience (I2, I3)

    private static func audience(_ state: ProfileServer, converts: Bool = false) async throws
        -> ProfileAudienceReading?
    {
        let harness = try await Self.harness(converts: converts)
        answerProfileRequests(harness.server, state)
        try await harness.goOnline()
        let reading = await harness.session.profileAudience()
        await harness.stop()
        return reading
    }

    @Test(.timeLimit(.minutes(1)))
    func everyNodeForContactsReadsAsContacts() async throws {
        #expect(try await Self.audience(ProfileServer())?.audience == .contacts)
    }

    @Test(.timeLimit(.minutes(1)))
    func everyNodeOpenReadsAsEveryone() async throws {
        var state = ProfileServer()
        state.nodes = state.nodes.mapValues { _ in "open" }
        #expect(try await Self.audience(state)?.audience == .everyone)
    }

    /// m16: an open picture beside a profile for contacts is neither.
    @Test(.timeLimit(.minutes(1)))
    func anOpenPictureBesideAProfileForContactsIsMixed() async throws {
        var state = ProfileServer()
        state.nodes[Avatars.metadataNode] = "open"
        #expect(try await Self.audience(state)?.audience == .mixed)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedReadIsNotKnown() async throws {
        #expect(try await Self.audience(ProfileServer(readFails: true))?.audience == .unknown)
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingPublishedReadsAsContacts() async throws {
        var state = ProfileServer()
        state.nodes = [:]
        #expect(try await Self.audience(state)?.audience == .contacts)
    }

    /// R68(c) as R70 defines it: our own vcard-temp is public, and the audience reads
    /// Everyone while the setting is what the nodes say.
    @Test(.timeLimit(.minutes(1)))
    func aPublicVCardTempCountsAsEveryone() async throws {
        var state = ProfileServer(vcardTemp: Self.publicVCardTemp)
        let reading = try await Self.audience(state)
        #expect(reading?.audience == .everyone)
        #expect(reading?.setting == .contacts)
        #expect(
            reading?.publicCopy.map(\.name) == ["FN", "NICKNAME", "EMAIL", "ORG", "PHOTO"])
        #expect(reading?.publicCopy.first == PublicField(name: "FN", value: "Alice"))
        state.nodes = [:]
        #expect(try await Self.audience(state)?.setting == .contacts)
    }

    /// I7: content is judged on the raw XML: a field the parser rejects still counts.
    @Test(.timeLimit(.minutes(1)))
    func aFieldTheParserRejectsIsStillContent() async throws {
        var state = ProfileServer(
            vcardTemp: "<vCard xmlns='vcard-temp'><URL>example.com</URL></vCard>")
        state.nodes = [:]
        let url = try await Self.audience(state)
        #expect(url?.audience == .everyone)
        #expect(url?.publicCopy == [PublicField(name: "URL", value: "example.com")])
        state.vcardTemp =
            "<vCard xmlns='vcard-temp'><PHOTO><BINVAL>not an image</BINVAL></PHOTO></vCard>"
        #expect(
            try await Self.audience(state)?.publicCopy == [PublicField(name: "PHOTO", value: "")])
        state.vcardTemp =
            "<vCard xmlns='vcard-temp'><EMAIL><USERID> </USERID></EMAIL><ORG/></vCard>"
        #expect(try await Self.audience(state)?.audience == .contacts)
    }

    @Test(.timeLimit(.minutes(1)))
    func longValuesAreShortenedForTheDialog() async throws {
        var state = ProfileServer(
            vcardTemp: "<vCard xmlns='vcard-temp'><DESC>" + String(repeating: "n", count: 200)
                + "</DESC><ADR><LOCALITY>Bern</LOCALITY><CTRY>CH</CTRY></ADR></vCard>")
        state.nodes = [:]
        let fields = try #require(try await Self.audience(state)?.publicCopy)
        #expect(fields.map(\.name) == ["DESC", "ADR"])
        #expect(fields[0].value.count <= PublicField.maxValue + 1)
        #expect(fields[0].value.hasSuffix("…"))
        #expect(fields[1].value == "Bern CH")
    }

    /// I5 and I8: a server known to copy (ejabberd's mod_avatar) shows the picture for sure.
    @Test(.timeLimit(.minutes(1)))
    func aServerKnownToCopyShowsThePictureForSure() async throws {
        var state = ProfileServer(vcardTemp: Self.publicVCardTemp)
        state.software = "ejabberd"
        let reading = try await Self.audience(state, converts: true)
        #expect(reading?.audience == .everyone)
        #expect(reading?.setting == .contacts)
        #expect(reading?.publicCopy == [])
        #expect(reading?.serverCopy.map(\.name).contains("PHOTO") == true)
        #expect(reading?.serverCopyCertain == true)
    }

    /// I8 and m24: a converting server that names no software may keep a copy: read as one,
    /// said with "may".
    @Test(.timeLimit(.minutes(1)))
    func anUnnamedConvertingServerMayShowACopy() async throws {
        let reading = try await Self.audience(
            ProfileServer(vcardTemp: Self.publicVCardTemp), converts: true)
        #expect(reading?.audience == .everyone)
        #expect(reading?.serverCopy.isEmpty == false)
        #expect(reading?.serverCopyCertain == false)
    }

    /// Prosody answers vcard-temp from the PEP nodes, with the requester's access checked
    /// (XEP-0398 5.2): what it shows its owner is no public copy.
    @Test(.timeLimit(.minutes(1)))
    func prosodysViewOfThePEPNodesIsNoPublicCopy() async throws {
        var state = ProfileServer(vcardTemp: Self.publicVCardTemp)
        state.software = "Prosody"
        let reading = try await Self.audience(state, converts: true)
        #expect(reading?.audience == .contacts)
        #expect(reading?.serverCopy == [])
    }

    @Test(.timeLimit(.minutes(1)))
    func offlineTheAudienceIsNotReady() async throws {
        let harness = try await Self.harness()
        #expect(await harness.session.profileAudience() == nil)
        await harness.stop()
    }
}

/// Ruling R61: an account's pinned certificates count for its own domain's file hosts only.
@Suite("AccountMediaTrust")
struct AccountMediaTrustTests {
    /// A self-signed certificate for `upload.example.test`, valid until 2126.
    static let certificate =
        "MIIBkzCCATigAwIBAgIUNlrL9UyiPSVMLRxc6Asx4eCCvmIwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTdXBsb2Fk"
        + "LmV4YW1wbGUudGVzdDAgFw0yNjExMTkxNTQ1MzNaGA8yMTI2MTAyNjE1NDUzM1owHjEcMBoGA1UEAwwTdXBsb2Fk"
        + "LmV4YW1wbGUudGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDIc9FdmyM3RTdM58k2vkiaDkBa/oPkP+2WP"
        + "lqPfyIAMNqkLaQoVcQ/iDAS4whtt60ja+3OHooZCEhwI2+PqF+WjUjBQMB0GA1UdDgQWBBQ5IS40koMH72Sik/Rk"
        + "epvzZg8I9TAPBgNVHRMBAf8EBTADAQH/MB4GA1UdEQQXMBWCE3VwbG9hZC5leGFtcGxlLnRlc3QwCgYIKoZIzj0E"
        + "AwIDSQAwRgIhAIC80x7M7xc9tWvdRqwbN65Uhq8gAIlJxDwGZeqyPZY/AiEApr8UR+MOgN82EXYhtK/sPEfTQeZr"
        + "ImVy6Hq+Vt5mSMw="
    static let sha256 = "121f013c419a9d10b05283ed9a778be7b4141d986b82cfb7c12e3e7ccd142887"

    private static func trust(for host: String) throws -> SecTrust {
        let der = try #require(Data(base64Encoded: certificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    private static func decision(_ evaluator: AccountHostTrust, host: String) async throws
        -> Bool
    {
        await evaluator.evaluate(try trust(for: host), host: host) == .trusted
    }

    @Test func aPinnedCertificateIsTrustedOnTheAccountsOwnHosts() async throws {
        let evaluator = AccountHostTrust(domain: "example.test", pinnedSHA256: [Self.sha256])
        #expect(try await Self.decision(evaluator, host: "upload.example.test"))
        #expect(try await Self.decision(evaluator, host: "Upload.Example.Test."))
        #expect(try await Self.decision(evaluator, host: "example.test"))
    }

    @Test func theSamePinIsRefusedOnAnyOtherHost() async throws {
        let evaluator = AccountHostTrust(domain: "example.test", pinnedSHA256: [Self.sha256])
        for host in [
            "upload.other.test", "evilexample.test", "example.test.other.test", "test",
            "192.0.2.1",
        ] {
            #expect(try await !Self.decision(evaluator, host: host), "\(host)")
        }
    }

    /// m14: a domain in Unicode matches its hosts, which arrive as A-labels.
    @Test func anIDNDomainMatchesItsHostsByTheirALabels() async throws {
        let evaluator = AccountHostTrust(domain: "jäbber.example", pinnedSHA256: [Self.sha256])
        #expect(try await Self.decision(evaluator, host: "upload.xn--jbber-gra.example"))
        #expect(try await !Self.decision(evaluator, host: "upload.xn--jbber-gra.example.test"))
    }

    @Test func anUnpinnedAccountKeepsTheSystemsTrust() async throws {
        let evaluator = AccountHostTrust(domain: "example.test", pinnedSHA256: [])
        #expect(try await !Self.decision(evaluator, host: "upload.example.test"))
    }

    @Test(.timeLimit(.minutes(1)))
    func theSessionMovesFilesWithItsAccountsTransport() async throws {
        let asked = Locked<[String]>([])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AccountMediaTrust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = MediaEnvironment(
            directory: directory, transport: URLSessionMediaTransport(), bytestreams: nil,
            accountTransport: { account in
                asked.withLock { $0.append(account.jid) }
                return URLSessionMediaTransport()
            })
        let harness = try await SessionHarness(media: media)
        #expect(asked.value == [SessionServer.account])
        await harness.stop()
    }
}

/// A password and a FAST token kept in memory, counting what is done to the token.
final class TokenStore: CredentialStore {
    struct WriteFailed: Error {}

    let passwords = Locked<[String: String]>([:])
    let tokens = Locked<[String: FASTToken]>([:])
    /// Accounts SCRAM worked for (XEP-0474).
    let plainRefusals = Locked<Set<String>>([])
    let failsWrites: Bool

    init(failsWrites: Bool = false) {
        self.failsWrites = failsWrites
    }

    func password(for jid: JID) async -> String? { passwords.value[jid.bare.description] }
    func fastToken(for jid: JID) async -> FASTToken? { tokens.value[jid.bare.description] }
    func plainRefused(for jid: JID) async -> Bool {
        plainRefusals.value.contains(jid.bare.description)
    }
    func refusePlain(for jid: JID) async {
        plainRefusals.withLock { _ = $0.insert(jid.bare.description) }
    }

    func store(_ token: FASTToken?, for jid: JID) async {
        tokens.withLock { $0[jid.bare.description] = token }
    }

    func setPassword(_ password: String, for jid: JID) throws {
        if failsWrites { throw WriteFailed() }
        passwords.withLock { $0[jid.bare.description] = password }
    }

    func remove(for jid: JID) throws {
        passwords.withLock { $0[jid.bare.description] = nil }
        tokens.withLock { $0[jid.bare.description] = nil }
    }

    static let staleToken = FASTToken(
        mechanism: "HT-SHA-256-NONE", token: "stale", expiry: Date().addingTimeInterval(86_400))
}

/// m1: a token minted under the old password is not kept once the password changed.
@Suite("FASTTokensOnPasswordChange")
struct FASTTokensOnPasswordChangeTests {
    @Test(.timeLimit(.minutes(1)))
    func aChangedPasswordDropsTheStoredToken() async throws {
        let store = TokenStore()
        let jid = try JID(SessionServer.account)
        try store.setPassword("secret", for: jid)
        let harness = try await SessionHarness(credentials: store)
        answerProfileRequests(harness.server)
        try await harness.goOnline()
        await store.store(TokenStore.staleToken, for: jid)

        try await harness.session.changePassword("new secret")

        #expect(store.passwords.value[SessionServer.account] == "new secret")
        #expect(store.tokens.value[SessionServer.account] == nil)
        await harness.stop()
    }
}

/// m20: the pane's reads of the audience, overtaken by newer reads and by switches.
@Suite("ProfileAudienceTracker")
struct ProfileAudienceTrackerTests {
    @Test func anOvertakenReadIsDropped() {
        var tracker = ProfileAudienceTracker()
        let first = tracker.beginRead()
        let second = tracker.beginRead()
        let late = tracker.finishRead(
            ProfileAudienceReading(audience: .contacts), generation: first)
        #expect(!late)
        #expect(tracker.reading == nil)
        let latest = tracker.finishRead(
            ProfileAudienceReading(audience: .everyone), generation: second)
        #expect(latest)
        #expect(tracker.reading?.audience == .everyone)
    }

    @Test func aSwitchOvertakesAReadUnderWay() {
        var tracker = ProfileAudienceTracker()
        let read = tracker.beginRead()
        tracker.beginSwitch()
        let kept = tracker.finishRead(ProfileAudienceReading(audience: .contacts), generation: read)
        #expect(!kept)
        #expect(tracker.reading == nil)
        #expect(!tracker.isCurrent(read))
    }
}
