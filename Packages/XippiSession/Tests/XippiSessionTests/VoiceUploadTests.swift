import Foundation
import Testing
import XMPPCore

@testable import XippiSession

/// Voice messages go up as `audio/mp4` (RFC 4337), not UTType's `audio/x-m4a`.
@Suite struct VoiceUploadTests {
    @Test func mpeg4AudioIsAudioMP4() {
        #expect(MediaLibrary.mediaType(forExtension: "m4a") == "audio/mp4")
        #expect(MediaLibrary.mediaType(forExtension: "M4A") == "audio/mp4")
        #expect(MediaLibrary.mediaType(forExtension: "m4b") == "audio/mp4")
        #expect(MediaLibrary.mediaType(forExtension: "png") == "image/png")
    }

    @Test func aRecordingAsksForAndPutsAudioMP4() async throws {
        let rig = try UploadRig()
        defer { rig.media.cleanUp() }
        let file = try rig.media.file("Voice message.m4a", MediaRig.bytes(4000))

        _ = try await rig.service.send(file: file, chatID: rig.media.chatID, encrypt: false)

        let request = try #require(rig.slotRequest)
        #expect(request[attribute: "content-type"] == "audio/mp4")
        #expect(rig.media.transport.uploads.first?.slot.contentType == "audio/mp4")
    }
}
