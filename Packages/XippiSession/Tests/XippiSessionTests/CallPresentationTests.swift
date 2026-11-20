import Foundation
import Testing
import XMPPCore
import XippiCalls
import XippiSession

@Suite("CallPresentation")
struct CallPresentationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func call(
        _ direction: CallDirection = .incoming, video: Bool = true, state: CallState = .ringing,
        id: String = "call-1", _ change: (inout Call) -> Void = { _ in }
    ) throws -> Call {
        var call = Call(
            id: CallID(rawValue: id), direction: direction,
            peer: try JID(direction == .incoming ? "alice@example.com/phone" : "alice@example.com"),
            video: video, state: state)
        change(&call)
        return call
    }

    /// A board fed `events` in order, one second apart.
    private func board(_ events: [CallEvent]) -> CallBoard {
        var board = CallBoard()
        for (index, event) in events.enumerated() {
            board.apply(event, at: at(Double(index)))
        }
        return board
    }

    // MARK: - Ringing and answering

    @Test func incomingRingingShowsThePanelOnly() throws {
        let board = board([.ringing(try call())])
        let shown = try #require(board.call)
        #expect(shown.phase == .incoming)
        #expect(shown.status == .incoming(video: true))
        #expect(shown.peer == (try JID("alice@example.com")))
        #expect(shown.isRinging)
        #expect(!shown.showsWindow)
        #expect(board.incoming?.id == shown.id)
        #expect(board.windowCall == nil)
        #expect(shown.dismissal == .stays)
    }

    @Test func incomingAudioCallSaysAudio() throws {
        let board = board([.ringing(try call(video: false))])
        #expect(board.call?.status == .incoming(video: false))
    }

    @Test func acceptMovesTheCallToTheWindow() throws {
        let board = board([
            .ringing(try call()),
            .connecting(try call(state: .connecting) { $0.media.cameraOn = true }),
        ])
        let shown = try #require(board.call)
        #expect(shown.phase == .connecting)
        #expect(shown.status == .connecting)
        #expect(!shown.isRinging)
        #expect(shown.showsWindow)
        #expect(board.incoming == nil)
        #expect(board.windowCall?.id == shown.id)
        #expect(shown.camera == .on)
    }

    @Test func connectedStartsTheDurationOnce() throws {
        let board = board([
            .ringing(try call()),
            .connecting(try call(state: .connecting)),
            .connected(try call(state: .connected)),
            .mediaChanged(try call(state: .connected) { $0.media.muted = true }),
        ])
        let shown = try #require(board.call)
        #expect(shown.phase == .connected)
        #expect(shown.connectedAt == at(2))
        #expect(shown.status == .connected(since: at(2)))
        #expect(shown.muted)
    }

    @Test func outgoingCallShowsCallingThenRinging() throws {
        var board = CallBoard()
        board.apply(.ringing(try call(.outgoing, state: .ringing)), at: at(0))
        #expect(board.call?.phase == .calling)
        #expect(board.call?.status == .calling)
        #expect(board.call?.showsWindow == true)
        #expect(board.incoming == nil)
        board.apply(.ringing(try call(.outgoing) { $0.peerRinging = true }), at: at(1))
        #expect(board.call?.status == .ringing)
    }

    @Test func connectingAfterConnectedIsReconnecting() throws {
        let board = board([
            .ringing(try call(.outgoing)),
            .connecting(try call(.outgoing, state: .connecting)),
            .connected(try call(.outgoing, state: .connected)),
            .connecting(try call(.outgoing, state: .connecting)),
        ])
        #expect(board.call?.phase == .reconnecting)
        #expect(board.call?.status == .reconnecting)
        // The duration keeps counting from the first connection.
        #expect(board.call?.connectedAt == at(2))
    }

    @Test func reconnectedKeepsTheFirstConnectionTime() throws {
        let board = board([
            .connecting(try call(.outgoing, state: .connecting)),
            .connected(try call(.outgoing, state: .connected)),
            .connecting(try call(.outgoing, state: .connecting)),
            .connected(try call(.outgoing, state: .connected)),
        ])
        #expect(board.call?.phase == .connected)
        #expect(board.call?.connectedAt == at(1))
    }

    /// The peer moved the call to a new session (R34): the same call, reconnecting, in a new
    /// media session, so the window takes the new engine's video views and cameras.
    @Test func migratedCallReportsItsNewMediaSession() throws {
        var board = board([
            .ringing(try call { $0.mediaSession = 4 }),
            .connected(try call(state: .connected) { $0.mediaSession = 4 }),
        ])
        let before = try #require(board.call)
        #expect(before.mediaSession == 4)
        board.apply(.connecting(try call(state: .connecting) { $0.mediaSession = 5 }), at: at(5))
        let after = try #require(board.call)
        #expect(after.id == before.id)
        #expect(after.mediaSession == 5)
        #expect(after.phase == .reconnecting)
        #expect(after.connectedAt == before.connectedAt)
    }

    // MARK: - Media

    @Test func cameraFailureTurnsTheCameraOffWithReason() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected) { $0.media.cameraOn = true }),
            .mediaChanged(
                try call(.outgoing, state: .connected) {
                    $0.media.cameraOn = false
                    $0.media.cameraProblem = .cameraFailed("stopped")
                }),
        ])
        let shown = try #require(board.call)
        #expect(shown.camera == .unavailable(.failed))
        #expect(shown.note == CallNote(kind: .cameraFailed, pane: nil))
        #expect(shown.privacyPane == nil)
    }

    @Test func deniedCameraOffersThePrivacyPane() throws {
        let board = board([
            .connected(
                try call(.outgoing, state: .connected) { $0.media.cameraProblem = .cameraDenied })
        ])
        #expect(board.call?.camera == .unavailable(.denied))
        #expect(board.call?.note == CallNote(kind: .noCameraAccess, pane: .camera))
        #expect(board.call?.privacyPane == .camera)
    }

    @Test func missingCameraSaysNoCamera() throws {
        let board = board([
            .connected(
                try call(.outgoing, state: .connected) {
                    $0.media.cameraProblem = .cameraUnavailable
                })
        ])
        #expect(board.call?.camera == .unavailable(.noCamera))
        #expect(board.call?.note == CallNote(kind: .noCamera, pane: nil))
    }

    @Test func turningTheCameraOnAgainClearsTheProblem() throws {
        let board = board([
            .connected(
                try call(.outgoing, state: .connected) { $0.media.cameraProblem = .cameraDenied }),
            .mediaChanged(try call(.outgoing, state: .connected) { $0.media.cameraOn = true }),
        ])
        #expect(board.call?.camera == .on)
        #expect(board.call?.note == nil)
    }

    @Test func screenShareEndedByTheSystemIsNoted() throws {
        let display = ScreenShareSource(kind: .display(1), width: 1440, height: 900)
        let board = board([
            .connected(try call(.outgoing, state: .connected)),
            .mediaChanged(
                try call(.outgoing, state: .connected) { $0.media.screenShare = display }),
            .mediaChanged(try call(.outgoing, state: .connected)),
        ])
        let shown = try #require(board.call)
        #expect(shown.screenShare == nil)
        #expect(shown.notice == .screenShareEnded)
        #expect(shown.note == CallNote(kind: .screenShareEnded, pane: nil))
        #expect(CallPresentation.Notice.screenShareEnded.lifetime == .seconds(5))
    }

    @Test func screenShareStoppedByTheUserIsNotNoted() throws {
        let display = ScreenShareSource(kind: .display(1))
        var board = board([
            .connected(try call(.outgoing, state: .connected)),
            .mediaChanged(
                try call(.outgoing, state: .connected) { $0.media.screenShare = display }),
        ])
        #expect(board.call?.screenShare == display)
        board.willStopScreenShare(CallID(rawValue: "call-1"))
        board.apply(.mediaChanged(try call(.outgoing, state: .connected)), at: at(5))
        #expect(board.call?.screenShare == nil)
        #expect(board.call?.notice == nil)
        // A later share that the system ends is noted again.
        board.apply(
            .mediaChanged(
                try call(.outgoing, state: .connected) { $0.media.screenShare = display }),
            at: at(6))
        board.apply(.mediaChanged(try call(.outgoing, state: .connected)), at: at(7))
        #expect(board.call?.notice == .screenShareEnded)
    }

    @Test func screenShareErrorsBecomeNotices() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.screenShareFailed(MediaEngineError.screenShareDenied, for: id)
        #expect(board.call?.notice == .screenShareDenied)
        #expect(
            board.call?.note == CallNote(kind: .noScreenRecordingAccess, pane: .screenRecording))
        #expect(board.call?.privacyPane == .screenRecording)
        #expect(CallPresentation.Notice.screenShareDenied.lifetime == nil)

        board.screenShareFailed(MediaEngineError.screenShareSourceGone, for: id)
        #expect(board.call?.notice == .screenShareFailed)

        board.clearNotice(.screenShareFailed, for: id)
        #expect(board.call?.notice == nil)

        // Cancelled by a later share or by the user: nothing to say.
        board.screenShareFailed(MediaEngineError.screenShareCancelled, for: id)
        board.screenShareFailed(CancellationError(), for: id)
        #expect(board.call?.notice == nil)

        board.screenShareFailed(CallError.notReady, for: id)
        #expect(board.call?.notice == .screenShareFailed)
    }

    @Test func aNewScreenShareClearsTheOldNotice() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.screenShareFailed(MediaEngineError.screenShareDenied, for: id)
        board.apply(
            .mediaChanged(
                try call(.outgoing, state: .connected) {
                    $0.media.screenShare = ScreenShareSource(kind: .window(7))
                }),
            at: at(3))
        #expect(board.call?.notice == nil)
    }

    @Test func clearingAnotherNoticeKeepsTheCurrentOne() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.screenShareFailed(MediaEngineError.screenShareDenied, for: id)
        board.clearNotice(.screenShareEnded, for: id)
        #expect(board.call?.notice == .screenShareDenied)
    }

    @Test func cameraSwitchFailureIsNoted() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.cameraSwitchFailed(for: id)
        #expect(board.call?.notice == .cameraSwitchFailed)
        #expect(board.call?.note == CallNote(kind: .cameraFailed, pane: nil))
    }

    @Test func videoControlFollowsTheCall() throws {
        let audio = board([.connected(try call(.outgoing, video: false, state: .connected))])
        #expect(audio.call?.videoControl == .addVideo)
        #expect(audio.call?.showsSelfView == false)
        #expect(audio.call?.showsRemoteVideo == false)

        let added = board([
            .connected(
                try call(.outgoing, video: false, state: .connected) {
                    $0.media.cameraOn = true
                    $0.media.sendsVideo = true
                    $0.media.receivesVideo = true
                })
        ])
        #expect(added.call?.videoControl == .turnOff)
        #expect(added.call?.showsSelfView == true)
        #expect(added.call?.showsRemoteVideo == true)

        let off = board([
            .connected(
                try call(.outgoing, state: .connected) {
                    $0.media.sendsVideo = true
                })
        ])
        #expect(off.call?.videoControl == .turnOn)
        #expect(off.call?.showsSelfView == false)

        let sharing = board([
            .connected(
                try call(.outgoing, state: .connected) {
                    $0.media.sendsVideo = true
                    $0.media.screenShare = ScreenShareSource(kind: .display(2))
                })
        ])
        #expect(sharing.call?.showsSelfView == true)
    }

    @Test func controlsFollowThePhase() throws {
        let ringing = board([.ringing(try call())])
        #expect(ringing.call?.controlsEnabled == false)
        #expect(ringing.call?.canShareScreen == false)

        let calling = board([.ringing(try call(.outgoing))])
        #expect(calling.call?.controlsEnabled == true)
        #expect(calling.call?.canShareScreen == false)

        let connected = board([.connected(try call(.outgoing, state: .connected))])
        #expect(connected.call?.controlsEnabled == true)
        #expect(connected.call?.canShareScreen == true)

        let ended = board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.remoteHungUp)), .remoteHungUp),
        ])
        #expect(ended.call?.controlsEnabled == false)
        #expect(ended.call?.canShareScreen == false)
    }

    @Test func peerMuteIsShown() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected) { $0.media.peerMuted = true })
        ])
        #expect(board.call?.peerMuted == true)
    }

    // MARK: - Ending

    @Test func hangUpClosesTheWindowAtOnce() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.hungUp)), .hungUp),
        ])
        #expect(board.call == nil)
        #expect(board.windowCall == nil)
    }

    @Test func peerHangingUpLingers() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected) { $0.media.cameraOn = true }),
            .ended(try call(.outgoing, state: .ended(.remoteHungUp)), .remoteHungUp),
        ])
        let shown = try #require(board.windowCall)
        #expect(shown.phase == .ended(.remoteHungUp))
        #expect(shown.status == .ended(.ended))
        #expect(shown.dismissal == .after(.seconds(3)))
        #expect(shown.note == nil)
        #expect(!shown.showsSelfView)
    }

    @Test func unansweredIncomingCallLeavesNothing() throws {
        for reason in [CallEndReason.missed, .declined, .answeredElsewhere, .declinedElsewhere] {
            let board = board([
                .ringing(try call()),
                .ended(try call(state: .ended(reason)), reason),
            ])
            #expect(board.call == nil, "\(reason)")
            #expect(board.incoming == nil, "\(reason)")
        }
    }

    @Test func deniedMicrophoneStaysWithThePrivacyPane() throws {
        let reason = CallEndReason.mediaFailed(.microphoneDenied)
        let board = board([
            .ringing(try call()),
            .connecting(try call(state: .connecting)),
            .ended(try call(state: .ended(reason)), reason),
        ])
        let shown = try #require(board.call)
        #expect(shown.status == .ended(.microphoneDenied))
        #expect(shown.privacyPane == .microphone)
        #expect(shown.dismissal == .byUser)
        #expect(board.windowCall?.id == shown.id)
    }

    @Test func dismissClearsTheEndedCall() throws {
        var board = board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.busy)), .busy),
        ])
        board.dismiss(CallID(rawValue: "other"))
        #expect(board.call != nil)
        board.dismiss(CallID(rawValue: "call-1"))
        #expect(board.call == nil)
    }

    @Test func endedReasonsHaveTheirCopyKeys() {
        let expected: [(CallEndReason, CallEndCopy)] = [
            (.hungUp, .ended),
            (.remoteHungUp, .ended),
            (.cancelled, .cancelled),
            (.missed, .missed),
            (.declined, .declined),
            (.remoteDeclined, .declined),
            (.busy, .busy),
            (.noAnswer, .noAnswer),
            (.answeredElsewhere, .answeredElsewhere),
            (.declinedElsewhere, .declinedElsewhere),
            (.timedOut, .timedOut),
            (.connectionFailed, .connectionFailed),
            (.mediaFailed(.microphoneDenied), .microphoneDenied),
            (.mediaFailed(.microphoneUnavailable), .noMicrophone),
            (.mediaFailed(.configurationRefused), .failed),
            (.mediaFailed(.sessionDescription("x")), .failed),
            (.failed, .failed),
        ]
        for (reason, copy) in expected {
            #expect(CallEndCopy(reason) == copy, "\(reason)")
        }
    }

    @Test func dismissalByReason() throws {
        // Ending it here closes the window at once: the board forgets the call.
        for reason in [CallEndReason.hungUp, .cancelled] {
            let board = board([
                .ringing(try call(.outgoing)),
                .ended(try call(.outgoing, state: .ended(reason)), reason),
            ])
            #expect(board.call == nil, "\(reason)")
        }
        let expected: [(CallEndReason, CallDismissal)] = [
            (.remoteHungUp, .after(.seconds(3))),
            (.remoteDeclined, .after(.seconds(3))),
            (.busy, .after(.seconds(3))),
            (.noAnswer, .after(.seconds(3))),
            (.connectionFailed, .after(.seconds(3))),
            (.timedOut, .after(.seconds(3))),
            (.failed, .after(.seconds(3))),
            (.mediaFailed(.microphoneUnavailable), .after(.seconds(3))),
            (.mediaFailed(.microphoneDenied), .byUser),
        ]
        for (reason, dismissal) in expected {
            let board = board([
                .ringing(try call(.outgoing)),
                .ended(try call(.outgoing, state: .ended(reason)), reason),
            ])
            #expect(board.call?.dismissal == dismissal, "\(reason)")
        }
    }

    // MARK: - Several calls

    @Test func eventsForAnotherCallAreIgnoredDuringACall() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected)),
            .ringing(try call(id: "call-2")),
            .ended(try call(state: .ended(.missed), id: "call-2"), .missed),
        ])
        #expect(board.call?.id == CallID(rawValue: "call-1"))
        #expect(board.call?.phase == .connected)
    }

    @Test func aNewCallReplacesAnEndedOne() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.busy)), .busy),
            .ringing(try call(id: "call-2")),
        ])
        #expect(board.call?.id == CallID(rawValue: "call-2"))
        #expect(board.call?.phase == .incoming)
    }

    @Test func lateEventsForAnUnknownCallAreIgnored() throws {
        let board = board([
            .mediaChanged(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.hungUp)), .hungUp),
        ])
        #expect(board.call == nil)
    }

    @Test func eventsAfterTheEndChangeNothing() throws {
        let board = board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.busy)), .busy),
            .mediaChanged(try call(.outgoing, state: .connected) { $0.media.muted = true }),
        ])
        #expect(board.call?.phase == .ended(.busy))
        #expect(board.call?.muted == false)
    }

    // MARK: - Settings panes

    @Test func privacyPanesOpenTheirSettings() {
        #expect(
            PrivacyPane.microphone.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(
            PrivacyPane.camera.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        #expect(
            PrivacyPane.screenRecording.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(
            CallPresentation.soundSettingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    // MARK: - An account's events end (fix round 1, I1)

    @Test func endedSourceTakesARingingCallAway() throws {
        var board = board([.ringing(try call())])
        board.sourceEnded(CallID(rawValue: "call-1"))
        #expect(board.call == nil)
        #expect(board.incoming == nil)
        // Later calls ring again.
        board.apply(.ringing(try call(id: "call-2")), at: at(5))
        #expect(board.incoming?.id == CallID(rawValue: "call-2"))
    }

    @Test func endedSourceClosesTheWindow() throws {
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.sourceEnded(CallID(rawValue: "call-1"))
        #expect(board.windowCall == nil)
        #expect(board.call == nil)
    }

    @Test func endedSourceLeavesOtherCallsAndEndedOnes() throws {
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.sourceEnded(CallID(rawValue: "other"))
        #expect(board.call?.phase == .connected)

        var ended = self.board([
            .connected(try call(.outgoing, state: .connected)),
            .ended(try call(.outgoing, state: .ended(.busy)), .busy),
        ])
        ended.sourceEnded(CallID(rawValue: "call-1"))
        #expect(ended.call?.phase == .ended(.busy), "it goes on its own timer")
    }

    // MARK: - Accept and decline (I2)

    @Test func declineOnlyWhileRinging() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.ringing(try call())])
        #expect(board.canDecline(id))
        #expect(!board.canDecline(CallID(rawValue: "other")))
        board.apply(.connecting(try call(state: .connecting)), at: at(1))
        #expect(!board.canDecline(id), "an answered call is never declined")
        board.apply(.ended(try call(state: .ended(.hungUp)), .hungUp), at: at(2))
        #expect(!board.canDecline(id))
    }

    @Test func acceptingMovesTheCallToTheWindowAtOnce() throws {
        let id = CallID(rawValue: "call-1")
        var board = board([.ringing(try call())])
        board.willAccept(id)
        #expect(board.incoming == nil, "the panel goes and the ringing stops")
        #expect(!board.canDecline(id), "a late Decline does not end the answered call")
        let shown = try #require(board.windowCall)
        #expect(shown.phase == .connecting)
        #expect(shown.status == .connecting)
        board.apply(.connecting(try call(state: .connecting)), at: at(1))
        #expect(board.call?.phase == .connecting)
        board.apply(.connected(try call(state: .connected)), at: at(2))
        #expect(board.call?.connectedAt == at(2))
    }

    @Test func acceptingAnotherCallChangesNothing() throws {
        var board = board([.ringing(try call())])
        board.willAccept(CallID(rawValue: "other"))
        #expect(board.incoming != nil)
        var connected = self.board([.connected(try call(.outgoing, state: .connected))])
        connected.willAccept(CallID(rawValue: "call-1"))
        #expect(connected.call?.phase == .connected)
    }

    // MARK: - A call that could not start (I3)

    @Test func deniedMicrophoneOnStartShowsTheWindow() throws {
        var board = CallBoard()
        let peer = try JID("alice@example.com")
        board.startFailed(
            MediaEngineError.microphoneDenied, peer: peer, video: true,
            id: CallID(rawValue: "start"))
        let shown = try #require(board.windowCall)
        #expect(shown.direction == .outgoing)
        #expect(shown.peer == peer)
        #expect(shown.status == .ended(.microphoneDenied))
        #expect(shown.privacyPane == .microphone)
        #expect(shown.dismissal == .byUser)
        #expect(board.incoming == nil)
    }

    @Test func otherStartFailuresShowForAMoment() throws {
        let peer = try JID("alice@example.com")
        var offline = CallBoard()
        offline.startFailed(CallError.notConnected, peer: peer, video: false)
        #expect(offline.windowCall?.status == .ended(.failed))
        #expect(offline.windowCall?.dismissal == .after(.seconds(3)))

        var noMicrophone = CallBoard()
        noMicrophone.startFailed(MediaEngineError.microphoneUnavailable, peer: peer, video: false)
        #expect(noMicrophone.windowCall?.status == .ended(.noMicrophone))
    }

    @Test func cancelledStartShowsNothing() throws {
        var board = CallBoard()
        board.startFailed(CancellationError(), peer: try JID("alice@example.com"), video: false)
        #expect(board.call == nil)
    }

    @Test func failedStartDuringACallChangesNothing() throws {
        var board = board([.connected(try call(.outgoing, state: .connected))])
        board.startFailed(CallError.busy, peer: try JID("bob@example.com"), video: false)
        #expect(board.call?.id == CallID(rawValue: "call-1"))
        #expect(board.call?.phase == .connected)
    }

    // MARK: - More event orders (M15)

    @Test func connectedRightAfterRingingOpensTheWindow() throws {
        let board = board([
            .ringing(try call()),
            .connected(try call(state: .connected)),
        ])
        #expect(board.incoming == nil)
        #expect(board.windowCall?.phase == .connected)
        #expect(board.windowCall?.connectedAt == at(1))
    }

    @Test func declinedWhileAcceptingClosesAtOnce() throws {
        // Hanging up while the answer is still being set up ends the call as declined.
        let board = board([
            .ringing(try call()),
            .connecting(try call(state: .connecting)),
            .ended(try call(state: .ended(.declined)), .declined),
        ])
        #expect(board.call == nil)
    }
}
