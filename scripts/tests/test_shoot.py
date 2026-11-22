"""What the screenshot script asks of the Debug app for each scene."""

import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "screenshots"))

import shoot  # noqa: E402


def scene(**fields):
    return {"file": "1-chat", "look": "light", "chat": "Weekend in the Alps", "steps": "", **fields}


class StepsTests(unittest.TestCase):
    def test_accounts_online_and_in_front_before_the_scenes_own_steps(self):
        steps = shoot.steps(scene(steps="inspector;verified")).split(";")
        self.assertEqual(steps[:5], ["online", "roompictures", "front", "inspector", "verified"])

    def test_the_capture_is_last_on_the_page_colour_of_its_look(self):
        self.assertEqual(shoot.steps(scene()).split(";")[-1], "composite #fdeee8")
        self.assertEqual(shoot.steps(scene(look="dark")).split(";")[-1], "composite #3b2730")

    def test_empty_steps_add_nothing(self):
        self.assertEqual(
            shoot.steps(scene(steps=" ;")), "online;roompictures;front;composite #fdeee8"
        )


class LaunchTests(unittest.TestCase):
    def value(self, arguments, name):
        return arguments[arguments.index(name) + 1]

    def test_the_store_chats_on_the_2x_screen_at_one_size(self):
        arguments = shoot.launch_arguments(scene())
        self.assertEqual(self.value(arguments, "-UITestSeed"), "store")
        self.assertEqual(self.value(arguments, "-UITestScreen"), "Screenshots")
        self.assertEqual(self.value(arguments, "-UITestWindowSize"), "1240x780")
        self.assertEqual(self.value(arguments, "-UITestSnapshot"), "1-chat.png")
        self.assertEqual(self.value(arguments, "-UITestAppearance"), "light")
        self.assertEqual(self.value(arguments, "-UITestOpenChat"), "Weekend in the Alps")

    def test_a_scene_without_a_chat_opens_none(self):
        arguments = shoot.launch_arguments({"file": "3-replies", "look": "dark", "steps": ""})
        self.assertEqual(self.value(arguments, "-UITestOpenChat"), "")

    def test_the_display_tool_names_the_screen_the_app_looks_for(self):
        display = (ROOT / "scripts" / "screenshots" / "display.m").read_text()
        self.assertIn(f'name = @"{shoot.SCREEN}"', display)


class ScenesTests(unittest.TestCase):
    def test_every_scene_has_a_file_a_look_and_a_headline(self):
        scenes = json.loads((ROOT / "scripts" / "screenshots" / "scenes.json").read_text())
        self.assertGreaterEqual(len(scenes), 1)
        self.assertLessEqual(len(scenes), 10)  # the App Store takes at most ten
        for item in scenes:
            with self.subTest(file=item.get("file")):
                self.assertIn(item["look"], shoot.BACKDROPS)
                self.assertTrue(item.get("title") or (item.get("question") and item.get("answer")))
        self.assertEqual(len({item["file"] for item in scenes}), len(scenes))


if __name__ == "__main__":
    unittest.main()
