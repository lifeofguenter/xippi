import XMPPCore

/// One side's ICE credentials for a content (XEP-0176 `ufrag` and `pwd`). New ones are an
/// ICE restart (section 5.9).
struct ICECredentials: Sendable, Equatable {
    var ufrag: String
    var pwd: String

    init(ufrag: String, pwd: String) {
        self.ufrag = ufrag
        self.pwd = pwd
    }

    /// The credentials of a content's ICE-UDP transport; nil when it lacks either.
    init?(_ content: JingleContent?) {
        guard let transport = content?.transport.flatMap(ICEUDPTransport.init(element:)),
            let ufrag = transport.ufrag, let pwd = transport.pwd
        else { return nil }
        self.init(ufrag: ufrag, pwd: pwd)
    }
}

/// A call's Jingle RTP session as both sides last described it: each content as this side
/// sent it and as the peer sent it, in media-section order. During a renegotiation the
/// engine gets the peer's side of it as an SDP description.
struct RTPSession: Sendable {
    /// This side's content-add waiting for the peer's answer.
    struct PendingAdd: Sendable {
        /// The whole re-offer, every content.
        var offer: [JingleContent]
        /// The contents it adds.
        var contents: [JingleContent]
        /// The BUNDLE group of the offer that added them.
        var group: [String]
        /// A content-accept, content-reject or error came, or the wait ended.
        var answered = false
    }

    /// This side's ICE restart waiting for the peer's answer.
    struct PendingRestart: Sendable {
        /// Tells this restart from a later one when the answer to its transport-info comes.
        let number: Int
        /// This side's new credentials by content name; empty until the offer is made.
        var local: [String: ICECredentials] = [:]
        /// The peer acknowledged the transport-info that offers it.
        var acknowledged = false
    }

    /// Where the candidates of a peer's transport belong.
    enum CandidateGeneration: Equatable {
        /// The session's ICE generation (or a content it does not know yet).
        case current
        /// The peer's ICE restart that is being applied.
        case restarting
        /// A generation the session left, or never took.
        case stale
    }

    /// Earlier peer ufrags kept, so that their late candidates are known as stale.
    static let retiredUfragsKept = 8

    let sid: String
    /// This side's role.
    let role: JingleRole
    /// Content names in media-section order.
    private(set) var names: [String] = []
    private(set) var local: [String: JingleContent] = [:]
    private(set) var remote: [String: JingleContent] = [:]
    /// The BUNDLE group (XEP-0338) of the last negotiation; empty when the peer does not bundle.
    var group: [String] = []
    /// The DTLS role the peer took, "active" or "passive".
    var remoteSetup: String?
    var pendingAdd: PendingAdd?
    var pendingRestart: PendingRestart?
    /// The peer's new credentials of its restart, or its answer to this side's, while the
    /// engine takes them: its candidates under them wait.
    var restartingRemote: [String: ICECredentials] = [:]
    /// The peer's restarts this side is answering; this side's candidates wait for the new
    /// credentials.
    var answeringRestarts = 0
    /// This side's restart was taken back when its 60 s ran out, and the peer may still answer
    /// it: new credentials of the peer's in answer form are that late answer, not its offer.
    /// An answer taken for a later restart of this side's may itself be that late answer, so
    /// it stays set until a restart offer of the peer's is answered.
    var restartAbandoned = false
    /// Peer ufrags the session left, newest last.
    private(set) var retiredRemoteUfrags: [String] = []

    init(sid: String, role: JingleRole) {
        self.sid = sid
        self.role = role
    }

    /// Takes contents as negotiated. New names go after the known ones, in `order`.
    mutating func commit(order: [String], local: [JingleContent], remote: [JingleContent]) {
        for name in order where !names.contains(name) { names.append(name) }
        for content in local { self.local[content.name] = content }
        for content in remote { self.remote[content.name] = content }
    }

    /// This side's description of `name`, negotiated or offered, with the credentials of its
    /// ICE restart while one is open.
    func localContent(_ name: String) -> JingleContent? {
        let content = local[name] ?? pendingAdd?.contents.first { $0.name == name }
        guard let content, let restarted = pendingRestart?.local[name] else { return content }
        return Self.content(content, with: restarted)
    }

    // MARK: ICE restarts

    /// An ICE restart is open: this side's waits for its answer, or this side answers the
    /// peer's.
    var restarting: Bool { pendingRestart != nil || answeringRestarts > 0 }

    /// This side's candidates wait: they belong to new credentials the peer has not got yet.
    var holdsLocalCandidates: Bool {
        answeringRestarts > 0 || pendingRestart.map { !$0.acknowledged } ?? false
    }

    /// Where the candidates in a content of the peer's belong, by its transport's credentials.
    func generation(of content: JingleContent) -> CandidateGeneration {
        guard let credentials = ICECredentials(content),
            let current = ICECredentials(remote[content.name]), credentials != current
        else { return .current }
        return restartingRemote[content.name] == credentials ? .restarting : .stale
    }

    /// The peer's new ICE credentials in a transport-info, by content name: an ICE restart.
    /// A content bundled with one that restarts restarts with it. Nil when no content of the
    /// session gets new ones; credentials it left before are no restart.
    func restartCredentials(in contents: [JingleContent]) -> [String: ICECredentials]? {
        var restarted: [String: ICECredentials] = [:]
        for content in contents {
            guard let credentials = ICECredentials(content),
                let current = ICECredentials(remote[content.name]), credentials != current,
                restartingRemote[content.name] != credentials,
                !retiredRemoteUfrags.contains(credentials.ufrag)
            else { continue }
            restarted[content.name] = credentials
        }
        guard !restarted.isEmpty else { return nil }
        if let bundled = group.lazy.compactMap({ restarted[$0] }).first {
            for name in group where restarted[name] == nil && remote[name] != nil {
                restarted[name] = bundled
            }
        }
        return restarted
    }

    /// The peer's restart offer: the session as the peer described it, with its new
    /// credentials, as an offer (DTLS setup actpass) and without the old candidates.
    func remoteRestartOffer(_ credentials: [String: ICECredentials]) throws(SDPMapperError)
        -> String
    {
        let contents = names.compactMap { name -> JingleContent? in
            guard let content = remote[name], let old = ICECredentials(content) else { return nil }
            return Self.content(content, with: credentials[name] ?? old, setup: "actpass")
        }
        return try SDPMapper.sdp(
            sessionID: sid, contents: contents, group: group, author: role.other)
    }

    /// The peer's answer to this side's restart offer: the session as negotiated, with the
    /// peer's new credentials and the DTLS role it took.
    func remoteRestartAnswer(_ credentials: [String: ICECredentials]) throws(SDPMapperError)
        -> String
    {
        var answered = self
        for (name, new) in credentials {
            if let content = remote[name] {
                answered.remote[name] = Self.content(content, with: new)
            }
        }
        let offer = names.compactMap { localContent($0) }
        return try answered.remoteAnswer(
            accepted: [], pending: PendingAdd(offer: offer, contents: [], group: group),
            group: group
        ).sdp
    }

    /// Takes the peer's new credentials; candidates under the old ones are stale from now on.
    mutating func takeRemoteCredentials(_ credentials: [String: ICECredentials]) {
        for (name, new) in credentials {
            guard let content = remote[name] else { continue }
            if let old = ICECredentials(content), old != new { retire(ufrag: old.ufrag) }
            remote[name] = Self.content(content, with: new)
        }
        forgetRestartingRemote(credentials)
    }

    /// The peer's credentials that are never taken: they are no restart, and candidates under
    /// them are stale.
    mutating func retireRemote(_ credentials: [String: ICECredentials]) {
        for new in credentials.values { retire(ufrag: new.ufrag) }
        forgetRestartingRemote(credentials)
    }

    private mutating func retire(ufrag: String) {
        guard !retiredRemoteUfrags.contains(ufrag) else { return }
        retiredRemoteUfrags.append(ufrag)
        if retiredRemoteUfrags.count > Self.retiredUfragsKept {
            retiredRemoteUfrags.removeFirst()
        }
    }

    /// Takes this side's new credentials.
    mutating func takeLocalCredentials(_ credentials: [String: ICECredentials]) {
        for (name, new) in credentials {
            if let content = local[name] { local[name] = Self.content(content, with: new) }
        }
    }

    /// The peer's restart that was being applied is applied, or given up.
    mutating func forgetRestartingRemote(_ credentials: [String: ICECredentials]) {
        for (name, new) in credentials where restartingRemote[name] == new {
            restartingRemote[name] = nil
        }
    }

    /// `content` with `credentials` on its transport, no candidates, and, when given, the
    /// DTLS `setup`.
    static func content(
        _ content: JingleContent, with credentials: ICECredentials, setup: String? = nil
    ) -> JingleContent {
        var content = content
        var transport =
            content.transport.flatMap(ICEUDPTransport.init(element:)) ?? ICEUDPTransport()
        transport.ufrag = credentials.ufrag
        transport.pwd = credentials.pwd
        transport.candidates = []
        if let setup {
            for index in transport.fingerprints.indices {
                transport.fingerprints[index].setup = setup
            }
        }
        content.transport = transport.element
        return content
    }

    /// Who created the content `name`.
    func creator(of name: String) -> String? {
        local[name]?.creator ?? remote[name]?.creator
    }

    /// `contents` with the creator the session knows for each name, and `newCreator` for the
    /// others. `SDPMapper` gives every content of a description one creator, but a content
    /// keeps the creator of whoever added it (XEP-0166).
    func withCreators(_ contents: [JingleContent], newCreator: String) -> [JingleContent] {
        contents.map { content in
            var content = content
            content.creator = creator(of: content.name) ?? newCreator
            return content
        }
    }

    /// The session carries video this side described.
    var hasLocalVideo: Bool {
        names.contains { local[$0].map(Self.isVideo) ?? false }
    }

    /// Whether `role` sends video in the session: both sides' `senders` allow it.
    func carriesVideo(from role: JingleRole) -> Bool {
        names.contains { name in
            guard let local = local[name], let remote = remote[name], Self.isVideo(local) else {
                return false
            }
            return Self.allows(local.senders, role) && Self.allows(remote.senders, role)
        }
    }

    // MARK: The peer's side as SDP

    /// The peer's re-offer: the session as the peer described it, then `added`.
    func remoteOffer(adding added: [JingleContent], group: [String]) throws(SDPMapperError)
        -> String
    {
        let contents = names.compactMap { remote[$0] } + added.map(filledTransport)
        return try SDPMapper.sdp(
            sessionID: sid, contents: contents, group: group, author: role.other)
    }

    /// The peer's answer to this side's re-offer: the session as it was negotiated, then
    /// `accepted`, the peer's content-accept for the added contents. Returns the description
    /// and the peer's contents in it.
    ///
    /// The peer only answers the added contents, so the rest is made up from what the peer
    /// said last. A peer that offered the session described it as an offer: all its payload
    /// types, DTLS setup "actpass", and the direction it wanted. As an answer it takes only
    /// the payload types this side offered, the DTLS role it settled on, and the direction
    /// both sides agreed on that the re-offer still allows.
    func remoteAnswer(
        accepted: [JingleContent], pending: PendingAdd, group: [String]
    ) throws(SDPMapperError) -> (sdp: String, contents: [JingleContent]) {
        var offered: [String: JingleContent] = [:]
        for content in pending.offer { offered[content.name] = content }
        var contents: [JingleContent] = []
        for name in names {
            guard var content = remote[name] else { continue }
            content.senders = Self.agreedSenders([
                local[name]?.senders, content.senders, offered[name]?.senders,
            ])
            contents.append(answerForm(content, offer: offered[name] ?? local[name]))
        }
        for content in accepted {
            contents.append(answerForm(filledTransport(content), offer: offered[content.name]))
        }
        let sdp = try SDPMapper.sdp(
            sessionID: sid, contents: contents, group: group, author: role.other)
        return (sdp, contents)
    }

    /// `content` as part of an answer to `offer`.
    func answerForm(_ content: JingleContent, offer: JingleContent?) -> JingleContent {
        var content = content
        if var transport = content.transport.flatMap(ICEUDPTransport.init(element:)) {
            for index in transport.fingerprints.indices
            where transport.fingerprints[index].setup == "actpass" {
                transport.fingerprints[index].setup = remoteSetup
            }
            content.transport = transport.element
        }
        if var description = content.description.flatMap(RTPDescription.init(element:)),
            let offered = offer?.description.flatMap(RTPDescription.init(element:))
        {
            let ids = Set(offered.payloadTypes.map(\.id))
            let kept = description.payloadTypes.filter { ids.contains($0.id) }
            if !kept.isEmpty {
                description.payloadTypes = kept
                content.description = description.element
            }
        }
        return content
    }

    /// A content whose transport lacks ICE credentials or fingerprints takes them from the
    /// session's first content, which it is bundled with.
    func filledTransport(_ content: JingleContent) -> JingleContent {
        guard
            var transport = content.transport.flatMap(ICEUDPTransport.init(element:)),
            transport.ufrag == nil || transport.pwd == nil || transport.fingerprints.isEmpty,
            let first = names.first,
            let bundled = remote[first]?.transport.flatMap(ICEUDPTransport.init(element:))
        else { return content }
        var content = content
        if transport.ufrag == nil || transport.pwd == nil {
            transport.ufrag = bundled.ufrag
            transport.pwd = bundled.pwd
        }
        if transport.fingerprints.isEmpty { transport.fingerprints = bundled.fingerprints }
        content.transport = transport.element
        return content
    }

    // MARK: Helpers

    /// A content of an RTP session: an audio or video RTP description over ICE-UDP.
    static func isRTP(_ content: JingleContent) -> Bool {
        guard let description = content.description.flatMap(RTPDescription.init(element:)),
            JingleMedia(rawValue: description.media) != nil,
            content.transport.flatMap(ICEUDPTransport.init(element:)) != nil
        else { return false }
        return true
    }

    static func isVideo(_ content: JingleContent) -> Bool {
        content.description.flatMap(RTPDescription.init(element:))?.media
            == JingleMedia.video.rawValue
    }

    /// The `senders` every one of `values` allows.
    static func agreedSenders(_ values: [String?]) -> String? {
        let initiator = values.allSatisfy { allows($0, .initiator) }
        let responder = values.allSatisfy { allows($0, .responder) }
        switch (initiator, responder) {
        case (true, true): return nil
        case (true, false): return JingleRole.initiator.rawValue
        case (false, true): return JingleRole.responder.rawValue
        case (false, false): return "none"
        }
    }

    /// Whether `senders` lets `role` send.
    static func allows(_ senders: String?, _ role: JingleRole) -> Bool {
        switch senders {
        case nil, "both": true
        case "none": false
        case let senders?: senders == role.rawValue
        }
    }

    /// The DTLS setup of a content's transport.
    static func setup(of content: JingleContent?) -> String? {
        content?.transport.flatMap(ICEUDPTransport.init(element:))?.fingerprints.lazy
            .compactMap(\.setup).first
    }

    /// The DTLS role the other side takes when one side takes `setup`.
    static func opposite(_ setup: String?) -> String? {
        switch setup {
        case "active": "passive"
        case "passive": "active"
        default: nil
        }
    }

    /// The `<group/>` for `members`, as `JingleIQ.info`.
    static func groupInfo(_ members: [String]) -> [Element] {
        members.isEmpty ? [] : [JingleGroup(contents: members).element]
    }

    /// The members of the BUNDLE group in `info`; nil without one.
    static func bundle(in info: [Element]) -> [String]? {
        info.lazy.compactMap(JingleGroup.init(element:)).first { $0.semantics == "BUNDLE" }?
            .contents
    }
}
