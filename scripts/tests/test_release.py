"""The release logic CI runs on a tag: which version, whether it may ship, its notes."""

import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import release  # noqa: E402


class TagTests(unittest.TestCase):
    def test_a_plain_tag_is_a_release(self):
        self.assertEqual(release.parse_tag("v0.1.0"), ("0.1.0", False))

    def test_a_suffix_makes_a_prerelease_of_the_same_version(self):
        self.assertEqual(release.parse_tag("v0.1.0-beta.1"), ("0.1.0", True))
        self.assertEqual(release.parse_tag("v1.20.3-rc1"), ("1.20.3", True))

    def test_other_tags_are_refused(self):
        for tag in ("0.1.0", "v1.2", "v1.2.3.4", "release-1", "v1.2.3-"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.parse_tag(tag)

    def test_the_previous_release_is_the_highest_plain_tag_below(self):
        tags = ["v0.1.0", "v0.1.1-beta.1", "v0.1.1", "v0.2.0-beta.1", "v0.10.0", "other"]
        self.assertEqual(release.previous_tag(tags, "v0.2.0"), "v0.1.1")
        self.assertEqual(release.previous_tag(tags, "v0.2.0-beta.2"), "v0.1.1")
        self.assertEqual(release.previous_tag(tags, "v0.11.0"), "v0.10.0")
        # By number, not as text: "v0.9.0" sorts after "v0.10.0" as a string.
        self.assertEqual(release.previous_tag(["v0.9.0", "v0.10.0"], "v0.11.0"), "v0.10.0")

    def test_the_first_release_has_none(self):
        self.assertIsNone(release.previous_tag(["v0.1.0-beta.1"], "v0.1.0"))
        self.assertIsNone(release.previous_tag([], "v0.1.0-beta.1"))


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.dir), *args], check=True, capture_output=True, text=True
        ).stdout.strip()

    def commit(self, message):
        self.git("commit", "--allow-empty", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_a_commit_on_main_may_ship_and_one_off_it_may_not(self):
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "ci@example.org")
        self.git("config", "user.name", "CI")
        merged = self.commit("on main")
        self.git("switch", "-q", "-c", "feature")
        unmerged = self.commit("on a branch")
        self.assertTrue(release.on_branch(merged, "main", cwd=self.dir))
        self.assertFalse(release.on_branch(unmerged, "main", cwd=self.dir))

    def plist(self, values):
        path = self.dir / "Info.plist"
        path.write_bytes(plistlib.dumps(values))
        return path

    def test_no_build_without_an_encryption_answer(self):
        problem = release.compliance_problem(self.plist({}))
        self.assertIn("no ITSAppUsesNonExemptEncryption", problem)

    def test_no_documents_needed_ships(self):
        self.assertIsNone(
            release.compliance_problem(self.plist({"ITSAppUsesNonExemptEncryption": False}))
        )

    def test_no_build_without_the_export_compliance_code(self):
        problem = release.compliance_problem(self.plist({"ITSAppUsesNonExemptEncryption": True}))
        self.assertIn("ITSEncryptionExportComplianceCode", problem)
        self.assertIsNone(
            release.compliance_problem(
                self.plist(
                    {
                        "ITSAppUsesNonExemptEncryption": True,
                        "ITSEncryptionExportComplianceCode": "abc",
                    }
                )
            )
        )


class NotesTests(unittest.TestCase):
    def test_long_dashes_become_hyphens(self):
        cleaned = release.clean_notes("- Calls \u2014 now ring\n- Search \u2013 faster\n")
        self.assertEqual(cleaned, "- Calls - now ring\n- Search - faster")

    def test_notes_over_the_limit_end_at_a_whole_line(self):
        lines = [f"- Change {n:04d} " + "x" * 40 for n in range(200)]
        cleaned = release.clean_notes("\n".join(lines))
        self.assertLessEqual(len(cleaned), release.NOTES_LIMIT)
        self.assertTrue(cleaned.endswith("x" * 40))
        self.assertIn(cleaned.splitlines()[-1], lines)

    def test_the_request_asks_the_pinned_model(self):
        body = release.notes_request("the changes")
        self.assertEqual(body["model"], "gpt-6.2-sol")
        self.assertEqual(body["input"], "the changes")
        self.assertIn("No em dash or en dash", body["instructions"])
        self.assertIn("free", body["instructions"])
        self.assertFalse(body["store"])
        self.assertGreater(body["max_output_tokens"], 0)

    def test_the_text_is_read_from_the_message_not_the_first_item(self):
        response = {
            "output": [
                {"type": "reasoning", "summary": []},
                {
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": "- Calls ring\n"},
                        {"type": "output_text", "text": "- Search is faster"},
                    ],
                },
            ]
        }
        self.assertEqual(release.notes_text(response), "- Calls ring\n- Search is faster")

    def test_a_response_without_text_fails(self):
        with self.assertRaises(RuntimeError):
            release.notes_text({"output": [{"type": "reasoning", "summary": []}]})

    def test_the_first_release_asks_nobody(self):
        def ask(_):
            raise AssertionError("asked OpenAI for a first release")

        self.assertEqual(release.write_notes("v0.1.0", [], ask=ask), release.FIRST_RELEASE)

    def test_a_later_release_sends_the_changes_since_the_previous_one(self):
        sent = []

        def ask(changes):
            sent.append(changes)
            return "- Calls \u2014 ring"

        notes = release.write_notes(
            "v0.2.0", ["v0.1.0"], ask=ask, changes=lambda prev, tag: f"{prev}..{tag}"
        )
        self.assertEqual(sent, ["v0.1.0..v0.2.0"])
        self.assertEqual(notes, "- Calls - ring")


if __name__ == "__main__":
    unittest.main()
