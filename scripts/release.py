#!/usr/bin/env python3
"""What CI does with a release tag before and after fastlane builds it.

    release.py version <tag>      {"version": "0.1.0", "prerelease": false}
    release.py check <tag>        refuses a tag that must not ship (exit 1, with why)
    release.py notes <tag> [out]  release notes since the previous release, from OpenAI

A plain tag (v0.1.0) goes to App Review, a tag with a suffix (v0.1.0-beta.1) only to
TestFlight. Release notes need OPENAI_API_KEY.
"""

import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "App" / "Info.plist"

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?$")

MODEL = "gpt-6.2-sol"
OPENAI_URL = "https://api.openai.com/v1/responses"
# Apple's limit for "What's New" and TestFlight's "What to Test".
NOTES_LIMIT = 4000
# The diff sent along, in characters: enough for a release, a few cents per call.
DIFF_LIMIT = 150_000
# The first version of an app takes no "What's New"; TestFlight still gets a line.
FIRST_RELEASE = "First release."
# The code a person using the app sees, without its tests.
SOURCES = ["App", "Packages/*/Sources"]

INSTRUCTIONS = """\
You write the "What's New" text of the Mac App Store listing of Xippi, a native macOS \
chat app for XMPP. You get the changes between two releases: commit titles, a diff stat \
and the code diff. Write what changed for the person using the app.

Rules:
- Only what a user can see or feel: new features, fixed bugs, things that now work \
differently. Leave out refactoring, tests, CI, builds and anything only developers see.
- One short line per change, each starting with "- ". Most important first. At most 10 lines.
- Terse and concrete: name the thing, say what changed. No introduction, no closing \
line, no headings, no marketing, no exclamation marks.
- Never use these words: seamless, seamlessly, robust, powerful, simply, leverage, \
ensure, enhance, enhanced, various, improved experience.
- No em dash or en dash anywhere; where a dash is needed, use a plain hyphen.
- Never mention prices, and never say the app is free.
- Never name people, accounts, servers or internal identifiers.
- Plain text only, no Markdown beyond the leading "- ".
- If nothing a user would notice changed, write exactly: - Fixes and small changes"""


def parse_tag(tag: str) -> tuple[str, bool]:
    """The version a tag builds, and whether it is a prerelease (TestFlight only)."""
    match = TAG.match(tag)
    if not match:
        raise ValueError(f"{tag}: not a release tag (vX.Y.Z or vX.Y.Z-suffix)")
    major, minor, patch, suffix = match.groups()
    return f"{int(major)}.{int(minor)}.{int(patch)}", suffix is not None


def _key(tag: str) -> tuple[int, int, int]:
    major, minor, patch = parse_tag(tag)[0].split(".")
    return int(major), int(minor), int(patch)


def previous_tag(tags: list[str], tag: str) -> str | None:
    """The newest release (a plain tag) older than `tag`'s version, None for the first."""
    current = _key(tag)
    older = []
    for other in tags:
        try:
            _, prerelease = parse_tag(other)
        except ValueError:
            continue
        if not prerelease and _key(other) < current:
            older.append(other)
    return max(older, key=_key, default=None)


def git(*args: str, cwd: pathlib.Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def on_branch(commit: str, branch: str, cwd: pathlib.Path = ROOT) -> bool:
    """Whether `commit` is part of `branch`'s history."""
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", commit, branch], cwd=cwd, capture_output=True
    )
    return result.returncode == 0


def compliance_problem(plist: pathlib.Path) -> str | None:
    """Why a build would wait for export compliance answers in App Store Connect; None when
    it would not."""
    values = plistlib.loads(plist.read_bytes())
    where = plist.relative_to(ROOT) if plist.is_relative_to(ROOT) else plist
    uses = values.get("ITSAppUsesNonExemptEncryption")
    if uses is None:
        return (
            f"{where}: no ITSAppUsesNonExemptEncryption. Without it every build waits for the "
            "export compliance questions in App Store Connect."
        )
    if uses and not values.get("ITSEncryptionExportComplianceCode"):
        return (
            f"{where}: ITSAppUsesNonExemptEncryption is YES without an "
            "ITSEncryptionExportComplianceCode, so every build stops at Missing Compliance. "
            "Add the code Apple gives when it approves the encryption documentation, or set "
            "the key to NO if no documents are needed (standard algorithms only, not sold in "
            "France)."
        )
    return None


def check(tag: str) -> list[str]:
    """Why `tag` must not ship; empty when it may."""
    try:
        _, prerelease = parse_tag(tag)
    except ValueError as error:
        return [str(error)]
    problems = []
    try:
        commit = git("rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}")
    except subprocess.CalledProcessError:
        return [f"{tag}: no such tag here"]
    if not prerelease and not on_branch(commit, "origin/main"):
        problems.append(
            f"{tag}: its commit {commit[:12]} is not on main. A release ships from main; "
            "tag a prerelease (vX.Y.Z-beta.N) to try a branch on TestFlight."
        )
    compliance = compliance_problem(INFO_PLIST)
    if compliance:
        problems.append(compliance)
    return problems


def clean_notes(text: str) -> str:
    """No em or en dash, and no more than Apple takes, ending at a whole line."""
    text = text.replace("\u2014", "-").replace("\u2013", "-").strip()
    if len(text) <= NOTES_LIMIT:
        return text
    kept = []
    for line in text.splitlines():
        if len("\n".join([*kept, line])) > NOTES_LIMIT:
            break
        kept.append(line)
    return "\n".join(kept).strip()


def changes(previous: str, tag: str) -> str:
    """What changed between two tags, as OpenAI reads it."""
    titles = git("log", "--no-merges", "--format=%s", f"{previous}..{tag}")
    stat = git("diff", "--stat", previous, tag, "--", *SOURCES)
    diff = git("diff", previous, tag, "--", *SOURCES)
    if len(diff) > DIFF_LIMIT:
        diff = diff[:DIFF_LIMIT] + "\n[diff cut here]"
    return (
        f"Previous release: {previous}\nThis release: {tag}\n\n"
        f"Commit titles:\n{titles}\n\nFiles changed:\n{stat}\n\nDiff:\n{diff}"
    )


def notes_request(changes_text: str) -> dict:
    """The Responses API body that asks for the notes."""
    return {
        "model": MODEL,
        "instructions": INSTRUCTIONS,
        "input": changes_text,
        "reasoning": {"effort": "low"},
        # Reasoning tokens count against this as well as the text.
        "max_output_tokens": 8000,
        # Nothing of the diff is kept at OpenAI after the answer.
        "store": False,
    }


def notes_text(response: dict) -> str:
    """The text of the answer: the message's output_text parts, whatever comes before."""
    parts = [
        part.get("text", "")
        for item in response.get("output", [])
        if item.get("type") == "message"
        for part in item.get("content", [])
        if part.get("type") == "output_text"
    ]
    text = "".join(parts).strip()
    if not text:
        raise RuntimeError(f"OpenAI answered without text (status {response.get('status')})")
    return text


def ask_openai(changes_text: str) -> str:
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    request = urllib.request.Request(
        OPENAI_URL,
        data=json.dumps(notes_request(changes_text)).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as answer:
            return notes_text(json.load(answer))
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise RuntimeError(f"OpenAI: HTTP {error.code}: {detail}") from None


def write_notes(tag: str, tags: list[str], ask=ask_openai, changes=changes) -> str:
    """Release notes for `tag`: OpenAI's summary of the changes since the last release."""
    previous = previous_tag(tags, tag)
    if previous is None:
        return FIRST_RELEASE
    return clean_notes(ask(changes(previous, tag)))


def main(argv: list[str]) -> int:
    match argv:
        case ["version", tag]:
            version, prerelease = parse_tag(tag)
            print(json.dumps({"version": version, "prerelease": prerelease}))
            return 0
        case ["check", tag]:
            problems = check(tag)
            for problem in problems:
                print(problem, file=sys.stderr)
            return 1 if problems else 0
        case ["notes", tag, *out] if len(out) <= 1:
            tags = git("tag", "--list", "v*").splitlines()
            notes = write_notes(tag, tags)
            if out:
                pathlib.Path(out[0]).write_text(notes + "\n", encoding="utf-8")
            print(notes)
            return 0
    print((__doc__ or "").strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release.py: {error}", file=sys.stderr)
        sys.exit(1)
