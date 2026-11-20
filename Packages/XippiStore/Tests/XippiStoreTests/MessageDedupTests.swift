import Foundation
import GRDB
import Testing

@testable import XippiStore

@Suite struct MessageDedupTests {
    // MARK: - Rule 1-3: one row per message per account

    @Test func liveThenArchiveIsOneRow() throws {
        let f = try StoreFixture()
        let live = f.fromBob("hi", at: 0, originID: "o1", stanzaID: "s1")

        let inserted = try f.db.upsertIncoming(live)
        let id = try inserted.id()
        #expect(inserted == .inserted(id))
        // The live copy again (stream resumption resends it): no new row.
        #expect(try f.db.upsertIncoming(live) == .duplicate(id))

        // The same message from MAM catch-up, with the archive's stanza-id and its own stamp.
        var archived = f.fromBob("hi", at: 0.4, originID: "o1", stanzaID: "s1", archiveID: "A1")
        archived.receivedAt = StoreFixture.at(60)
        #expect(try f.db.upsertIncoming(archived) == .merged(id))
        #expect(try f.db.upsertIncoming(archived) == .duplicate(id))

        let rows = try f.messages()
        #expect(rows.count == 1)
        #expect(rows.first?.archiveID == "A1")
        #expect(rows.first?.body == "hi")
    }

    @Test func carbonThenArchiveIsOneRow() throws {
        let f = try StoreFixture()
        // Received carbon: bob wrote to another of our devices.
        let received = f.fromBob("to my laptop", at: 0, originID: "o-r")
        let receivedID = try f.db.upsertIncoming(received).id()
        let receivedArchived = f.fromBob("to my laptop", at: 1, originID: "o-r", archiveID: "A-r")
        #expect(try f.db.upsertIncoming(receivedArchived) == .merged(receivedID))

        // Sent carbon: we wrote to bob from another device. No local row exists for it.
        let sent = IncomingMessage(
            accountID: f.accountID, chatID: f.bobChatID, direction: .outgoing,
            senderJID: "me@x/phone",
            body: "from my phone", originID: "o-s", stanzaMessageID: "o-s",
            timestamp: StoreFixture.at(10),
            receivedAt: StoreFixture.at(10))
        let sentID = try f.db.upsertIncoming(sent).id()
        var sentArchived = sent
        sentArchived.archiveID = "A-s"
        sentArchived.timestamp = StoreFixture.at(11)
        #expect(try f.db.upsertIncoming(sentArchived) == .merged(sentID))
        #expect(try f.db.upsertIncoming(sent) == .duplicate(sentID))

        let rows = try f.messages()
        #expect(rows.map(\.archiveID) == ["A-r", "A-s"])
        #expect(rows.map(\.direction) == [.incoming, .outgoing])
    }

    @Test func sameRoomTwoAccountsTwoRows() throws {
        let f = try StoreFixture()
        let onFirst = f.inRoom(
            "hello room", nick: "carol", occupantID: "occ-c", originID: "o3", archiveID: "R1")
        let onSecond = f.inRoom(
            "hello room", nick: "carol", occupantID: "occ-c", chatID: f.otherRoomChatID,
            accountID: f.otherAccountID, originID: "o3", archiveID: "R1")

        let first = try f.db.upsertIncoming(onFirst).id()
        let second = try f.db.upsertIncoming(onSecond).id()
        #expect(first != second)
        #expect(try f.db.upsertIncoming(onFirst) == .duplicate(first))
        #expect(try f.db.upsertIncoming(onSecond) == .duplicate(second))

        #expect(try f.messages(chatID: f.roomChatID).count == 1)
        #expect(try f.messages(chatID: f.otherRoomChatID).count == 1)
    }

    @Test func archiveIDAloneIsEnough() throws {
        let f = try StoreFixture()
        // A client without origin-id or a stable id: only the archive identifies it.
        let first = try f.db.upsertIncoming(f.fromBob("x", at: 0, archiveID: "A9")).id()
        #expect(
            try f.db.upsertIncoming(f.fromBob("x", at: 0, archiveID: "A9")) == .duplicate(first))
        // A different archive entry with the same text is a different message.
        #expect(
            try f.db.upsertIncoming(f.fromBob("x", at: 5, archiveID: "A10")) != .duplicate(first))
        #expect(try f.messages().count == 2)
    }

    @Test func originIDNeedsTheSameSender() throws {
        let f = try StoreFixture()
        let carol = f.inRoom("one", nick: "carol", occupantID: "occ-c", originID: "same")
        let dave = f.inRoom("two", nick: "dave", occupantID: "occ-d", originID: "same")
        let carolID = try f.db.upsertIncoming(carol).id()
        let daveID = try f.db.upsertIncoming(dave).id()
        #expect(carolID != daveID)

        // A nick change keeps the occupant id, so carol's copy under a new nick is the same message.
        var renamed = carol
        renamed.senderJID = "\(StoreFixture.roomJID)/caroline"
        renamed.senderNick = "caroline"
        renamed.archiveID = "R7"
        #expect(try f.db.upsertIncoming(renamed) == .merged(carolID))
        #expect(try f.messages().count == 2)
    }

    @Test func originIDMatchesAcrossResourcesOfOneContact() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("hi", originID: "o7", resource: "phone")).id()
        // An archive that stored the bare JID: origin-id is unique per message, so it is the same one.
        var bare = f.fromBob("hi", at: 1, originID: "o7", archiveID: "A7")
        bare.senderJID = StoreFixture.bobJID
        #expect(try f.db.upsertIncoming(bare) == .merged(id))
        #expect(try f.messages().count == 1)
    }

    @Test func stanzaIDMatchesOnlyWithin24HoursAndSameSender() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("ping", at: 0, stanzaID: "1")).id()
        #expect(
            try f.db.upsertIncoming(f.fromBob("ping", at: 2 * 3600, stanzaID: "1"))
                == .duplicate(id))
        #expect(
            try f.db.upsertIncoming(f.fromBob("ping", at: -2 * 3600, stanzaID: "1"))
                == .duplicate(id))

        // Clients reuse counters: a day later the same id is a new message.
        let later = try f.db.upsertIncoming(f.fromBob("ping", at: 25 * 3600, stanzaID: "1"))
        #expect(later == .inserted(try later.id()))
        // Another device of bob's with its own counter.
        let laptop = try f.db.upsertIncoming(
            f.fromBob("ping", at: 0, stanzaID: "1", resource: "laptop"))
        #expect(laptop == .inserted(try laptop.id()))
        #expect(try f.messages().count == 3)
    }

    @Test func reusedStanzaIDWithTwoArchiveIDsIsTwoMessages() throws {
        let f = try StoreFixture()
        // A client restarted and reused its counter; the archive holds two entries.
        let first = try f.db.upsertIncoming(
            f.fromBob("before restart", at: 0, stanzaID: "1", archiveID: "A1")
        ).id()
        let second = try f.db.upsertIncoming(
            f.fromBob("after restart", at: 3600, stanzaID: "1", archiveID: "A2"))
        #expect(second == .inserted(try second.id()))
        #expect(try second.id() != first)
        #expect(try f.messages().map(\.body) == ["before restart", "after restart"])
        // Copies without an archive id still match by stanza id.
        #expect(
            try f.db.upsertIncoming(f.fromBob("after restart", at: 3600, stanzaID: "1"))
                == .duplicate(first))
    }

    @Test func archiveIDMergesIntoStanzaIDMatch() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("old client", at: 0, stanzaID: "m42")).id()
        #expect(
            try f.db.upsertIncoming(
                f.fromBob("old client", at: 1, stanzaID: "m42", archiveID: "A42")) == .merged(id))
        #expect(try f.message(id).archiveID == "A42")
    }

    @Test func differentArchiveIDKeepsTheStoredOne() throws {
        let f = try StoreFixture()
        // The server archived a client's resend twice under one origin-id.
        let id = try f.db.upsertIncoming(f.fromBob("again", at: 0, originID: "o8", archiveID: "A1"))
            .id()
        #expect(
            try f.db.upsertIncoming(f.fromBob("again", at: 3, originID: "o8", archiveID: "A2"))
                == .duplicate(id))
        #expect(try f.message(id).archiveID == "A1")
        #expect(try f.messages().count == 1)
    }

    @Test func ownReflectionMarksPendingSentWithoutSecondRow() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "o-mine",
                senderJID: "\(StoreFixture.roomJID)/me", senderNick: "me", body: "my words",
                timestamp: StoreFixture.at(0)))
        #expect(try f.message(id).state == .pending)

        let reflection = f.inRoom(
            "my words", nick: "me", occupantID: "occ-me", at: 0.2, originID: "o-mine",
            stanzaID: "o-mine",
            archiveID: "R-mine", direction: .outgoing)
        #expect(try f.db.upsertIncoming(reflection) == .merged(id))
        #expect(try f.db.upsertIncoming(reflection) == .duplicate(id))

        let row = try f.message(id)
        #expect(row.state == .sent)
        #expect(row.archiveID == "R-mine")
        #expect(try f.messages().count == 1)
    }

    @Test func failedMessageBecomesSentWhenItsCopyArrives() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "o-late",
                senderJID: "\(StoreFixture.roomJID)/me", senderNick: "me", body: "late",
                timestamp: StoreFixture.at(0)))
        try f.db.markFailed(accountID: f.accountID, originID: "o-late", error: "Timed out")
        let reflection = f.inRoom(
            "late", nick: "me", occupantID: "occ-me", at: 1, originID: "o-late",
            archiveID: "R-late", direction: .outgoing)
        #expect(try f.db.upsertIncoming(reflection) == .merged(id))
        let row = try f.message(id)
        #expect(row.state == .sent)
        #expect(row.errorText == nil)
    }

    @Test func ownMessageNotClaimedByAnotherOccupant() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "o-mine",
                senderJID: "\(StoreFixture.roomJID)/me", senderNick: "me", body: "mine",
                timestamp: StoreFixture.at(0)))
        // Someone else repeats our origin-id: their message is theirs, and ours stays pending.
        let copycat = f.inRoom(
            "spoof", nick: "mallory", occupantID: "occ-m", at: 1, originID: "o-mine")
        let other = try f.db.upsertIncoming(copycat)
        #expect(other == .inserted(try other.id()))
        #expect(try f.message(id).state == .pending)
    }

    @Test func batchKeepsOrderAndDedupsWithinTheBatch() throws {
        let f = try StoreFixture()
        let a = f.fromBob("a", at: 0, originID: "oa", archiveID: "Aa")
        let b = f.fromBob("b", at: 1, originID: "ob", archiveID: "Ab")
        let outcomes = try f.db.upsertIncoming([a, b, a])
        #expect(outcomes.count == 3)
        let first = try outcomes[0].id()
        #expect(outcomes[0] == .inserted(first))
        #expect(outcomes[1] == .inserted(try outcomes[1].id()))
        #expect(outcomes[2] == .duplicate(first))
    }

    @Test func pageWithABadMessageStoresNothing() throws {
        let f = try StoreFixture()
        var missing = f.fromBob("lost", at: 1, originID: "o2")
        missing.chatID = 999
        #expect(throws: StoreError.chatNotFound(id: 999)) {
            try f.db.upsertIncoming([f.fromBob("good", at: 0, originID: "o1"), missing])
        }
        #expect(try f.messages().isEmpty)
        #expect(try f.chat(f.bobChatID).unreadCount == 0)
    }

    @Test func messageForAnotherAccountsChatIsRejected() throws {
        let f = try StoreFixture()
        var wrong = f.fromBob("x")
        wrong.accountID = f.otherAccountID
        #expect(throws: StoreError.chatAccountMismatch(chatID: f.bobChatID)) {
            try f.db.upsertIncoming(wrong)
        }
        var missing = f.fromBob("x")
        missing.chatID = 999
        #expect(throws: StoreError.chatNotFound(id: 999)) { try f.db.upsertIncoming(missing) }
        #expect(try f.messages().isEmpty)
    }

    @Test func incomingMessageStoresEveryField() throws {
        let f = try StoreFixture()
        let message = IncomingMessage(
            accountID: f.accountID, chatID: f.roomChatID, direction: .outgoing,
            senderJID: "room@conference.x/me",
            senderNick: "me", occupantID: "occ-me", senderRealJID: "me@x/mac", body: "all fields",
            archiveID: "R1",
            originID: "o1",
            stanzaMessageID: "s1", timestamp: StoreFixture.at(1), receivedAt: StoreFixture.at(2),
            state: .delivered,
            errorText: "e", encryption: .omemo, senderDeviceFingerprint: "fp", replyToMessageID: 42,
            replyToSenderLabel: "carol", replyQuote: "q", editedAt: StoreFixture.at(3),
            retracted: false,
            moderatedBy: "mod", moderationReason: "why", kind: .location, mentionsMe: true,
            identityChanged: true)
        let id = try f.db.upsertIncoming(message).id()
        let expected = MessageRecord(
            id: id, accountID: f.accountID, chatID: f.roomChatID, direction: .outgoing,
            senderJID: "room@conference.x/me", senderNick: "me", occupantID: "occ-me",
            body: "all fields",
            archiveID: "R1", originID: "o1", stanzaMessageID: "s1", timestamp: StoreFixture.at(1),
            receivedAt: StoreFixture.at(2), state: .delivered, errorText: "e", encryption: .omemo,
            senderDeviceFingerprint: "fp", replyToMessageID: 42, replyToSenderLabel: "carol",
            replyQuote: "q",
            editedAt: StoreFixture.at(3), retracted: false, moderatedBy: "mod",
            moderationReason: "why",
            kind: .location, mentionsMe: true, senderRealJID: "me@x/mac", identityChanged: true)
        #expect(try f.message(id) == expected)

        // The fast insert names every column but the id.
        let columns = try f.db.reader.read { try $0.columns(in: "message").map(\.name) }
        #expect(Set(columns) == Set(IncomingBatch.insertedColumns + ["id"]))
        #expect(columns.count == IncomingBatch.insertedColumns.count + 1)
    }

    @Test func emptyTextIsNotStored() throws {
        let f = try StoreFixture()
        #expect(try f.db.upsertIncoming(f.fromBob(nil, originID: "o-empty")) == .ignored)
        #expect(try f.db.upsertIncoming(f.fromBob("", originID: "o-empty")) == .ignored)
        var file = f.fromBob(nil, originID: "o-file")
        file.kind = .file
        file.attachments = [AttachmentDraft(remoteURL: "https://x/f.png", mimeType: "image/png")]
        let id = try f.db.upsertIncoming(file).id()
        #expect(try f.db.attachments(messageID: id).map(\.remoteURL) == ["https://x/f.png"])
    }

    // MARK: - Corrections (XEP-0308)

    @Test func correctionUpdatesBody() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("helo", at: 0, originID: "m1", stanzaID: "m1"))
            .id()
        var fix = f.fromBob("hello", at: 30, originID: "c1", stanzaID: "c1")
        fix.correctionOf = "m1"

        #expect(try f.db.upsertIncoming(fix) == .merged(id))
        let row = try f.message(id)
        #expect(row.body == "hello")
        #expect(row.editedAt == StoreFixture.at(30))
        #expect(try f.messages().count == 1)

        // The correction again, from MAM: nothing changes.
        var archived = fix
        archived.archiveID = "A-c1"
        #expect(try f.db.upsertIncoming(archived) == .duplicate(id))
        #expect(try f.messages().count == 1)
    }

    @Test func correctionInRoomNeedsTheSameOccupant() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(
            f.inRoom(
                "original", nick: "carol", occupantID: "occ-c", originID: "m2", stanzaID: "m2",
                archiveID: "R2")
        ).id()

        // Someone took the nick after carol left: their text is their own message.
        var hijack = f.inRoom("forged", nick: "carol", occupantID: "occ-x", at: 5, originID: "c2")
        hijack.correctionOf = "m2"
        let apart = try f.db.upsertIncoming(hijack)
        #expect(apart == .inserted(try apart.id()))
        #expect(try f.message(id).body == "original")
        #expect(try f.message(try apart.id()).body == "forged")

        // Carol herself, under a new nick.
        var real = f.inRoom("fixed", nick: "caroline", occupantID: "occ-c", at: 6, originID: "c3")
        real.correctionOf = "m2"
        #expect(try f.db.upsertIncoming(real) == .merged(id))
        #expect(try f.message(id).body == "fixed")
    }

    @Test func nickAloneNeverAuthorisesARoomEdit() throws {
        let f = try StoreFixture()
        // No occupant id and no real JID: nothing proves who wrote it.
        let id = try f.db.upsertIncoming(
            f.inRoom("one", nick: "carol", occupantID: nil, stanzaID: "m3", archiveID: "R3")
        ).id()
        var correction = f.inRoom("two", nick: "carol", occupantID: nil, at: 2, stanzaID: "c5")
        correction.correctionOf = "m3"
        let apart = try f.db.upsertIncoming(correction)
        #expect(apart == .inserted(try apart.id()))
        var retraction = f.inRoom(nil, nick: "carol", occupantID: nil, at: 3, stanzaID: "r5")
        retraction.retractionOf = "R3"
        #expect(try f.db.upsertIncoming(retraction) == .ignored)
        let row = try f.message(id)
        #expect(row.body == "one")
        #expect(row.retracted == false)
    }

    @Test func realJIDDecidesRoomEditsWithoutOccupantID() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(
            f.inRoom(
                "one", nick: "carol", occupantID: nil, realJID: "carol@x/laptop", stanzaID: "m4",
                archiveID: "R4")
        ).id()

        // Mallory took the nick: another real JID.
        var forged = f.inRoom(
            "evil", nick: "carol", occupantID: nil, realJID: "mallory@y/pc", at: 1, stanzaID: "c6")
        forged.correctionOf = "m4"
        let apart = try f.db.upsertIncoming(forged)
        #expect(apart == .inserted(try apart.id()))
        var forgedRetraction = f.inRoom(
            nil, nick: "carol", occupantID: nil, realJID: "mallory@y/pc", at: 2, stanzaID: "r6")
        forgedRetraction.retractionOf = "R4"
        #expect(try f.db.upsertIncoming(forgedRetraction) == .ignored)
        #expect(try f.message(id).body == "one")

        // Carol under another nick and from another device: the same bare real JID.
        var fix = f.inRoom(
            "two", nick: "caroline", occupantID: nil, realJID: "carol@x/phone", at: 3,
            stanzaID: "c7")
        fix.correctionOf = "m4"
        #expect(try f.db.upsertIncoming(fix) == .merged(id))
        #expect(try f.message(id).body == "two")
        var retraction = f.inRoom(
            nil, nick: "caroline", occupantID: nil, realJID: "carol@x", at: 4, stanzaID: "r7")
        retraction.retractionOf = "R4"
        #expect(
            try f.db.upsertIncoming(retraction)
                == .retracted(RemovedContent(messageID: id, localFiles: [])))
        #expect(try f.message(id).retracted)
    }

    @Test func roomEditWithMismatchedOccupantIDIsRefused() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(
            f.inRoom(
                "one", nick: "carol", occupantID: "occ-c", realJID: "carol@x", stanzaID: "m8",
                archiveID: "R8")
        ).id()
        // Same real JID claimed, but the room's occupant ids differ: the occupant id decides.
        var retraction = f.inRoom(
            nil, nick: "carol", occupantID: "occ-other", realJID: "carol@x", at: 1, stanzaID: "r8")
        retraction.retractionOf = "R8"
        #expect(try f.db.upsertIncoming(retraction) == .ignored)
        #expect(try f.message(id).retracted == false)
    }

    @Test func peerCannotCorrectOurMessage() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "mine",
                senderJID: "me@x/mac",
                body: "I said this", timestamp: StoreFixture.at(0)))
        var forged = f.fromBob("I said that", at: 1, originID: "c6")
        forged.correctionOf = "mine"
        let apart = try f.db.upsertIncoming(forged)
        #expect(apart == .inserted(try apart.id()))
        #expect(try f.message(try apart.id()).direction == .incoming)
        #expect(try f.message(id).body == "I said this")

        // Our own correction, sent from another device, applies.
        let own = IncomingMessage(
            accountID: f.accountID, chatID: f.bobChatID, direction: .outgoing,
            senderJID: "me@x/phone",
            body: "I meant this", originID: "c7", timestamp: StoreFixture.at(2),
            receivedAt: StoreFixture.at(2),
            correctionOf: "mine")
        #expect(try f.db.upsertIncoming(own) == .merged(id))
        #expect(try f.message(id).body == "I meant this")
    }

    @Test func correctionOfUnknownMessageIsStoredAsMessage() throws {
        let f = try StoreFixture()
        var fix = f.fromBob("corrected text", at: 5, originID: "c8")
        fix.correctionOf = "never-seen"
        let outcome = try f.db.upsertIncoming(fix)
        let id = try outcome.id()
        #expect(outcome == .inserted(id))
        #expect(try f.message(id).body == "corrected text")
        #expect(try f.db.upsertIncoming(fix) == .duplicate(id))
    }

    @Test func liveCorrectionBeforeCatchUpFoldsIntoOriginal() throws {
        let f = try StoreFixture()
        // Live: the correction arrives while catch-up has not reached the original yet.
        var live = f.fromBob("final text", at: 100, originID: "c9")
        live.correctionOf = "m9"
        let orphan = try f.db.upsertIncoming(live).id()

        // Catch-up brings the original, then the correction's archived copy.
        let original = try f.db.upsertIncoming(
            f.fromBob("first text", at: 10, originID: "m9", archiveID: "A9")
        ).id()
        var archived = f.fromBob("final text", at: 100, originID: "c9", archiveID: "A9c")
        archived.correctionOf = "m9"
        #expect(try f.db.upsertIncoming(archived) == .merged(original))

        let rows = try f.messages()
        #expect(rows.map(\.id) == [original])
        #expect(rows.first?.body == "final text")
        #expect(try f.db.message(id: orphan) == nil)
        // The orphan was counted unread; it no longer is.
        #expect(try f.chat(f.bobChatID).unreadCount == 1)
    }

    @Test func foldingAReadCorrectionMovesTheReadMarker() throws {
        let f = try StoreFixture()
        let earlier = try f.db.upsertIncoming(f.fromBob("earlier", at: 50, originID: "e1")).id()
        var live = f.fromBob("final text", at: 100, originID: "c9")
        live.correctionOf = "m9"
        let orphan = try f.db.upsertIncoming(live).id()
        try f.db.markRead(chatID: f.bobChatID, upTo: orphan)
        #expect(try f.chat(f.bobChatID).unreadCount == 0)

        let original = try f.db.upsertIncoming(
            f.fromBob("first text", at: 10, originID: "m9", archiveID: "A9")
        ).id()
        var archived = f.fromBob("final text", at: 100, originID: "c9", archiveID: "A9c")
        archived.correctionOf = "m9"
        #expect(try f.db.upsertIncoming(archived) == .merged(original))

        let chat = try f.chat(f.bobChatID)
        #expect(chat.lastReadMessageID == earlier)
        #expect(chat.unreadCount == 0)
    }

    @Test func plaintextCorrectionOfEncryptedMessageIsIgnored() throws {
        let f = try StoreFixture()
        var secret = f.fromBob("encrypted words", originID: "m10")
        secret.encryption = .omemo
        let id = try f.db.upsertIncoming(secret).id()
        var plain = f.fromBob("server rewrote this", at: 1, originID: "c10")
        plain.correctionOf = "m10"
        #expect(try f.db.upsertIncoming(plain) == .ignored)
        var encrypted = plain
        encrypted.encryption = .omemo
        encrypted.body = "bob rewrote this"
        #expect(try f.db.upsertIncoming(encrypted) == .merged(id))
        #expect(try f.message(id).body == "bob rewrote this")
    }

    @Test func correctionDoesNotReviveRetractedMessage() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("gone soon", originID: "m11")).id()
        var retract = f.fromBob(nil, at: 1, originID: "r11")
        retract.retractionOf = "m11"
        #expect(
            try f.db.upsertIncoming(retract)
                == .retracted(RemovedContent(messageID: id, localFiles: [])))
        var fix = f.fromBob("back again", at: 2, originID: "c11")
        fix.correctionOf = "m11"
        #expect(try f.db.upsertIncoming(fix) == .duplicate(id))
        #expect(try f.message(id).body == nil)
        #expect(try f.messages().count == 1)
    }

    // MARK: - Retractions (XEP-0424) and moderation (XEP-0425)

    @Test func retractionBlanksBody() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("oops", at: 0, originID: "m12")).id()
        var retract = f.fromBob("fallback text for old clients", at: 10, originID: "r12")
        retract.retractionOf = "m12"

        #expect(
            try f.db.upsertIncoming(retract)
                == .retracted(RemovedContent(messageID: id, localFiles: [])))
        let row = try f.message(id)
        #expect(row.body == nil)
        #expect(row.retracted)
        #expect(try f.messages().count == 1)
        #expect(try f.db.upsertIncoming(retract) == .duplicate(id))
    }

    @Test func retractionRemovesAttachmentsAndReturnsTheirFiles() throws {
        let f = try StoreFixture()
        var file = f.fromBob(nil, originID: "m20")
        file.kind = .file
        file.attachments = [
            AttachmentDraft(
                remoteURL: "aesgcm://x/secret.jpg", aesgcmKey: Data([1, 2, 3]),
                localPath: "/media/abc", state: .local),
            AttachmentDraft(remoteURL: "https://x/not-downloaded.jpg"),
        ]
        let id = try f.db.upsertIncoming(file).id()
        var retract = f.fromBob(nil, at: 1, originID: "r20")
        retract.retractionOf = "m20"

        #expect(
            try f.db.upsertIncoming(retract)
                == .retracted(RemovedContent(messageID: id, localFiles: ["/media/abc"])))
        #expect(try f.db.attachments(messageID: id).isEmpty)
        let keys = try f.db.reader.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM attachment WHERE aesgcmKey IS NOT NULL")
        }
        #expect(keys == 0)
    }

    @Test func retractionByAnotherSenderOrOfUnknownMessageIsIgnored() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(
            f.inRoom(
                "keep me", nick: "carol", occupantID: "occ-c", originID: "m13", archiveID: "R13")
        ).id()
        var forged = f.inRoom(nil, nick: "dave", occupantID: "occ-d", at: 1, originID: "r13")
        forged.retractionOf = "R13"
        #expect(try f.db.upsertIncoming(forged) == .ignored)
        #expect(try f.message(id).body == "keep me")

        var unknown = f.inRoom(nil, nick: "carol", occupantID: "occ-c", at: 2, originID: "r14")
        unknown.retractionOf = "R-unknown"
        #expect(try f.db.upsertIncoming(unknown) == .ignored)
        #expect(try f.messages().count == 1)

        // In a room the retraction names the room's stanza-id.
        var real = f.inRoom(nil, nick: "carol", occupantID: "occ-c", at: 3, originID: "r15")
        real.retractionOf = "R13"
        #expect(
            try f.db.upsertIncoming(real)
                == .retracted(RemovedContent(messageID: id, localFiles: [])))
        #expect(try f.message(id).retracted)
    }

    @Test func moderationBlanksBodyAndRecordsModerator() throws {
        let f = try StoreFixture()
        var spam = f.inRoom(
            "spam", nick: "spammer", occupantID: "occ-s", originID: "m16", archiveID: "R16")
        spam.attachments = [
            AttachmentDraft(
                remoteURL: "https://x/spam.png", localPath: "/media/spam", state: .local)
        ]
        let id = try f.db.upsertIncoming(spam).id()
        let moderated = try f.db.applyModeration(
            chatID: f.roomChatID, archiveID: "R16", moderatedBy: "\(StoreFixture.roomJID)/admin",
            reason: "Spam")
        #expect(moderated == RemovedContent(messageID: id, localFiles: ["/media/spam"]))
        #expect(try f.db.attachments(messageID: id).isEmpty)
        let row = try f.message(id)
        #expect(row.body == nil)
        #expect(row.retracted)
        #expect(row.moderatedBy == "\(StoreFixture.roomJID)/admin")
        #expect(row.moderationReason == "Spam")
        #expect(
            try f.db.applyModeration(
                chatID: f.roomChatID, archiveID: "R-none", moderatedBy: nil, reason: nil)
                == nil)
        // Moderation is a room's; a direct chat message is never moderated.
        _ = try f.db.upsertIncoming(f.fromBob("hi", archiveID: "A16"))
        #expect(
            try f.db.applyModeration(
                chatID: f.bobChatID, archiveID: "A16", moderatedBy: "bob@x", reason: nil) == nil)
    }

    // MARK: - Reactions (XEP-0444)

    @Test func reactionsReplaceSet() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(
            f.inRoom("party", nick: "carol", occupantID: "occ-c", originID: "m17", archiveID: "R17")
        ).id()
        func react(_ nick: String, _ occupant: String, _ emojis: [String], at: TimeInterval) throws
            -> UpsertOutcome
        {
            var message = f.inRoom(
                nil, nick: nick, occupantID: occupant, at: at, originID: "x\(at)")
            message.reactions = ReactionUpdate(targetID: "R17", emojis: emojis)
            return try f.db.upsertIncoming(message)
        }

        #expect(try react("dave", "occ-d", ["👍", "❤️"], at: 1) == .merged(id))
        #expect(try react("erin", "occ-e", ["👍"], at: 2) == .merged(id))
        #expect(try react("dave", "occ-d", ["😂"], at: 3) == .merged(id))
        #expect(try react("dave", "occ-d", ["😂"], at: 4) == .duplicate(id))

        var reactions = try f.db.reactions(messageID: id)
        #expect(reactions.count == 2)
        #expect(reactions.first(where: { $0.reactorKey == "occ-d" })?.emojis == ["😂"])
        #expect(reactions.first(where: { $0.reactorKey == "occ-e" })?.emojis == ["👍"])

        // An empty set removes the reactor's reactions.
        #expect(try react("dave", "occ-d", [], at: 5) == .merged(id))
        reactions = try f.db.reactions(messageID: id)
        #expect(reactions.map(\.reactorKey) == ["occ-e"])
        #expect(try f.messages().count == 1)
    }

    @Test func reactionsAreFilteredAndUnknownTargetsIgnored() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("hi", originID: "m18", stanzaID: "m18")).id()
        var message = f.fromBob(nil, at: 1, originID: "x1")
        message.reactions = ReactionUpdate(
            targetID: "m18", emojis: ["👍", "👍", "not one", " ", "🎉"])
        #expect(try f.db.upsertIncoming(message) == .merged(id))
        let reactions = try f.db.reactions(messageID: id)
        #expect(reactions.map(\.reactorKey) == [StoreFixture.bobJID])
        #expect(reactions.first?.emojis == ["👍", "🎉"])

        message.reactions = ReactionUpdate(targetID: "nope", emojis: ["👍"])
        #expect(try f.db.upsertIncoming(message) == .ignored)
    }

    @Test func reactionSetsAreCapped() throws {
        let f = try StoreFixture()
        let id = try f.db.upsertIncoming(f.fromBob("hi", originID: "m19")).id()
        var message = f.fromBob(nil, at: 1, originID: "x1")
        let many = (0..<30).compactMap {
            Unicode.Scalar(0x1F600 + $0).map { String(Character($0)) }
        }
        message.reactions = ReactionUpdate(targetID: "m19", emojis: many)
        #expect(try f.db.upsertIncoming(message) == .merged(id))
        #expect(try f.db.reactions(messageID: id).first?.emojis == Array(many.prefix(20)))
    }

    // MARK: - Looking a copy up without storing (OMEMO decrypts only what is new)

    @Test func storedCopyFindsWhatUpsertWouldTakeAsACopy() throws {
        let f = try StoreFixture()
        #expect(try f.db.storedCopy(of: f.fromBob(nil, originID: "o1")) == nil)
        let id = try f.db.upsertIncoming(
            f.fromBob("hi", at: 0, originID: "o1", stanzaID: "s1", archiveID: "A1")
        ).id()
        let chatBefore = try f.chat(f.bobChatID)

        // The body plays no part: the copy is found before anything is decrypted.
        #expect(try f.db.storedCopy(of: f.fromBob(nil, at: 5, originID: "o1"))?.id == id)
        #expect(try f.db.storedCopy(of: f.fromBob(nil, at: 5, archiveID: "A1"))?.id == id)
        #expect(try f.db.storedCopy(of: f.fromBob(nil, at: 60, stanzaID: "s1"))?.id == id)
        // Rule 3 needs the same full JID and 24 hours at most.
        #expect(
            try f.db.storedCopy(of: f.fromBob(nil, at: 60, stanzaID: "s1", resource: "pc")) == nil)
        #expect(try f.db.storedCopy(of: f.fromBob(nil, at: 90_000, stanzaID: "s1")) == nil)
        // Rule 2 needs the same sender.
        var stranger = f.fromBob(nil, originID: "o1")
        stranger.senderJID = "eve@x/phone"
        #expect(try f.db.storedCopy(of: stranger) == nil)
        // Nothing was written.
        #expect(try f.messages().count == 1)
        #expect(try f.chat(f.bobChatID) == chatBefore)
    }

    @Test func storedCopyFindsOurOwnPendingMessage() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.roomChatID, originID: "mine",
                senderJID: "me@x/mac", senderNick: "me", body: "secret",
                timestamp: StoreFixture.at(0), encryption: .omemo))
        // The room's reflection of it, as a copy of ours.
        let reflection = f.inRoom(
            nil, nick: "me", occupantID: nil, at: 1, originID: "mine", stanzaID: "mine",
            archiveID: "R1", direction: .outgoing)
        let copy = try #require(try f.db.storedCopy(of: reflection))
        #expect(copy.id == id)
        #expect(copy.body == "secret")
        #expect(copy.encryption == .omemo)
        // Someone else's message with the same origin-id is no copy of ours.
        #expect(
            try f.db.storedCopy(
                of: f.inRoom(nil, nick: "eve", occupantID: nil, at: 1, originID: "mine")) == nil)
    }

    // MARK: - OMEMO notices and encrypted rows

    @Test func anOMEMONoticeBecomesTheMessageALaterCopyDecryptedTo() throws {
        let f = try StoreFixture()
        var notice = f.fromBob("Cannot decrypt", at: 0, originID: "n1")
        notice.kind = .system
        notice.encryption = .omemo
        let id = try f.db.upsertIncoming(notice).id()
        #expect(try f.chat(f.bobChatID).unreadCount == 0)

        let upgraded = try f.db.upgradeOMEMONotice(
            messageID: id, body: "the text", kind: .file, senderDeviceFingerprint: "ab cd",
            attachments: [AttachmentDraft(remoteURL: "aesgcm://x/y#z", state: .remote)])
        #expect(upgraded)
        let row = try f.message(id)
        #expect(row.body == "the text")
        #expect(row.kind == .file)
        #expect(row.encryption == .omemo)
        #expect(row.senderDeviceFingerprint == "ab cd")
        #expect(try f.db.attachments(messageID: id).map(\.remoteURL) == ["aesgcm://x/y#z"])
        // A message now: it counts as unread, and turns up in search.
        #expect(try f.chat(f.bobChatID).unreadCount == 1)
        #expect(try f.db.search("text").map(\.messageID) == [id])

        // Only ever that way: a message, or a notice in the clear, is never changed.
        #expect(
            try !f.db.upgradeOMEMONotice(
                messageID: id, body: "other", kind: .text, senderDeviceFingerprint: nil,
                attachments: []))
        var plainNotice = f.fromBob("joined", at: 1, originID: "n2")
        plainNotice.kind = .system
        let plainID = try f.db.upsertIncoming(plainNotice).id()
        #expect(
            try !f.db.upgradeOMEMONotice(
                messageID: plainID, body: "forged", kind: .text, senderDeviceFingerprint: nil,
                attachments: []))
        #expect(try f.message(plainID).body == "joined")
    }

    /// A notice kept because the sending device's identity key changed is never turned into
    /// a message: its later copies carry the same unchecked key.
    @Test func aNoticeOfAChangedIdentityStaysANotice() throws {
        let f = try StoreFixture()
        var notice = f.fromBob("Cannot decrypt", at: 0, originID: "n1")
        notice.kind = .system
        notice.encryption = .omemo
        notice.identityChanged = true
        let id = try f.db.upsertIncoming(notice).id()
        #expect(try f.message(id).identityChanged)
        #expect(
            try !f.db.upgradeOMEMONotice(
                messageID: id, body: "forged", kind: .text, senderDeviceFingerprint: "ab cd",
                attachments: []))
        #expect(try f.message(id).body == "Cannot decrypt")
        #expect(try f.message(id).kind == .system)
    }

    /// R54: a chat holds a message of ours once one was sent in it, from this device or
    /// another; nothing the contact sends counts.
    @Test func aChatHoldsOurMessageOnlyOnceWeSentOne() throws {
        let f = try StoreFixture()
        _ = try f.db.upsertIncoming(f.fromBob("hello", at: 0, originID: "b1"))
        #expect(try !f.db.hasOutgoingMessage(chatID: f.bobChatID))
        _ = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "q1", senderJID: "me@x/mac",
                body: "hi", timestamp: StoreFixture.at(1)))
        #expect(try f.db.hasOutgoingMessage(chatID: f.bobChatID))
    }

    @Test func aQueuedMessageIsMarkedEncryptedWhenItGoesOutSo() throws {
        let f = try StoreFixture()
        let id = try f.db.insertOutgoing(
            OutgoingMessage(
                accountID: f.accountID, chatID: f.bobChatID, originID: "q1", senderJID: "me@x/mac",
                body: "queued", timestamp: StoreFixture.at(0)))
        #expect(try f.message(id).encryption == .none)
        try f.db.markEncrypted(messageID: id)
        #expect(try f.message(id).encryption == .omemo)
    }
}
