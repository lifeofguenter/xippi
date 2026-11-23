"""The secrets the release job gets: every one it reads, from the files Apple gives and the
folder scripts/signing.py writes."""

import argparse
import base64
import io
import pathlib
import re
import shutil
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import release_secrets  # noqa: E402

SIGNING_SECRETS = {
    "DIST_CERT_P12", "DIST_CERT_PASSWORD", "INSTALLER_CERT_P12", "INSTALLER_CERT_PASSWORD",
    "MAS_PROFILE",
}


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
        self.addCleanup(shutil.rmtree, self.dir)
        self.folder = self.dir / "signing"
        self.folder.mkdir()
        (self.folder / "distribution.p12").write_bytes(b"distribution bytes")
        (self.folder / "installer.p12").write_bytes(b"installer bytes")
        (self.folder / "Xippi_Mac_App_Store.provisionprofile").write_bytes(b"profile bytes")
        (self.folder / "passwords.txt").write_text(
            "distribution.p12\tdistribution secret\ninstaller.p12\tinstaller secret\n")
        key = self.dir / "AuthKey_ABC123.p8"
        key.write_bytes(b"api_key bytes")
        self.arguments = argparse.Namespace(signing=self.folder, api_key=key, issuer="issuer-1")
        self.answers = {name: f"{name} answer" for name in release_secrets.QUESTIONS}

    def test_every_secret_the_release_job_reads(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        job = workflow[workflow.index("\n  release:") :]
        read = set(re.findall(r"secrets\.([A-Z0-9_]+)", job))
        self.assertEqual(set(release_secrets.secrets(self.arguments, self.answers)), read)

    def test_files_go_in_as_base64_and_passwords_come_from_the_folder(self):
        values = release_secrets.secrets(self.arguments, self.answers)
        self.assertEqual(base64.b64decode(values["MAS_PROFILE"]), b"profile bytes")
        self.assertEqual(base64.b64decode(values["DIST_CERT_P12"]), b"distribution bytes")
        self.assertEqual(base64.b64decode(values["ASC_KEY_P8"]), b"api_key bytes")
        self.assertEqual(values["DIST_CERT_PASSWORD"], "distribution secret")
        self.assertEqual(values["INSTALLER_CERT_PASSWORD"], "installer secret")
        self.assertEqual(values["ASC_KEY_ID"], "ABC123")
        self.assertEqual(values["ASC_ISSUER_ID"], "issuer-1")

    def test_nothing_is_asked_for_that_a_file_holds(self):
        self.assertFalse(SIGNING_SECRETS & set(release_secrets.QUESTIONS))

    def test_renewal_sets_the_signing_secrets_only(self):
        renewal = argparse.Namespace(signing=self.folder, api_key=None, issuer=None)
        self.assertEqual(set(release_secrets.secrets(renewal, {})), SIGNING_SECRETS)

    def test_a_folder_missing_a_password_is_refused(self):
        (self.folder / "passwords.txt").write_text("distribution.p12\tdistribution secret\n")
        with self.assertRaisesRegex(ValueError, "installer.p12"):
            release_secrets.signing(self.folder)

    def test_a_renewal_sets_the_five_and_prints_no_secret(self):
        """Code scanning (CodeQL, py/clear-text-logging-sensitive-data) flagged a line per
        secret; the run prints one count and nothing that came out of secrets()."""
        set_calls = []
        policies = mock.Mock(stdout="tag v*\n")
        argv = ["release_secrets.py", "--signing", str(self.folder)]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(release_secrets, "gh", side_effect=lambda *a, value=None: set_calls.append((a, value))), \
                mock.patch.object(release_secrets.subprocess, "run", return_value=policies), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(release_secrets.main(), 0)
        secrets = {a[2]: value for a, value in set_calls if a[:2] == ("secret", "set")}
        self.assertEqual(set(secrets), SIGNING_SECRETS)
        self.assertEqual(secrets["INSTALLER_CERT_PASSWORD"], "installer secret")
        self.assertEqual(out.getvalue(), "Done: 5 secrets set in app-store\n")

    def test_a_folder_with_two_profiles_is_refused(self):
        (self.folder / "old.provisionprofile").write_bytes(b"old")
        with self.assertRaisesRegex(ValueError, "2 profiles"):
            release_secrets.signing(self.folder)


if __name__ == "__main__":
    unittest.main()
