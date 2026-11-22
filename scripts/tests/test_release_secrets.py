"""The secrets the release job gets: every one it reads, from the files Apple gives."""

import argparse
import base64
import pathlib
import re
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import release_secrets  # noqa: E402


class KeyIdTests(unittest.TestCase):
    def test_the_id_is_in_the_file_name(self):
        self.assertEqual(release_secrets.key_id(pathlib.Path("/x/AuthKey_2X9R4HXF34.p8")), "2X9R4HXF34")

    def test_another_file_is_refused(self):
        for name in ("key.p8", "AuthKey_.p8", "AuthKey_ABC.p12"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_secrets.key_id(pathlib.Path(name))


class SecretsTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(lambda: [p.unlink() for p in self.dir.iterdir()] and None)
        files = {}
        for option, name in (
            ("api_key", "AuthKey_ABC123.p8"),
            ("distribution", "distribution.p12"),
            ("installer", "installer.p12"),
            ("profile", "Xippi.provisionprofile"),
        ):
            path = self.dir / name
            path.write_bytes(f"{option} bytes".encode())
            files[option] = path
        self.arguments = argparse.Namespace(issuer="issuer-1", **files)
        self.answers = {name: f"{name} answer" for name in release_secrets.QUESTIONS}

    def test_every_secret_the_release_job_reads(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        job = workflow[workflow.index("\n  release:") :]
        read = set(re.findall(r"secrets\.([A-Z0-9_]+)", job))
        self.assertEqual(set(release_secrets.secrets(self.arguments, self.answers)), read)

    def test_files_go_in_as_base64(self):
        values = release_secrets.secrets(self.arguments, self.answers)
        self.assertEqual(base64.b64decode(values["MAS_PROFILE"]), b"profile bytes")
        self.assertEqual(base64.b64decode(values["ASC_KEY_P8"]), b"api_key bytes")
        self.assertEqual(values["ASC_KEY_ID"], "ABC123")
        self.assertEqual(values["ASC_ISSUER_ID"], "issuer-1")


if __name__ == "__main__":
    unittest.main()
