"""Mutation checks for the OMEMO engine's tests (test tooling, never shipped).

Each mutation breaks one rule in Packages/OMEMO/Sources/OMEMO/XMPP on purpose, runs the engine
suites, and restores the file. A mutation must make at least one test fail; one that leaves
every test passing, does not build, or no longer matches the source is reported and makes the
script exit with status 1.

    python3 -I scripts/omemo-mutations/mutate.py --copy DIR            # every mutation
    python3 -I scripts/omemo-mutations/mutate.py --copy DIR heartbeat  # names with a word

Mutants are never written into the shared working tree, which others build from: the
packages are copied into DIR (`--copy`, outside the repository, e.g. a scratch directory) and
mutated and built there. The copy keeps its own build products between runs.

The sources must be formatted (swift format -i) for the patterns to match.
"""

import pathlib
import re
import subprocess
import sys

# The shared working tree: read from, never mutated.
SHARED = pathlib.Path(__file__).resolve().parents[2]
# The copy mutated and built (`--copy`), set by `use_copy`.
ROOT = SHARED
SOURCES = ROOT / "Packages/OMEMO/Sources/OMEMO/XMPP"


def use_copy(argv: list[str]) -> list[str]:
    """Copies the shared packages into the directory `--copy` names and points the harness at
    the copy; returns the other arguments. Refuses to run on the shared tree."""
    global ROOT, SOURCES
    if "--copy" not in argv or argv.index("--copy") + 1 >= len(argv):
        sys.exit("Mutants are never written to the shared tree: pass --copy DIR")
    index = argv.index("--copy")
    copy = pathlib.Path(argv[index + 1]).expanduser().resolve()
    if copy == SHARED or SHARED in copy.parents:
        sys.exit(f"--copy must be outside the repository: {copy}")
    (copy / "Packages").mkdir(parents=True, exist_ok=True)
    # The sources as they are now; the copy's own build products stay.
    subprocess.run(
        ["rsync", "-a", "--delete", "--exclude", ".build", "--exclude", ".swiftpm",
         f"{SHARED / 'Packages'}/", f"{copy / 'Packages'}/"],
        check=True,
    )
    ROOT = copy
    SOURCES = ROOT / "Packages/OMEMO/Sources/OMEMO/XMPP"
    return argv[:index] + argv[index + 2:]
FILTER = "EngineTests|RecordedStanzaTests|EngineFixRoundTests|EngineIdentityTrustTests|EngineStoreFailureTests|EngineHostileListTests|EngineDistrustedSenderTests"

ENGINE = "OMEMOEngine.swift"
ENCRYPT = "OMEMOEngine+Encrypt.swift"
DECRYPT = "OMEMOEngine+Decrypt.swift"
TRUST = "TrustPolicy.swift"

# (name, [(file, old, new), ...]): every replacement of a mutation is applied together.
MUTATIONS = [
    ("no engine lock", [(ENGINE, """        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }""", "        busy = false")]),
    ("BTBV off: new devices always trusted", [
        (TRUST, "known.contains { $0.trust == .verified } ? .undecided : .trusted", ".trusted")]),
    ("undecided devices get keys", [(TRUST, """        case .trusted, .verified: true
        case .undecided, .distrusted: false""", """        case .trusted, .verified, .undecided: true
        case .distrusted: false""")]),
    ("unlisted devices get keys (all three filters)", [
        (TRUST, "device.active && device.trust.receivesKeys", "device.trust.receivesKeys"),
        (ENCRYPT, ".filter { $0.active && !(jid == accountJID", ".filter { !(jid == accountJID"),
        (ENCRYPT, "where device.active && !(jid == accountJID && device.deviceID == own.deviceID)",
         "where !(jid == accountJID && device.deviceID == own.deviceID)"),
    ]),
    ("heartbeat at counter 52", [
        (ENGINE, "heartbeatCounter: UInt32 = 53", "heartbeatCounter: UInt32 = 52")]),
    ("heartbeat on every message past 53", [
        (DECRYPT, "            && session.heartbeatRatchetKey != opened.header.ratchetKey\n",
         "            && true\n")]),
    ("no repair rate limit", [
        (DECRYPT, "now().timeIntervalSince(last) < Self.repairInterval",
         "now().timeIntervalSince(last) < 0")]),
    ("automatic repair in OMEMO 2 too", [
        (DECRYPT, "            if version == .v03,\n                try await shouldRepair(",
         "            if version == .v03 || version == .v2,\n                try await shouldRepair(")]),
    ("no automatic repair at all", [
        (DECRYPT, "            if version == .v03,\n                try await shouldRepair(",
         "            if version == .v2,\n                try await shouldRepair(")]),
    ("repair after one authentication failure", [
        (ENGINE, "brokenSessionFailures = 2", "brokenSessionFailures = 1")]),
    ("replaceSessions ignores distrust", [
        (DECRYPT, "        guard device.trust != .distrusted else { return nil }\n        let now = now()",
         "        let now = now()")]),
    ("replaceSessions skips the list refresh", [
        (DECRYPT, "if let element = try? await transport.fetchDeviceList(of: jid, version: version),",
         "if let element = try? await transport.fetchDeviceList(of: jid, version: version),\n"
         "                element.name == \"x\",")]),
    ("pre key not consumed", [
        (ENGINE, "            state, with: device, consumingPreKey: consumed, version: version)",
         "            state, with: device, version: version); _ = consumed")]),
    ("refill at 79 instead of below 80", [
        (ENGINE, "guard existing.count < Self.preKeyRefillThreshold else",
         "guard existing.count < Self.preKeyRefillThreshold - 1 else")]),
    ("no bundle after a pre key is used", [
        (DECRYPT, "            result.bundleToPublish = try await bundleElement(version: version)\n", "")]),
    ("state stored before the payload is read", [
        (DECRYPT, """            if case .failed = content {
                result.content = content
                return result
            }""", "")]),
    ("SCE affixes not checked", [
        (DECRYPT, "                try envelope.verify(sender: sender, recipient: recipient)\n", "")]),
    ("server elements kept in <content/> on receive", [
        ("SCE.swift", "!SCE.serverProcessedNamespaces.contains(namespace)", "!namespace.isEmpty")]),
    ("server elements kept in <content/> on send", [
        (ENCRYPT, "!SCE.serverProcessedNamespaces.contains($0.namespace ?? \"\")",
         "!($0.namespace ?? \"\").isEmpty")]),
    ("no <rpad/>", [
        (ENCRYPT, "padding: SCE.randomPadding(contentLength: unpadded.element.xml().utf8.count),",
         "padding: unpadded.padding,")]),
    ("replaced signed pre key deleted at once", [
        (ENGINE, "if now.timeIntervalSince(ordered[index + 1].createdAt) > Self.signedPreKeyRetention {",
         "if now.timeIntervalSince(ordered[index + 1].createdAt) >= 0 {")]),
    ("signed pre key never rotated", [
        (ENGINE, "now.timeIntervalSince($0.createdAt) >= Self.signedPreKeyLifetime",
         "now.timeIntervalSince($0.createdAt) < 0")]),
    ("pending key exchange never cleared", [
        (DECRYPT, "            state.pendingKeyExchange = nil\n", "")]),
    ("repeated key exchange builds a new session", [
        (DECRYPT, "$0.remoteEphemeralKey == exchange.ephemeralKey",
         "$0.remoteEphemeralKey == Data([1])")]),
    ("replaced sessions not tried", [
        (DECRYPT, "for index in 0...stored.previous.count {", "for index in 0...0 {")]),
    ("replaced session not made current", [
        (DECRYPT, "session = stored.promoting(index - 1, as: state)",
         "session.previous[index - 1] = state")]),
    ("own other devices not encrypted for", [
        (ENCRYPT, "                    of: accountJID, own: own, version: version, required: ownRequired)))",
         "                    of: try JID(\"nobody@example.org\"), own: own, version: version,\n"
         "                    required: ownRequired)))")]),
    ("own reflection not recognised", [
        (DECRYPT, "if sender == accountJID, parsed.senderDeviceID == own.deviceID {",
         "if sender == accountJID, parsed.senderDeviceID == 0 {")]),
    ("missing key reported as a failure", [
        (DECRYPT, "result.content = parsed.payload == nil ? .empty : .notForThisDevice",
         "result.content = .failed(.noSession)")]),
    ("room check || instead of &&", [
        (ENCRYPT, "guard room.isNonAnonymous, room.isMembersOnly else",
         "guard room.isNonAnonymous || room.isMembersOnly else")]),
    ("no session completion reply", [
        (DECRYPT, "if opened.isNewSession { reason = .sessionCompletion }", "")]),
    ("repair after a malformed message", [
        (DECRYPT, "        case .malformed, .invalidPayload, .envelopeRejected, .identityChanged, .notReadable:\n            return false",
         "        case .malformed, .invalidPayload, .envelopeRejected, .identityChanged, .notReadable:\n            return true")]),
    ("duplicate reported as a failure", [
        (DECRYPT, "        } catch .duplicateMessage {\n            return .failure(Refused(outcome: .duplicate))\n",
         "")]),
    ("listed device id not avoided", [
        (ENGINE, "if (1...maxDeviceID).contains(id), !taken.contains(id) { return id }",
         "if (1...maxDeviceID).contains(id) { return id }")]),
    ("legacy fingerprint keeps 0x05", [
        (ENGINE, "if identityKey.count == 33, identityKey.first == OMEMOVersion.curve25519KeyType {",
         "if identityKey.count == 1 {")]),
    ("OMEMO 2 fingerprint in the Ed25519 form", [
        (ENGINE, "let converted = try? KeyConversion.montgomeryPublic(fromEdwards: identityKey)",
         "let converted = Optional(identityKey)")]),
    ("lastSeen not set", [(DECRYPT, "device.lastSeen = now()", "device.lastSeen = nil")]),
    ("bundle signature checked only after the identity is recorded", [
        (ENGINE, "            bundle.hasValidSignature(version: version),\n", "")]),
    ("identity change keeps the old trust", [
        (ENGINE, """            updated.trust = TrustPolicy.trustAfterIdentityChange(
                previous: device.trust, among: others)""",
         "            updated.trust = others.isEmpty ? device.trust : device.trust")]),
    ("identity change raises trust", [
        (TRUST, "previous == .trusted && trustForNewDevice(among: others) == .trusted",
         "trustForNewDevice(among: others) == .trusted")]),
    ("bundle back-off off", [
        (ENGINE, "return now() >= failure.retryAt", "return failure.retryAt == failure.retryAt")]),
    ("back-off kept when a device is listed again", [
        (ENGINE, "bundleFailures[RepairKey(device: known[index].address, version: version)] = nil", "")]),
    ("back-off does not double", [
        (ENGINE, "3_600 * pow(2, Double(max(failures, 1) - 1))", "3_600 * Double(max(failures, 1))")]),
    ("bundle fetches one at a time", [
        (ENGINE, "while next < min(devices.count, Self.maxConcurrentBundleFetches) {",
         "while next < min(devices.count, 1) {")]),
    ("bundle fetches unbounded", [
        (ENGINE, "maxConcurrentBundleFetches = 8", "maxConcurrentBundleFetches = 16")]),
    ("no bundle fetch time-out", [
        ("Timeout.swift", "try? await clock.sleep(for: timeout)", "try? await clock.sleep(for: timeout * 1_000)")]),
    ("stale by message count off", [
        (ENGINE, "if session.sentSinceReceived >= Self.staleAfterMessages { return true }", "")]),
    ("stale by silence off", [
        (ENGINE, "return now().timeIntervalSince(heard) > Self.staleAfterSilence",
         "return now().timeIntervalSince(heard) < 0")]),
    ("all-stale contact gets no keys", [
        (ENCRYPT, "groups[index].devices = current.isEmpty ? reachable : current",
         "groups[index].devices = current")]),
    ("staleness decided among unreachable devices too", [
        (ENCRYPT, "let current = reachable.filter { !isStale($0, session: sessions[$0.address]) }",
         "let current = groups[index].devices.filter {\n"
         "                !isStale($0, session: sessions[$0.address])\n            }")]),
    ("device without a session shown as having one", [
        (ENGINE, "hasSession: session != nil,", "hasSession: session == nil || session != nil,")]),
    ("bundle unavailability not shown", [
        (ENGINE, "isBundleUnavailable: !mayFetchBundle(device.address, version: version)",
         "isBundleUnavailable: !mayFetchBundle(device.address, version: version) && false")]),
    ("message count not reset by an answer", [
        (DECRYPT, "        session.sentSinceReceived = 0\n", "")]),
    ("sessions stored before the message is complete", [
        (ENCRYPT, "                sealedSessions.append((device.address, session))",
         "                sealedSessions.append((device.address, session))\n"
         "                try await store.saveSession(\n"
         "                    try session.encoded(), with: device.address, version: version)")]),
    # Task 17b fix round 2.
    ("decrypt asks for no repair", [
        (DECRYPT, "result.repairWanted = true", "result.repairWanted = false")]),
    ("unknown sender not reported", [
        (DECRYPT, "result.senderUnknown = !origin.known", "result.senderUnknown = false")]),
    ("archived key exchange replaces the current session", [
        (DECRYPT, "            if let stored, answering,\n                promoting || state.remoteIdentityKey != stored.remoteIdentityKey\n            {",
         "            if let stored, true || answering || promoting {")]),
    ("repair fetches under the engine queue", [
        (DECRYPT, "let fetched = await fetchBundles([address], version: version)",
         "let fetched = try await exclusively {\n"
         "            await fetchBundles([address], version: version)\n        }")]),
    ("a device gets an id per version", [
        (ENGINE, "if let reused = other {", "if let reused = other, reused == 0 {")]),
    # Task 17b fix round 3.
    ("archived key exchange under another identity read (both guards)", [
        (DECRYPT, "if let known = recorded ?? stored?.remoteIdentityKey, known != exchange.identityKey {",
         "if let known = recorded ?? stored?.remoteIdentityKey, known != exchange.identityKey, known.isEmpty {"),
        ("StoredSession.swift", "guard state.remoteIdentityKey == current.remoteIdentityKey else { return nil }",
         "guard state.remoteIdentityKey == current.remoteIdentityKey else { return self }")]),
    ("archived ratchet message promotes an old session", [
        (DECRYPT, "return Self.open(message, on: stored, promoting: promoting)",
         "return Self.open(message, on: stored, promoting: true)")]),
    ("archived repeated key exchange promotes an old session", [
        (DECRYPT, "return Self.open(exchange.message, on: stored, only: index, promoting: promoting)",
         "return Self.open(exchange.message, on: stored, only: index, promoting: true)")]),
    ("heartbeat recorded without an answer", [
        (DECRYPT, "        if heartbeatDue { reason = reason ?? .heartbeat }\n",
         "        if heartbeatDue {\n            reason = reason ?? .heartbeat\n"
         "            session.heartbeatRatchetKey = opened.header.ratchetKey\n        }\n")]),
    ("a heartbeat not sent stays recorded", [
        (DECRYPT, "            session.heartbeatRatchetKey = nil\n",
         "            session.heartbeatRatchetKey = session.heartbeatRatchetKey\n")]),
    # Task 17b fix round 3, R60: trust belongs to the identity key.
    ("BTBV looks at one version", [
        (ENGINE, "let newTrust = TrustPolicy.trustForNewDevice(among: known + elsewhere)",
         "let newTrust = TrustPolicy.trustForNewDevice(among: known + elsewhere.filter { _ in false })")]),
    ("a decision stays in its version", [
        (ENGINE, "try await setIdentityTrust(trust, identity: identity, of: device.jid)",
         "_ = identity")]),
    ("a key takes no trust from its twin", [
        (ENGINE, "            updated.trust = merged\n", "")]),
    ("undecided devices' keys never read", [
        ("OMEMOEngine+Encrypt.swift",
         "        try await learnIdentities(from: read, bundles: bundles, version: version)\n",
         "")]),
    ("stored trust merges to the laxer", [
        ("TrustPolicy.swift", "return rank(one) >= rank(other) ? one : other",
         "return rank(one) >= rank(other) ? other : one")]),
    ("legacy key read with its sign bit", [
        (ENGINE, "            montgomery[montgomery.startIndex + 31] &= 0x7F\n", "")]),
    # R66: one identity key for both versions.
    ("own legacy identity made apart", [
        (ENGINE, "privateKey: KeyConversion.montgomeryPrivate(fromEd25519Seed: modern.privateKey),",
         "privateKey: modern.privateKey.isEmpty\n                    ? Data() : IdentityKeyPair.generate(version: .v03).privateKey,")]),
    ("a refresh records no key", [
        ("OMEMOEngine+Encrypt.swift",
         "                _ = try await recordIdentity(bundle.identityKey, of: current, version: version)\n",
         "                _ = current.identityKey\n")]),
    # Task 17b fix round 4.
    ("a key's trust raises the device's", [
        (ENGINE, ": updated.trust == .distrusted ? .distrusted : shared", ": shared")]),
    ("a late message promotes", [
        (DECRYPT, "promoting: promoting ?? answering, arrivedAt: arrivedAt)",
         "promoting: answering, arrivedAt: arrivedAt)")]),
    ("a late key exchange replaces the session", [
        (DECRYPT, "promoting || state.remoteIdentityKey != stored.remoteIdentityKey",
         "promoting || true")]),
    # Task 17b fix round 5.
    ("a keyless default lowers a key", [
        (ENGINE, ": updated.trust == .distrusted ? .distrusted : shared",
         ": TrustPolicy.stricter(updated.trust, shared)")]),
    ("a keyless device is verified", [
        (ENGINE, "if record.identityKey == nil, trust == .trusted || trust == .verified {",
         "if record.identityKey == nil, trust == .trusted && trust == .verified {")]),
    ("a late older key replaces the session", [
        (DECRYPT, "                    seen > arrivedAt\n", "                    seen > arrivedAt, seen < arrivedAt\n")]),
    # Task 17c, m20.
    ("a session save after the key throws", [
        (DECRYPT, "            guard wrote else { throw error }\n",
         "            guard !wrote else { throw error }\n")]),
    ("a session not saved is answered", [
        (DECRYPT, "            result.replies = []\n            saved = false\n",
         "            saved = false\n")]),
    # Task 17c fix round 1.
    ("the old session deleted after the record", [
        (ENGINE, "            try await store.deleteSession(with: device.address, version: version)\n"
         "            Self.log.notice(\n", "            Self.log.notice(\n"),
        (ENGINE, "        try await store.saveDevice(updated, version: version)\n        if let spread {\n",
         "        try await store.saveDevice(updated, version: version)\n"
         "        if changed { try? await store.deleteSession(with: device.address, version: version) }\n"
         "        if let spread {\n")]),
    ("a session under another key is sealed to", [
        (ENCRYPT, "session.remoteIdentityKey == device.identityKey",
         "!session.remoteIdentityKey.isEmpty")]),
    ("the pre key of a session not saved is forgotten", [
        (DECRYPT, "unconsumedPreKeys[RepairKey(device: address, version: version)] = preKeyID",
         "_ = preKeyID")]),
    # Final review I-3: a huge device list never holds up the account.
    ("new sessions per message unbounded", [
        (ENCRYPT, "wanted += picked.prefix(Self.newDevicesPerMessage).map(\\.address)",
         "wanted += picked.map(\\.address)")]),
    ("a message's bundles fetched under the engine queue", [
        (ENCRYPT, "let fetched = await fetchBundles(wanted, version: version)",
         "let fetched = try await exclusively {\n"
         "            await fetchBundles(wanted, version: version)\n        }")]),
    ("bundle fetches not shared", [
        (ENGINE, "bundleFetches[RepairKey(device: device, version: version)] = started",
         "_ = (device, started)")]),
    ("canonical forms worked out every time", [
        (ENGINE, "canonicalForms[cacheKey] = .some(form)", "_ = form")]),
    # Final review I-2: a distrusted device that writes is told apart.
    ("a distrusted device keeps when it was heard from", [
        (ENGINE, "            if trust == .distrusted { record.lastSeen = nil }\n", "")]),
    ("a distrusted identity keeps when it was heard from", [
        (ENGINE, "                if trust == .distrusted { device.lastSeen = nil }\n", "")]),
]


def run_tests() -> str:
    result = subprocess.run(
        ["swift", "test", "--package-path", str(ROOT / "Packages/OMEMO"), "--filter", FILTER],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1_800,
    )
    return re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)


def main() -> int:
    words = use_copy(sys.argv[1:])
    problems = 0
    for name, replacements in MUTATIONS:
        if words and not any(word in name for word in words):
            continue
        originals: dict[pathlib.Path, str] = {}
        try:
            matched = True
            for file, old, new in replacements:
                path = SOURCES / file
                originals.setdefault(path, path.read_text(encoding="utf-8"))
                text = path.read_text(encoding="utf-8")
                if old not in text:
                    matched = False
                    break
                path.write_text(text.replace(old, new, 1), encoding="utf-8")
            if not matched:
                print(f"[{name}] PATTERN NOT FOUND", flush=True)
                problems += 1
                continue
            output = run_tests()
        finally:
            for path, text in originals.items():
                path.write_text(text, encoding="utf-8")
        if "Test run with" not in output:
            errors = [line for line in output.splitlines() if "error:" in line][:2]
            print(f"[{name}] BUILD ERROR {errors}", flush=True)
            problems += 1
            continue
        failing = sorted(set(re.findall(r"✘ Test (\w+)\(", output)))
        if failing:
            print(f"[{name}] caught by: {' '.join(failing)}", flush=True)
        else:
            print(f"[{name}] NOT CAUGHT", flush=True)
            problems += 1
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
