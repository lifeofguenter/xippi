import GRDB

extension AppDatabase {
    /// Past migrations are never edited; schema changes add a new migration.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE account (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        jid TEXT NOT NULL UNIQUE,
                        enabled BOOLEAN NOT NULL,
                        resource TEXT NOT NULL,
                        clientID TEXT NOT NULL,
                        hostOverride TEXT,
                        portOverride INTEGER,
                        directTLSOverride BOOLEAN,
                        pinnedCertSHA256 TEXT NOT NULL,
                        rosterVersion TEXT,
                        smResume BLOB,
                        createdAt DATETIME NOT NULL
                    );

                    CREATE TABLE rosterItem (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        jid TEXT NOT NULL,
                        name TEXT,
                        subscription TEXT NOT NULL,
                        ask TEXT,
                        approved BOOLEAN NOT NULL,
                        groups TEXT NOT NULL,
                        UNIQUE (accountID, jid)
                    );

                    CREATE TABLE chat (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        jid TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        name TEXT,
                        pinned BOOLEAN NOT NULL,
                        muted BOOLEAN NOT NULL,
                        notify TEXT NOT NULL,
                        draft TEXT,
                        encryption TEXT NOT NULL,
                        nick TEXT,
                        password TEXT,
                        autojoin BOOLEAN NOT NULL,
                        lastActivity DATETIME,
                        unreadCount INTEGER NOT NULL,
                        mentionCount INTEGER NOT NULL,
                        lastReadMessageID INTEGER,
                        avatarHash TEXT,
                        UNIQUE (accountID, jid)
                    );

                    CREATE TABLE message (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        chatID INTEGER NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
                        direction TEXT NOT NULL,
                        senderJID TEXT,
                        senderNick TEXT,
                        occupantID TEXT,
                        body TEXT,
                        archiveID TEXT,
                        originID TEXT,
                        stanzaMessageID TEXT,
                        timestamp DATETIME NOT NULL,
                        receivedAt DATETIME NOT NULL,
                        state TEXT NOT NULL,
                        errorText TEXT,
                        encryption TEXT NOT NULL,
                        senderDeviceFingerprint TEXT,
                        replyToMessageID INTEGER,
                        replyToSenderLabel TEXT,
                        replyQuote TEXT,
                        editedAt DATETIME,
                        retracted BOOLEAN NOT NULL,
                        moderatedBy TEXT,
                        moderationReason TEXT,
                        kind TEXT NOT NULL
                    );
                    CREATE INDEX message_chat_timestamp ON message(chatID, timestamp);
                    CREATE UNIQUE INDEX message_archive ON message(accountID, chatID, archiveID)
                        WHERE archiveID IS NOT NULL;
                    CREATE INDEX message_origin ON message(accountID, chatID, originID, senderJID);
                    CREATE INDEX message_stanza ON message(accountID, chatID, stanzaMessageID, senderJID);

                    CREATE TABLE reaction (
                        messageID INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                        reactorKey TEXT NOT NULL,
                        emojis TEXT NOT NULL,
                        PRIMARY KEY (messageID, reactorKey)
                    );

                    CREATE TABLE attachment (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        messageID INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                        remoteURL TEXT,
                        aesgcmKey BLOB,
                        localPath TEXT,
                        mimeType TEXT,
                        byteSize INTEGER,
                        fileName TEXT,
                        width INTEGER,
                        height INTEGER,
                        durationSeconds DOUBLE,
                        state TEXT NOT NULL
                    );
                    CREATE INDEX attachment_message ON attachment(messageID);

                    CREATE TABLE mamRange (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        archiveJID TEXT NOT NULL,
                        startArchiveID TEXT NOT NULL,
                        endArchiveID TEXT NOT NULL,
                        startTime DATETIME,
                        endTime DATETIME
                    );
                    CREATE INDEX mamRange_archive ON mamRange(accountID, archiveJID);

                    CREATE TABLE caps (
                        verification TEXT PRIMARY KEY,
                        features TEXT NOT NULL,
                        identities BLOB NOT NULL
                    );

                    CREATE TABLE avatar (
                        hash TEXT PRIMARY KEY,
                        fileName TEXT NOT NULL,
                        byteSize INTEGER NOT NULL
                    );

                    CREATE TABLE profile (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        jid TEXT NOT NULL,
                        fullName TEXT,
                        nickname TEXT,
                        data BLOB NOT NULL,
                        PRIMARY KEY (accountID, jid)
                    );

                    CREATE TABLE bookmark (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        roomJID TEXT NOT NULL,
                        name TEXT,
                        autojoin BOOLEAN NOT NULL,
                        nick TEXT,
                        password TEXT,
                        PRIMARY KEY (accountID, roomJID)
                    );

                    CREATE TABLE omemoAccount (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        version TEXT NOT NULL,
                        deviceID INTEGER NOT NULL,
                        identityPrivate BLOB NOT NULL,
                        identityPublic BLOB NOT NULL,
                        registrationID INTEGER,
                        signedPreKeyID INTEGER NOT NULL,
                        nextPreKeyID INTEGER NOT NULL,
                        PRIMARY KEY (accountID, version)
                    );

                    CREATE TABLE omemoDevice (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        jid TEXT NOT NULL,
                        version TEXT NOT NULL,
                        deviceID INTEGER NOT NULL,
                        label TEXT,
                        active BOOLEAN NOT NULL,
                        lastSeen DATETIME,
                        identityKey BLOB,
                        trust TEXT NOT NULL,
                        PRIMARY KEY (accountID, jid, version, deviceID)
                    );

                    CREATE TABLE omemoSession (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        jid TEXT NOT NULL,
                        version TEXT NOT NULL,
                        deviceID INTEGER NOT NULL,
                        state BLOB NOT NULL,
                        PRIMARY KEY (accountID, jid, version, deviceID)
                    );

                    CREATE TABLE omemoPreKey (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        version TEXT NOT NULL,
                        keyID INTEGER NOT NULL,
                        privateKey BLOB NOT NULL,
                        publicKey BLOB NOT NULL,
                        PRIMARY KEY (accountID, version, keyID)
                    );

                    CREATE TABLE omemoSignedPreKey (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        version TEXT NOT NULL,
                        keyID INTEGER NOT NULL,
                        privateKey BLOB NOT NULL,
                        publicKey BLOB NOT NULL,
                        signature BLOB NOT NULL,
                        createdAt DATETIME NOT NULL,
                        PRIMARY KEY (accountID, version, keyID)
                    );
                    """)

            // External-content full-text index over message bodies, kept in sync by triggers.
            try db.create(virtualTable: "messageFTS", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("body")
            }
        }
        migrator.registerMigration("v2") { db in
            // 1. Search. unicode61 removes accents but keeps letters such as ß, æ, ø and ł, so
            //    "grusse" could not find "Grüße". The index now holds each body with those letters
            //    spelled out (`SearchText` folds queries the same way). It is contentless: the text
            //    lives in `message` only, and the triggers fire only when a body changes.
            // 2. `mentionsMe`, so marking a chat read can recount its mentions exactly, and
            //    `senderRealJID`, the occupant's real JID in rooms that show it: without an
            //    occupant id it is what proves who may correct or retract a room message.
            // 3. Partial indexes for the outbox: pending messages per account, our own messages by
            //    origin-id (acks and errors name the origin-id only, not the chat), and our messages
            //    not yet displayed per chat (a displayed marker covers every earlier one).
            let fold = { (expression: String) in
                v2SearchFoldings.reduce(expression) { folded, pair in
                    "replace(\(folded), '\(pair.letter)', '\(pair.replacement)')"
                }
            }
            try db.execute(
                sql: """
                    DROP TRIGGER IF EXISTS "__messageFTS_ai";
                    DROP TRIGGER IF EXISTS "__messageFTS_ad";
                    DROP TRIGGER IF EXISTS "__messageFTS_au";
                    DROP TABLE messageFTS;
                    CREATE VIRTUAL TABLE messageFTS USING fts5(
                        body, content = '', contentless_delete = 1,
                        tokenize = 'unicode61 remove_diacritics 2');
                    CREATE TRIGGER messageFTS_insert AFTER INSERT ON message WHEN new.body IS NOT NULL BEGIN
                        INSERT INTO messageFTS (rowid, body) VALUES (new.id, \(fold("new.body")));
                    END;
                    CREATE TRIGGER messageFTS_delete AFTER DELETE ON message BEGIN
                        DELETE FROM messageFTS WHERE rowid = old.id;
                    END;
                    CREATE TRIGGER messageFTS_update AFTER UPDATE OF body ON message BEGIN
                        DELETE FROM messageFTS WHERE rowid = old.id;
                        INSERT INTO messageFTS (rowid, body)
                            SELECT new.id, \(fold("new.body")) WHERE new.body IS NOT NULL;
                    END;
                    INSERT INTO messageFTS (rowid, body)
                        SELECT id, \(fold("body")) FROM message WHERE body IS NOT NULL;

                    ALTER TABLE message ADD COLUMN mentionsMe BOOLEAN NOT NULL DEFAULT 0;
                    ALTER TABLE message ADD COLUMN senderRealJID TEXT;

                    CREATE INDEX message_pending ON message(accountID, timestamp) WHERE state = 'pending';
                    CREATE INDEX message_outgoing_origin ON message(accountID, originID)
                        WHERE direction = 'outgoing';
                    CREATE INDEX message_unsettled ON message(chatID, timestamp)
                        WHERE direction = 'outgoing' AND state IN ('pending', 'sent', 'delivered');
                    """)
        }
        migrator.registerMigration("v3") { db in
            // File transfers (Task 13): upload and download progress on the attachment row, the
            // type the file's bytes show beside the declared one, and why a transfer failed.
            // Files are kept once per content hash, so a file is deleted only when no row names
            // it any more: `attachment_localPath` answers that.
            try db.execute(
                sql: """
                    ALTER TABLE attachment ADD COLUMN progress DOUBLE;
                    ALTER TABLE attachment ADD COLUMN sniffedMimeType TEXT;
                    ALTER TABLE attachment ADD COLUMN errorText TEXT;
                    CREATE INDEX attachment_localPath ON attachment(localPath)
                        WHERE localPath IS NOT NULL;
                    CREATE INDEX attachment_transfer ON attachment(state)
                        WHERE state IN ('uploading', 'downloading');
                    """)
        }
        migrator.registerMigration("v4") { db in
            // Bookmark changes made here and not yet on the server (Task 12): `pending` until a
            // publish of the row succeeds, `removed` for a room the user left, kept until the
            // server retracted its bookmark. A fetch never overwrites a pending row.
            try db.execute(
                sql: """
                    ALTER TABLE bookmark ADD COLUMN pending BOOLEAN NOT NULL DEFAULT 0;
                    ALTER TABLE bookmark ADD COLUMN removed BOOLEAN NOT NULL DEFAULT 0;
                    """)
        }
        migrator.registerMigration("v5") { db in
            // What the database knows about itself, one row (Task 13, R50): the id of the
            // media library it belongs to, which the library keeps in a marker file too. The
            // library's orphan sweep runs only while the two match. Library files are matched
            // by their name (the last 64 characters of `localPath`), never the whole path, so a
            // moved home folder deletes nothing: `attachment_fileName` answers that.
            try db.execute(
                sql: """
                    CREATE TABLE storeSettings (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        mediaLibraryID TEXT
                    );
                    CREATE INDEX attachment_fileName ON attachment(substr(localPath, -65))
                        WHERE localPath IS NOT NULL;
                    """)
        }
        migrator.registerMigration("v6") { db in
            // OMEMO (Task 17b). `identityChanged`: the sending device came with another
            // identity key than the one known for it. Set on the message read under the new
            // key, and on the notice kept for a copy that is not live under one; such a notice
            // is never upgraded. `omemoPending`: OMEMO messages that came while the session
            // could not decrypt (it waited for the store's lease, R53), as they came, read in
            // arrival order once it can.
            try db.execute(
                sql: """
                    ALTER TABLE message ADD COLUMN identityChanged BOOLEAN NOT NULL DEFAULT 0;
                    CREATE TABLE omemoPending (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        stanza TEXT NOT NULL,
                        carbon TEXT,
                        receivedAt DATETIME NOT NULL
                    );
                    CREATE INDEX omemoPending_account ON omemoPending(accountID, id);
                    """)
        }
        migrator.registerMigration("v7") { db in
            // Account settings (Task 26a). `account.priority`: the presence priority the user
            // set. `rosterItem.avatarHash` and `profile.avatarHash`: the avatar shown for a
            // contact and for the account itself, so an avatar file is kept while a roster row,
            // a chat or the account's own profile names it, also when no session runs.
            // `storeSettings.groupNotify`: the notification level new group chats start with.
            try db.execute(
                sql: """
                    ALTER TABLE account ADD COLUMN priority INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE rosterItem ADD COLUMN avatarHash TEXT;
                    ALTER TABLE profile ADD COLUMN avatarHash TEXT;
                    ALTER TABLE storeSettings ADD COLUMN groupNotify TEXT;
                    """)
        }
        migrator.registerMigration("v8") { db in
            // The inspector's shared media (Task 24): a chat's file messages, newest first,
            // read from this partial index instead of scanning the chat.
            try db.execute(
                sql: """
                    CREATE INDEX message_chat_files ON message(chatID, timestamp, id)
                    WHERE kind = 'file' AND retracted = 0;
                    """)
        }
        migrator.registerMigration("v9") { db in
            // Task 23b, ruling R63. `chat.encryptionSettled`: whether a direct chat's encryption
            // default (OMEMO when the contact publishes devices) was set, or the user or an OMEMO
            // message chose first. Chats from before keep what they have; new ones wait (the
            // column's default), and any change of `encryption` settles them.
            // A file message whose body is only its attachment's link loses the body: the link
            // (an `aesgcm://` one carries the file's key) stays on the attachment, and the
            // update trigger takes it out of the search index.
            try db.execute(
                sql: """
                    ALTER TABLE chat ADD COLUMN encryptionSettled BOOLEAN NOT NULL DEFAULT 0;
                    UPDATE chat SET encryptionSettled = 1;
                    CREATE TRIGGER chat_encryptionChosen AFTER UPDATE OF encryption ON chat
                    WHEN old.encryption IS NOT new.encryption BEGIN
                        UPDATE chat SET encryptionSettled = 1 WHERE id = new.id;
                    END;
                    UPDATE message SET body = NULL
                    WHERE kind = 'file' AND body IS NOT NULL AND EXISTS (
                        SELECT 1 FROM attachment
                        WHERE attachment.messageID = message.id
                            AND attachment.remoteURL = trim(message.body, ' ' || char(9, 10, 13)));
                    """)
        }
        migrator.registerMigration("v10") { db in
            // Ruling R65: kept OMEMO messages count against their sender's share (`sender`, the
            // bare JID), and a full store makes room from senders not known first
            // (`senderKnown`). Rows from before count as one unknown sender's.
            try db.execute(
                sql: """
                    ALTER TABLE omemoPending ADD COLUMN sender TEXT NOT NULL DEFAULT '';
                    ALTER TABLE omemoPending ADD COLUMN senderKnown BOOLEAN NOT NULL DEFAULT 0;
                    CREATE INDEX omemoPending_sender ON omemoPending(accountID, sender);
                    """)
        }
        migrator.registerMigration("v11") { db in
            // Task 23b. Only a choice settles a chat's encryption default (I10): the write that
            // makes it does so itself, so the trigger that took any change for one goes.
            // Rows v9 left (M20): a body that is only its attachment's link, whatever its kind
            // (whitespace around it once made it text), becomes a file without a body; and a
            // reply quote that is only an `aesgcm://` link (with its key) goes.
            try db.execute(
                sql: """
                    DROP TRIGGER IF EXISTS chat_encryptionChosen;
                    UPDATE message SET body = NULL, kind = 'file'
                    WHERE body IS NOT NULL AND EXISTS (
                        SELECT 1 FROM attachment
                        WHERE attachment.messageID = message.id
                            AND attachment.remoteURL = trim(message.body, ' ' || char(9, 10, 13)));
                    UPDATE message SET replyQuote = NULL
                    WHERE replyQuote IS NOT NULL
                        AND lower(trim(replyQuote, ' ' || char(9, 10, 13))) LIKE 'aesgcm://%'
                        AND instr(trim(replyQuote, ' ' || char(9, 10, 13)), ' ') = 0
                        AND instr(trim(replyQuote, ' ' || char(9, 10, 13)), char(10)) = 0
                        AND instr(trim(replyQuote, ' ' || char(9, 10, 13)), char(9)) = 0;
                    """)
        }
        migrator.registerMigration("v12") { db in
            // Ruling R72: participants the user blocked in rooms and channels, ignored on this
            // Mac. `room` is the room or channel (bare JID), empty for a real JID, which counts
            // everywhere; `kind` is realJID, occupantID, participantID or nick.
            try db.execute(
                sql: """
                    CREATE TABLE ignoredParticipant (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        room TEXT,
                        kind TEXT NOT NULL,
                        value TEXT NOT NULL,
                        label TEXT NOT NULL,
                        createdAt DATETIME NOT NULL
                    );
                    CREATE UNIQUE INDEX ignoredParticipant_entry
                        ON ignoredParticipant(accountID, ifnull(room, ''), kind, value);
                    -- A message of someone ignored, stored before they were: left out of the
                    -- chat list, search, shared media and the counts.
                    ALTER TABLE message ADD COLUMN hidden BOOLEAN NOT NULL DEFAULT 0;
                    CREATE INDEX message_hidden ON message(chatID) WHERE hidden;
                    -- What an ignore change looks up: by occupant id in a room, by real JID.
                    CREATE INDEX message_chat_occupant ON message(chatID, occupantID)
                        WHERE occupantID IS NOT NULL;
                    CREATE INDEX message_realjid ON message(senderRealJID)
                        WHERE senderRealJID IS NOT NULL;
                    -- A channel's participant address: room and channel rows without an
                    -- occupant id, from someone else.
                    CREATE INDEX message_chat_sender ON message(chatID, senderJID)
                        WHERE senderNick IS NOT NULL AND occupantID IS NULL
                            AND direction = 'incoming';
                    -- The real JID a room or channel showed for an occupant id or participant
                    -- id, so a real JID can be matched where only the id is stamped.
                    CREATE TABLE occupantIdentity (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        room TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        value TEXT NOT NULL,
                        realJID TEXT NOT NULL,
                        seenAt DATETIME NOT NULL
                    );
                    CREATE UNIQUE INDEX occupantIdentity_id
                        ON occupantIdentity(accountID, room, kind, value);
                    CREATE INDEX occupantIdentity_realJID ON occupantIdentity(accountID, realJID);
                    """)
        }
        migrator.registerMigration("v13") { db in
            // A chat the user closed, out of the list until it opens again; and the background
            // chosen for a chat (NULL: the app's default).
            try db.execute(
                sql: """
                    ALTER TABLE chat ADD COLUMN closed BOOLEAN NOT NULL DEFAULT 0;
                    ALTER TABLE chat ADD COLUMN background TEXT;
                    """)
        }
        migrator.registerMigration("v14") { db in
            // The avatar each room occupant's presence names, by nick: shown in the member
            // list and on the room's messages, and kept by the avatar cleanup while named.
            try db.execute(
                sql: """
                    CREATE TABLE occupantAvatar (
                        accountID INTEGER NOT NULL REFERENCES account(id) ON DELETE CASCADE,
                        room TEXT NOT NULL,
                        nick TEXT NOT NULL,
                        hash TEXT NOT NULL,
                        PRIMARY KEY (accountID, room, nick)
                    );
                    """)
        }
        migrator.registerMigration("v15") { db in
            // A message corrected to blank text was taken back by its sender; it was stored as
            // an edit to nothing and showed as an empty bubble. Its files go with the next sweep.
            let edited = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, body FROM message
                    WHERE editedAt IS NOT NULL AND retracted = 0 AND body IS NOT NULL
                    """)
            for row in edited {
                let body: String = row["body"]
                guard body.isBlank else { continue }
                _ = try AppDatabase.removeContent(
                    db, messageID: row["id"], moderatedBy: nil, reason: nil)
            }
        }
        return migrator
    }

    /// The letters the v2 search index spells out. Frozen with migration v2: a change needs a new
    /// migration that rebuilds the index, and the same change in `SearchText.foldings`.
    private static let v2SearchFoldings: [(letter: String, replacement: String)] = [
        ("ß", "ss"), ("ẞ", "ss"), ("æ", "ae"), ("Æ", "ae"), ("œ", "oe"), ("Œ", "oe"),
        ("ø", "o"), ("Ø", "o"), ("ł", "l"), ("Ł", "l"), ("đ", "d"), ("Đ", "d"),
        ("ð", "d"), ("Ð", "d"), ("þ", "th"), ("Þ", "th"),
    ]
}
