"""Mutation checks for OMEMO in the account session (test tooling, never shipped).

Each mutation breaks one rule in XippiSession's OMEMO files on purpose, runs the OMEMO
suites, and restores the file. A mutation must make at least one test fail; one that leaves
every test passing, does not build, or no longer matches the source is reported and makes the
script exit with status 1. Only the OMEMO files are touched, never the session files other
work shares.

    python3 -I scripts/omemo-mutations/session.py --copy DIR            # every mutation
    python3 -I scripts/omemo-mutations/session.py --copy DIR heartbeat  # names with a word

Mutants are never written into the shared working tree, which others build from: the
packages are copied into DIR (`--copy`, outside the repository, e.g. a scratch directory) and
mutated and built there. The copy keeps its own build products between runs.

The sources must be formatted (swift format -i) for the patterns to match.
"""

import pathlib
import re
import subprocess
import sys
import time

# The shared working tree: read from, never mutated.
SHARED = pathlib.Path(__file__).resolve().parents[2]
# The copy mutated and built (`--copy`), set by `use_copy`.
ROOT = SHARED
SOURCES = ROOT / "Packages/XippiSession/Sources/XippiSession"


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
    ROOT = copy
    SOURCES = ROOT / "Packages/XippiSession/Sources/XippiSession"
    sync_copy()
    return argv[:index] + argv[index + 2:]


def sync_copy(keep: tuple[pathlib.Path, ...] = ()) -> None:
    """Brings the copy's sources up to the shared tree's, except the files in `keep` (the ones
    mutated); the copy's own build products stay."""
    packages = ROOT / "Packages"
    kept = [arg for path in keep for arg in ("--exclude", f"/{path.relative_to(packages)}")]
    subprocess.run(
        ["rsync", "-a", "--delete", "--exclude", ".build", "--exclude", ".swiftpm", *kept,
         f"{SHARED / 'Packages'}/", f"{packages}/"],
        check=True,
    )
FILTER = "OMEMOManagerTests|OMEMOPipelineTests|OMEMOArchiveTests|OMEMOFixRoundTests|OMEMOFixRound3Tests|OMEMOFixRound4Tests|OMEMOFixRound5Tests|OMEMOFollowUpTests|OMEMOLeaseTests|OMEMOFinalReviewTests"

MANAGER = "OMEMO/OMEMOManager.swift"
TRANSPORT = "OMEMO/PEPTransport.swift"
GLUE = "AccountSession+OMEMO.swift"
CATCHUP = "History/MAMCatchUp.swift"
LEASE = "OMEMOLease.swift"
SESSION = "AccountSession.swift"
FILES = "AccountSession+Files.swift"
ROOMS = "AccountSession+Rooms.swift"

# (name, [(file, old, new), ...]): every replacement of a mutation is applied together.
MUTATIONS = [
    ("device list taken from a full JID", [
        (MANAGER, "guard let from = event.from, from.isBare else {",
         "guard let from = event.from else {")]),
    ("own list without this device not published again", [
        (MANAGER, "guard jid == account, let own = update.listToPublish else { return }",
         "guard jid == account, let own = update.listToPublish, jid != account else { return }")]),
    ("no publish-options", [
        (MANAGER, "guard accountFeatures.contains(PubSub.publishOptionsFeature) else {",
         "guard accountFeatures.contains(PubSub.publishOptionsFeature), accountFeatures.isEmpty\n"
         "        else {")]),
    ("node not configured without publish-options", [
        (MANAGER, """            do {
                try await PubSub.configure(node: node, options: options, via: bounded)
            } catch {
                Self.log.notice("OMEMO node not configured")
            }
""", "")]),
    ("node not configured after precondition-not-met", [
        (MANAGER, """                try await PubSub.configure(node: node, options: options, via: bounded)
                try await PubSub.publish(""", """                try await PubSub.publish(""")]),
    ("always OMEMO 2", [
        (MANAGER, "guard legacy.isSubset(of: modern), jid == account || !modern.isEmpty else {",
         "guard legacy.count + modern.count >= 0 else {")]),
    ("devices matched by count", [
        (MANAGER, "guard legacy.isSubset(of: modern), jid == account || !modern.isEmpty else {",
         "guard legacy.subtracting(modern).count <= modern.subtracting(legacy).count,\n"
         "                jid == account || !modern.isEmpty\n            else {")]),
    ("replies not sent", [
        (MANAGER, "for reply in result.replies {",
         "for reply in result.replies where reply.device.deviceID == 0 {")]),
    ("bundle not published after a pre key is used", [
        (MANAGER, "        if result.bundleToPublish != nil { schedulePublishBundle(version) }\n",
         "")]),
    ("room member lists ignored", [
        (MANAGER, "jids.formUnion(items.map(\\.jid.bare))",
         "jids.formUnion(items.map(\\.jid.bare).filter { _ in false })")]),
    ("room occupants ignored", [
        (MANAGER, ".union(await occupants())", "")]),
    ("keys never looked after", [
        (MANAGER, "now.timeIntervalSince(last) >= Self.maintenanceInterval",
         "now.timeIntervalSince(last) < 0")]),
    ("stop does not wait for the work under way", [
        (MANAGER, "        worker?.cancel()\n        await ownDevices?.value\n        await publishing?.value\n",
         "        worker?.cancel()\n")]),
    ("a stopped manager takes work", [
        (MANAGER, "guard !stopped, leased else { return false }",
         "guard leased else { return false }")]),
    ("repair run on the event loop", [
        (MANAGER, "if result.repairWanted { askRepair(device, version: version) }",
         "if result.repairWanted {\n"
         "                await repair(device, version: version, failedAt: now())\n            }")]),
    ("unknown sender's lists read on the event loop", [
        (MANAGER, "if result.senderUnknown { askListRead(device.jid) }",
         "if result.senderUnknown { await readLists(of: device.jid) }")]),
    ("repairs limited per device only", [
        (MANAGER, "if let last = repairsAsked[device.jid],",
         "if let last = repairsAsked[device.jid], device.deviceID == 0,")]),
    ("OMEMO 2 reactions in the clear", [
        (MANAGER, "reactions + plain.children(\"fallback\"", "plain.children(\"fallback\"")]),
    ("legacy reactions not refused", [
        (MANAGER, "guard reactions.isEmpty else { throw .reactionsNeedOMEMO2 }",
         "guard reactions.isEmpty || !reactions.isEmpty else { throw .reactionsNeedOMEMO2 }")]),
    ("sealed stanza keeps clear links and file metadata", [
        (MANAGER, """child.name == "body" || child.namespace == ChatMessage.oobNamespace
                    || child.namespace == ChatMessage.sfsNamespace || inside.contains(child)""",
         """child.name == "body" || inside.contains(child)""")]),
    ("archive copies answered like live ones", [
        (MANAGER, "recipient: recipient, answering: false, known: false,",
         "recipient: recipient, answering: true, known: false,")]),
    ("requests not bounded", [
        (TRANSPORT, "try await base.request(iq, timeout: min(timeout, limit))",
         "try await base.request(iq, timeout: timeout)")]),
    ("decrypted although a copy is stored", [
        (GLUE, "if let lookup = origin.lookup, let copy = try? database.storedCopy(of: lookup) {",
         "if let lookup = origin.lookup, lookup.chatID < 0,\n"
         "            let copy = try? database.storedCopy(of: lookup)\n        {")]),
    ("strangers repaired", [
        (GLUE, "known: outgoing || isKnown(peer))", "known: true)")]),
    ("a stranger's own messages make them known", [
        (GLUE, "return (try? database.hasOutgoingMessage(chatID: chatID)) ?? false",
         "return chatID >= Int64.min")]),
    ("a chat the user read is a stranger's", [
        (GLUE, "if chat.lastReadMessageID != nil { return true }", "")]),
    ("work asked for strangers", [
        (MANAGER, "if let device = result.sender, known {", "if let device = result.sender {")]),
    ("repair queue without a bound", [
        (MANAGER, "if jobs.count >= Self.capacity {", "if jobs.count >= Int.max {")]),
    ("repair queue without contacts first", [
        (MANAGER, "guard let index = jobs.firstIndex(where: \\.known) ?? jobs.indices.first else {",
         "guard let index = jobs.indices.first else {")]),
    ("repair queue with an entry per job", [
        (MANAGER, "var index = jobs.firstIndex { $0.jid == jid }", "var index: Int? = nil")]),
    ("identity change not flagged", [
        (GLUE, "incoming.identityChanged = omemo.identityChanged", "incoming.identityChanged = false")]),
    ("archive copy kept as unreadable while OMEMO is off", [
        (GLUE, "let result = await omemo.decryptArchived(encrypted, from: sender, recipient: recipient)\n        else { return nil }",
         "let result = await omemo.decryptArchived(encrypted, from: sender, recipient: recipient)\n        else { return unreadable(message, cannotDecryptText, hasPayload: hasPayload) }")]),
    ("page recorded although cut short", [
        (CATCHUP, "            guard case .stored = outcome else { return outcome }\n",
         "            _ = outcome\n")]),
    ("cancellation not checked within a page", [
        (CATCHUP, "            if Task.isCancelled {\n                outcome = .stopped\n                break\n            }\n", "")]),
    ("stop does not wait for the catch-up", [
        (GLUE, "        await catchUp.stop()\n        await catchUp.runsEnded()\n", "        await catchUp.stop()\n")]),
    ("OMEMO messages shown before OMEMO can read them", [
        (GLUE, "return dead || !hasOMEMO || drainingPending", "return dead")]),
    ("kept messages not signalled", [
        (GLUE, "        OMEMOPendingSignal.shared.raise(database: database, accountID: accountID)\n", "")]),
    ("undecided devices choose the version", [
        (MANAGER, ".filter(TrustPolicy.receivesKeys).map(\\.deviceID))", ".filter(\\.active).map(\\.deviceID))"),
        (MANAGER, ".filter(TrustPolicy.receivesKeys).map(\\.deviceID))", ".filter(\\.active).map(\\.deviceID))")]),
    ("an answer not sent kept as done", [
        (MANAGER, "                try? await engine.heartbeatNotSent(to: reply.device, version: version)\n", "")]),
    ("lease taken but OMEMO left off", [
        (GLUE, "        await omemo.leaseGranted()\n", "")]),
    ("deferred archive pages never read again", [
        (GLUE, "        await catchUp.resumeDeferred()\n", "")]),
    ("waiting for the lease misses its release", [
        (LEASE, "            for waiter in woken.values { waiter.resume(returning: true) }\n",
         "            _ = woken\n")]),
    ("notice never upgraded", [
        (GLUE, "guard let result, case .message = result.content, !result.identityChanged,",
         "guard let result, case .message = result.content, copy.id == nil, !result.identityChanged,")]),
    ("copy of a notice keeps its receipt request", [
        (GLUE, "        if isNotice(copy) {\n            return unreadable(",
         "        if isNotice(copy), copy.id == nil {\n            return unreadable(")]),
    ("envelope time not checked", [
        (GLUE, "> OMEMOManager.envelopeTimeMargin", "> .infinity")]),
    ("clear links beside the encrypted body kept", [
        (GLUE, "case ChatMessage.oobNamespace, ChatMessage.sfsNamespace, OMEMOManager.emeNamespace,",
         "case OMEMOManager.emeNamespace,")]),
    ("clear reactions beside the encrypted body kept", [
        (GLUE, "OMEMOManager.emeNamespace,\n            ChatMessage.reactionsNamespace:",
         "OMEMOManager.emeNamespace:")]),
    ("notice asks for a receipt", [
        (GLUE, "ChatMessage.fallbackNamespace, Receipts.namespace, Markers.namespace,",
         "ChatMessage.fallbackNamespace, Markers.namespace,")]),
    ("notice stored as text", [
        (GLUE, "if let kind = omemo.kind {", "if let kind = omemo.kind, kind == .text {")]),
    ("decrypted message stored as plaintext", [
        (GLUE, "incoming.encryption = .omemo", "incoming.encryption = .none")]),
    ("sent carbon checked against the account", [
        (GLUE, "recipient: outgoing ? .direct(peer) : nil", "recipient: nil")]),
    ("sent in the clear when it cannot be encrypted", [
        (GLUE, "            throw .encryption(error)\n",
         "            await transmit(plain)\n            throw .encryption(error)\n")]),
    ("archived room messages decrypted in any room", [
        (GLUE, "!(archived.roomTrust.map { $0.nonAnonymous && $0.membersOnly } ?? false)",
         "archived.roomTrust == nil")]),
    ("our archived messages checked against the account", [
        (GLUE, ": archived.outgoing ? .direct(archived.conversation) : nil", ": nil")]),
    # Task 17b fix round 4.
    ("a member is no one", [
        (GLUE, "let listed = await omemo.isMember(sender, of: room)",
         "let listed = sender == room")]),
    ("members known in any room", [
        (GLUE, "if !known, let sender, trust.nonAnonymous, trust.membersOnly {",
         "if !known, let sender {")]),
    ("nothing read when the stream resumes", [
        (SESSION, "if leaseCameWhileDown { await readWhatWaited() } else { await drainPendingOMEMO() }",
         "_ = leaseCameWhileDown")]),
    ("a correction read into a notice", [
        (GLUE, "let parsed = ChatMessage(element: opened.element), parsed.correctionOf == nil,",
         "let parsed = ChatMessage(element: opened.element),")]),
    ("the archive opens after a cut", [
        (GLUE, "        if isCut() { return nil }\n", "        _ = isCut\n")]),
    ("an engine error defers the page", [
        (MANAGER, "return DecryptedPayload(content: .failed(.notReadable))", "return nil")]),
    ("kept messages read as live", [
        (GLUE, "promoting: arrivedAt == nil, arrivedAt: arrivedAt)",
         "promoting: true, arrivedAt: arrivedAt)")]),
    # Task 17b fix round 5.
    ("members by presence unknown", [
        (GLUE, "known = [.member, .admin, .owner].contains(affiliation) || listed",
         "known = affiliation == nil && listed")]),
    ("no member list read on join", [
        (ROOMS, "if trust.nonAnonymous, trust.membersOnly { await omemo.roomJoined(room) }",
         "if trust.nonAnonymous, trust.membersOnly, room.isBare == false { await omemo.roomJoined(room) }")]),
    ("a row that could not be deleted is read again", [
        (GLUE, "excluding: undeletedKept)", "excluding: [])")]),
    ("a row that could not be deleted stays for good", [
        (GLUE, "        retryUndeletedKept()\n", "")]),
    # Task 17c.
    ("a genuine duplicate is a notice", [
        (MANAGER, "        guard let result = decrypted else {\n",
         "        guard let result = decrypted, result.content != .duplicate else {\n")]),
    ("the drain reads the whole table", [
        (GLUE, "return try database.nextOMEMOPending(accountID: accountID, excluding: undeletedKept)",
         "return try database.omemoPending(accountID: accountID)\n"
         "                .first { !undeletedKept.contains($0.id ?? 0) }")]),
    # Final review I-1: the lease holds across processes.
    ("lease held in this process only", [
        (LEASE, "            locked = Self.lock(path)\n", "            locked = path.isEmpty ? -1 : -1\n")]),
    ("a lease another process held never taken", [
        (LEASE, "                try? await Task.sleep(for: retryInterval)\n                continue\n",
         "                return nil\n")]),
    # Final review I-2: a distrusted device's message.
    ("a distrusted device's message shown as any other", [
        (GLUE, "if result.senderTrust == .distrusted {",
         "if result.senderTrust == .distrusted, result.sender == nil {")]),
    ("a distrusted device's text not kept", [
        (GLUE, "            incoming.errorText = omemo.withheld\n", "")]),
    # Final review I-4, R77.
    ("OMEMO 2 markers in the clear read", [
        (GLUE, "isClearContent(child, of: message) || modern && isEnvelopeOnly(child)",
         "isClearContent(child, of: message) || modern && isEnvelopeOnly(child) && false")]),
    ("a legacy fallback cuts whatever it says", [
        (GLUE, "            return checkingReplyFallback(opened, chatID: chatID, database: database)\n",
         "            return opened\n")]),
    ("any quote lines are a quote of the target", [
        (GLUE, "return whole.contains(quote) || quote.hasSuffix(whole)", "return true")]),
    ("OMEMO 2 corrections and replies in the clear", [
        (MANAGER, "\n                + plain.children(\"replace\", namespace: ChatMessage.correctionNamespace)"
         "\n                + plain.children(\"reply\", namespace: ChatMessage.replyNamespace)", "")]),
]


# Builds tried while other files do not compile, 30 s apart.
BUILD_RETRIES = 40


def run_tests() -> str:
    try:
        result = subprocess.run(
            ["swift", "test", "--package-path", str(ROOT / "Packages/XippiSession"), "--filter",
             FILTER],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        # The test process outlives `swift test`: end the one this copy started, nobody else's.
        subprocess.run(["pkill", "-f", f"test-bundle-path {ROOT}/"], check=False)
        # The suites have time limits; a run that still does not end hung on the mutant.
        return "Test run with no end\n✘ Test hungRun("
    return re.sub(r"\x1b\[[0-9;]*m", "", result.stdout)


def restore(
    originals: dict[pathlib.Path, str], mutants: dict[pathlib.Path, str],
    applied: list[tuple[pathlib.Path, str, str]],
) -> None:
    """Puts each file back as it was. A file someone else edited while the mutant ran keeps
    their edit: only the mutation is undone in it (other people work in these files too)."""
    for path, original in originals.items():
        current = path.read_text(encoding="utf-8")
        if path not in mutants or current == mutants[path]:
            path.write_text(original, encoding="utf-8")
            continue
        for mutated_path, old, new in reversed(applied):
            if mutated_path == path and new in current:
                current = current.replace(new, old, 1)
        path.write_text(current, encoding="utf-8")
        print(f"  ({path.name} was edited meanwhile: only the mutation undone)", flush=True)


def main() -> int:
    words = use_copy(sys.argv[1:])
    problems = 0
    for name, replacements in MUTATIONS:
        if words and not any(word in name for word in words):
            continue
        originals: dict[pathlib.Path, str] = {}
        # What each file held once mutated, to tell whether someone edited it meanwhile.
        mutants: dict[pathlib.Path, str] = {}
        applied: list[tuple[pathlib.Path, str, str]] = []
        try:
            matched = True
            for file, old, new in replacements:
                path = SOURCES / file
                originals.setdefault(path, path.read_text(encoding="utf-8"))
                text = path.read_text(encoding="utf-8")
                if old not in text:
                    matched = False
                    break
                mutant = text.replace(old, new, 1)
                path.write_text(mutant, encoding="utf-8")
                mutants[path] = mutant
                applied.append((path, old, new))
            if not matched:
                print(f"[{name}] PATTERN NOT FOUND", flush=True)
                problems += 1
                continue
            # Other people's files may not compile for a while: a build error that names none
            # of the mutated files is waited out, not counted.
            mutated = [str(SOURCES / file) for file, _, _ in replacements]
            for _ in range(BUILD_RETRIES):
                output = run_tests()
                if "Test run with" in output:
                    break
                errors = [line for line in output.splitlines() if "error:" in line]
                if any(path in line for line in errors for path in mutated):
                    break
                time.sleep(30)
                # The copy was taken while their files did not compile: take them again.
                sync_copy(keep=tuple(mutants))
        finally:
            restore(originals, mutants, applied)
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
