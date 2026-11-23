#!/usr/bin/env python3
"""Checks the App Store text in fastlane/metadata before fastlane uploads it, and the
screenshots' headlines in scripts/screenshots/scenes.json.

Apple's character limits, no em or en dash except in the name (the owner's choice for
that one string), and no "free": the price is not announced anywhere.

Usage: scripts/store_text.py <metadata dir> [<scenes.json>]
"""

import json
import pathlib
import re
import sys

# Apple's limits, in characters, for the files of a language folder.
LIMITS = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "keywords.txt": 100,
    "promotional_text.txt": 170,
    "description.txt": 4000,
    "release_notes.txt": 4000,
}
REVIEW_NOTES_LIMIT = 4000
DASHES = ("\u2013", "\u2014")
FREE = re.compile(r"\bfree\b", re.IGNORECASE)


def problems(metadata: pathlib.Path) -> list[str]:
    """One line per problem, empty when the text can go to the App Store."""
    found = []
    for language in sorted(p for p in metadata.iterdir() if p.is_dir()):
        if language.name == "review_information":
            continue
        for path in sorted(language.glob("*.txt")):
            text = path.read_text(encoding="utf-8").strip()
            where = f"{language.name}/{path.name}"
            limit = LIMITS.get(path.name)
            if limit is not None and len(text) > limit:
                found.append(f"{where}: {len(text)} characters, at most {limit}")
            if path.name != "name.txt" and any(dash in text for dash in DASHES):
                found.append(f"{where}: em or en dash")
            if FREE.search(text):
                found.append(f'{where}: says "free"')
    notes = metadata / "review_information" / "notes.txt"
    if notes.exists():
        text = notes.read_text(encoding="utf-8").strip()
        if len(text) > REVIEW_NOTES_LIMIT:
            found.append(
                f"review_information/notes.txt: {len(text)} characters, "
                f"at most {REVIEW_NOTES_LIMIT}"
            )
    return found


# The fields of a screenshot that it shows as text.
SCENE_TEXT = ("title", "lead", "question", "answer")


def scene_problems(scenes: pathlib.Path) -> list[str]:
    """The screenshots' headlines: no em or en dash, no "free"."""
    found = []
    for scene in json.loads(scenes.read_text(encoding="utf-8")):
        for field in SCENE_TEXT:
            text = scene.get(field) or ""
            where = f"{scenes.name}: {scene.get('file', '?')} {field}"
            if any(dash in text for dash in DASHES):
                found.append(f"{where}: em or en dash")
            if FREE.search(text):
                found.append(f'{where}: says "free"')
    return found


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("Usage: store_text.py <metadata dir> [<scenes.json>]", file=sys.stderr)
        return 2
    found = problems(pathlib.Path(sys.argv[1]))
    if len(sys.argv) == 3:
        found += scene_problems(pathlib.Path(sys.argv[2]))
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
