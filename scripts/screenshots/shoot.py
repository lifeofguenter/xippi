#!/usr/bin/env python3
"""The App Store screenshots: every scene in scenes.json, captured from the Debug app on a
2x display of its own (display.m), then laid out by compose.swift into
fastlane/screenshots/en-US/.

The Debug app shares the installed app's preferences, so the saved window frame and
sidebar width are read before and put back if a capture changed them.

Usage: scripts/screenshots/shoot.py   (make screenshots builds the Debug app first)
"""

import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "scripts" / "screenshots"
OUTPUT = ROOT / "fastlane" / "screenshots" / "en-US"
CONTAINER = pathlib.Path.home() / "Library" / "Containers" / "eu.xippi.Xippi" / "Data"
PREFERENCES = CONTAINER / "Library" / "Preferences" / "eu.xippi.Xippi.plist"
SAVED = ("NSWindow Frame main", "NSSplitView Subview Frames main, SidebarNavigationSplitView")

SCREEN = "Screenshots"
WINDOW = "1240x780"
SIDEBAR = "290"
# The website's page colours: what the windows are captured on and the canvas is.
BACKDROPS = {"light": "#fdeee8", "dark": "#3b2730"}
# Every scene: accounts online, room pictures, the app in front (grey window controls
# otherwise), then its own steps, then the capture.
FIRST_STEPS = ["online", "roompictures", "front"]


def steps(scene: dict) -> str:
    """The app's -UITestAction for a scene."""
    own = [step for step in scene.get("steps", "").split(";") if step.strip()]
    return ";".join(FIRST_STEPS + own + [f"composite {BACKDROPS[scene['look']]}"])


def launch_arguments(scene: dict) -> list[str]:
    """The Debug app's arguments for a scene: the store's chats, the 2x screen, one capture."""
    return [
        "-UITestSeed", "store",
        "-UITestSnapshot", f"{scene['file']}.png",
        "-UITestSnapshotDelay", "4",
        "-UITestAppearance", scene["look"],
        "-UITestOpenChat", scene.get("chat", ""),
        "-UITestScreen", SCREEN,
        "-UITestWindowSize", WINDOW,
        "-UITestSidebarWidth", SIDEBAR,
        "-UITestAction", steps(scene),
        "-ApplePersistenceIgnoreState", "YES",
    ]


def saved_values() -> dict:
    """The window frame and sidebar width the installed app keeps, as the system has them."""
    exported = subprocess.run(
        ["defaults", "export", str(PREFERENCES), "-"], capture_output=True, check=True
    ).stdout
    values = plistlib.loads(exported)
    return {key: values.get(key) for key in SAVED}


def restore(values: dict) -> None:
    for key, value in values.items():
        if value is None:
            subprocess.run(["defaults", "delete", str(PREFERENCES), key], check=False)
        elif isinstance(value, list):
            subprocess.run(
                ["defaults", "write", str(PREFERENCES), key, "-array", *map(str, value)], check=True
            )
        else:
            subprocess.run(["defaults", "write", str(PREFERENCES), key, "-string", str(value)], check=True)


def debug_app() -> pathlib.Path:
    settings = subprocess.run(
        ["xcodebuild", "-project", str(ROOT / "Xippi.xcodeproj"), "-scheme", "Xippi",
         "-configuration", "Debug", "-showBuildSettings"],
        capture_output=True, text=True, check=True,
    ).stdout
    for line in settings.splitlines():
        name, _, value = line.strip().partition(" = ")
        if name == "BUILT_PRODUCTS_DIR":
            return pathlib.Path(value) / "Xippi.app"
    sys.exit("No Debug build: make build CONFIGURATION=Debug")


def capture(app: pathlib.Path, scene: dict, into: pathlib.Path) -> None:
    temporary = CONTAINER / "tmp"
    for old in temporary.glob(f"{scene['file']}.*"):
        old.unlink()
    subprocess.run(
        ["open", "-n", "-W", str(app), "--args", *launch_arguments(scene)], check=True, timeout=180
    )
    for suffix in ("composite.png", "composite.json"):
        made = temporary / f"{scene['file']}.{suffix}"
        if not made.exists():
            sys.exit(f"No capture: {scene['file']}")
        shutil.copy(made, into / made.name)


def main() -> None:
    scenes = json.loads((HERE / "scenes.json").read_text())
    app = debug_app()
    if not app.exists():
        sys.exit(f"No Debug build at {app}: make build CONFIGURATION=Debug")
    photos = CONTAINER / "tmp" / "StorePhotos"
    shutil.rmtree(photos, ignore_errors=True)
    photos.mkdir(parents=True)
    for photo in (HERE / "photos").glob("*.jpg"):
        shutil.copy(photo, photos / photo.name)

    before = saved_values()
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        subprocess.run(
            ["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
             str(HERE / "display.m"), "-o", str(work / "display")],
            check=True,
        )
        # The display is there while this runs: its input closing removes it.
        display = subprocess.Popen(
            [str(work / "display")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
        )
        try:
            if display.stdout is None or not display.stdout.readline().startswith("ready"):
                sys.exit("No 2x display")
            for scene in scenes:
                print(scene["file"], flush=True)
                capture(app, scene, work)
        finally:
            if display.stdin:
                display.stdin.close()
            display.wait(timeout=10)
            after = saved_values()
            if after != before:
                restore(before)
                print("Put back the installed app's window frame and sidebar width")

        OUTPUT.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["swift", str(HERE / "compose.swift"), str(HERE / "scenes.json"), str(work), str(OUTPUT)],
            check=True,
        )
    keep = {f"{scene['file']}.png" for scene in scenes}
    for old in OUTPUT.glob("*.png"):
        if old.name not in keep:
            old.unlink()


if __name__ == "__main__":
    main()
