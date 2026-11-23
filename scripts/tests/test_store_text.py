"""The App Store text: Apple's limits, no long dash outside the name, no word "free"."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import store_text  # noqa: E402

METADATA = ROOT / "fastlane" / "metadata"
SCENES = ROOT / "scripts" / "screenshots" / "scenes.json"


class StoreTextTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.metadata = self.dir / "metadata"
        shutil.copytree(METADATA, self.metadata)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, name, text):
        (self.metadata / "en-US" / name).write_text(text, encoding="utf-8")

    def test_the_repos_text_passes(self):
        self.assertEqual(store_text.problems(METADATA), [])

    def test_a_subtitle_over_30_characters_fails(self):
        self.write("subtitle.txt", "x" * 31)
        self.assertEqual(
            store_text.problems(self.metadata), ["en-US/subtitle.txt: 31 characters, at most 30"]
        )

    def test_every_limit_is_checked(self):
        for name, limit in store_text.LIMITS.items():
            with self.subTest(name=name):
                self.write(name, "x" * (limit + 1))
                self.assertIn(
                    f"en-US/{name}: {limit + 1} characters, at most {limit}",
                    store_text.problems(self.metadata),
                )

    def test_a_long_dash_outside_the_name_fails(self):
        for dash in ("\u2013", "\u2014"):
            with self.subTest(dash=dash):
                self.write("description.txt", f"Chat {dash} on any server.")
                self.assertEqual(
                    store_text.problems(self.metadata),
                    ["en-US/description.txt: em or en dash"],
                )

    def test_the_name_may_carry_its_dash(self):
        self.write("name.txt", "Xippi \u2013 XMPP Messenger")
        self.assertEqual(store_text.problems(self.metadata), [])

    def test_the_word_free_fails(self):
        self.write("promotional_text.txt", "Free for everyone who downloads it now.")
        self.assertEqual(
            store_text.problems(self.metadata), ["en-US/promotional_text.txt: says \"free\""]
        )

    def test_free_inside_another_word_passes(self):
        self.write("promotional_text.txt", "Hands-freedom.")
        self.assertEqual(store_text.problems(self.metadata), [])

    def test_review_notes_are_held_to_their_limit(self):
        (self.metadata / "review_information" / "notes.txt").write_text("x" * 4001)
        self.assertEqual(
            store_text.problems(self.metadata),
            ["review_information/notes.txt: 4001 characters, at most 4000"],
        )


if __name__ == "__main__":
    unittest.main()


class SceneTextTests(unittest.TestCase):
    """The screenshots' headlines follow the same rules as the store text."""

    def scenes(self, **text):
        directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        path = directory / "scenes.json"
        path.write_text(json.dumps([{"file": "1-chat", "look": "light", **text}]), encoding="utf-8")
        return path

    def test_the_repos_headlines_pass(self):
        self.assertEqual(store_text.scene_problems(SCENES), [])

    def test_a_long_dash_in_a_headline_fails(self):
        for field in store_text.SCENE_TEXT:
            with self.subTest(field=field):
                path = self.scenes(**{field: "Native \u2014 and secure"})
                self.assertEqual(
                    store_text.scene_problems(path), [f"scenes.json: 1-chat {field}: em or en dash"]
                )

    def test_free_in_a_headline_fails(self):
        path = self.scenes(answer="Free for everyone")
        self.assertEqual(store_text.scene_problems(path), ['scenes.json: 1-chat answer: says "free"'])

    def test_freely_is_not_free(self):
        self.assertEqual(store_text.scene_problems(self.scenes(title="Chat freely, on your Mac.")), [])

    def test_the_check_reads_the_scenes_it_is_given(self):
        path = self.scenes(answer="Free for everyone")
        run = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "store_text.py"), str(METADATA), str(path)],
            capture_output=True, text=True,
        )
        self.assertEqual(run.returncode, 1)
        self.assertIn('says "free"', run.stdout)
