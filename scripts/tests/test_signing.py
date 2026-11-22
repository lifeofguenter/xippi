"""Making the signing files through the App Store Connect API: the token, the App ID, the
certificates as .p12 files the release job can read, and the profile. The API is a fake
that signs each request's CSR with a test CA standing in for Apple's intermediate."""

import base64
import datetime
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import release_secrets  # noqa: E402
import signing  # noqa: E402

AIA = "authorityInfoAccess = caIssuers;URI:http://certs.apple.com/wwdrg3.der\n"
TODAY = datetime.date(2027, 11, 1)


def openssl(*arguments, data=None):
    return subprocess.run([signing.OPENSSL, *arguments], input=data, capture_output=True,
                          check=True).stdout


def make_ca(folder: pathlib.Path, name: str) -> pathlib.Path:
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(folder / f"{name}.key"),
            "-subj", f"/CN={name}/OU=G3/O=Test/C=US", "-days", "2", "-out", str(folder / f"{name}.pem"))
    return folder / f"{name}.pem"


class FakeApi(signing.Api):
    """Answers as App Store Connect does; `bundles` and `apps` are what already exists."""

    def __init__(self, folder: pathlib.Path, bundles=True, apps=True):
        self.folder, self.requests = folder, []
        self.bundles, self.apps = bundles, apps
        self.ca = make_ca(folder, "Test WWDR")

    def call(self, method, path, body=None):
        self.requests.append((method, path, body))
        if method == "GET" and path.startswith("/v1/bundleIds"):
            found = [{"id": "B1", "attributes": {"identifier": "eu.xippi.XippiOther"}}]
            if self.bundles:
                found.append({"id": "B2", "attributes": {"identifier": signing.BUNDLE}})
            return {"data": found}
        if method == "POST" and path == "/v1/bundleIds":
            return {"data": {"id": "B3", "attributes": body["data"]["attributes"]}}
        if method == "POST" and path == "/v1/bundleIdCapabilities":
            return {"data": {"id": "C1"}}
        if method == "GET" and path.startswith("/v1/apps"):
            return {"data": [{"attributes": {"bundleId": signing.BUNDLE}}] if self.apps else []}
        if method == "GET" and path.startswith("/v1/certificates"):
            return {"data": []}
        if method == "POST" and path == "/v1/certificates":
            kind = body["data"]["attributes"]["certificateType"]
            csr = self.folder / f"{kind}.csr"
            csr.write_text(body["data"]["attributes"]["csrContent"])
            (self.folder / "aia.cnf").write_text(AIA)
            der = openssl("x509", "-req", "-in", str(csr), "-CA", str(self.ca),
                          "-CAkey", str(self.ca.with_suffix(".key")), "-CAcreateserial",
                          "-days", "1", "-extfile", str(self.folder / "aia.cnf"), "-outform", "DER")
            return {"data": {"id": f"cert-{kind}", "attributes": {
                "name": f"Test {kind}", "expirationDate": "2028-11-01T00:00:00.000+00:00",
                "certificateContent": base64.b64encode(der).decode()}}}
        if method == "POST" and path == "/v1/profiles":
            return {"data": {"id": "P1", "attributes": {
                "name": body["data"]["attributes"]["name"],
                "expirationDate": "2028-11-01T00:00:00.000+00:00",
                "profileContent": base64.b64encode(b"profile bytes").decode()}}}
        raise AssertionError(f"unexpected {method} {path}")

    def posted(self, path):
        return [body for method, called, body in self.requests if method == "POST" and called == path]


class TokenTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.dir / "ec.pem"))
        self.key = self.dir / "AuthKey_TEST123.p8"
        openssl("pkcs8", "-topk8", "-nocrypt", "-in", str(self.dir / "ec.pem"), "-out", str(self.key))

    @staticmethod
    def decoded(part):
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))

    def test_the_token_names_the_key_and_team_and_expires_in_ten_minutes(self):
        header, payload, _ = signing.token(self.key, "issuer-1", now=1000).split(".")
        self.assertEqual(self.decoded(header), {"alg": "ES256", "kid": "TEST123", "typ": "JWT"})
        self.assertEqual(self.decoded(payload),
                         {"iss": "issuer-1", "iat": 1000, "exp": 1600, "aud": "appstoreconnect-v1"})

    def test_the_signature_verifies_with_the_public_key(self):
        signed = signing.token(self.key, "issuer-1")
        message, signature = signed.rsplit(".", 1)
        raw = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
        self.assertEqual(len(raw), 64)

        def integer(value):
            value = value.lstrip(b"\0") or b"\0"
            if value[0] & 0x80:
                value = b"\0" + value
            return b"\x02" + bytes([len(value)]) + value

        body = integer(raw[:32]) + integer(raw[32:])
        (self.dir / "sig.der").write_bytes(b"\x30" + bytes([len(body)]) + body)
        public = openssl("ec", "-in", str(self.key), "-pubout")
        (self.dir / "pub.pem").write_bytes(public)
        result = subprocess.run(
            [signing.OPENSSL, "dgst", "-sha256", "-verify", str(self.dir / "pub.pem"),
             "-signature", str(self.dir / "sig.der")],
            input=message.encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class MakeTests(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.out = self.dir / "2027-11-01"
        self.api = FakeApi(self.dir)
        self.fetch = mock.patch.object(
            signing, "fetch", side_effect=self.serve_ca).start()
        self.addCleanup(mock.patch.stopall)
        mock.patch("builtins.print").start()

    def serve_ca(self, url):
        self.assertEqual(url, "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer")
        return openssl("x509", "-in", str(self.api.ca), "-outform", "DER")

    def passwords(self):
        lines = (self.out / "passwords.txt").read_text().splitlines()
        return dict(line.split("\t") for line in lines)

    def test_both_certificates_come_out_as_p12_files_with_their_passwords(self):
        self.assertEqual(signing.make(self.api, self.out, TODAY), 0)
        self.assertEqual(
            [body["data"]["attributes"]["certificateType"] for body in self.api.posted("/v1/certificates")],
            ["DISTRIBUTION", "MAC_INSTALLER_DISTRIBUTION"])
        passwords = self.passwords()
        self.assertEqual(set(passwords), {"distribution.p12", "installer.p12"})
        for name, password in passwords.items():
            with self.subTest(name=name):
                path = self.out / name
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                dump = openssl("pkcs12", "-in", str(path), "-passin", f"pass:{password}",
                               "-nodes").decode()
                # The key, its certificate and the intermediate.
                self.assertEqual(dump.count("BEGIN CERTIFICATE"), 2)
                self.assertIn("PRIVATE KEY", dump)
                self.assertIn("Test WWDR", dump)
        self.assertEqual((self.out / "passwords.txt").stat().st_mode & 0o777, 0o600)

    def test_the_profile_is_for_the_app_id_and_the_distribution_certificate(self):
        signing.make(self.api, self.out, TODAY)
        (body,) = self.api.posted("/v1/profiles")
        self.assertEqual(body["data"]["attributes"],
                         {"name": "Xippi Mac App Store 2027-11-01", "profileType": "MAC_APP_STORE"})
        relationships = body["data"]["relationships"]
        self.assertEqual(relationships["bundleId"]["data"]["id"], "B2")
        self.assertEqual(relationships["certificates"]["data"],
                         [{"type": "certificates", "id": "cert-DISTRIBUTION"}])
        self.assertEqual((self.out / "Xippi_Mac_App_Store.provisionprofile").read_bytes(),
                         b"profile bytes")
        self.assertEqual(self.api.posted("/v1/bundleIds"), [])

    def test_the_folder_is_what_release_secrets_takes(self):
        signing.make(self.api, self.out, TODAY)
        values = release_secrets.signing(self.out)
        self.assertEqual(values["DIST_CERT_PASSWORD"], self.passwords()["distribution.p12"])
        self.assertEqual(base64.b64decode(values["MAS_PROFILE"]), b"profile bytes")

    def test_a_missing_app_id_is_registered_for_every_platform_with_push(self):
        self.api.bundles = False
        signing.make(self.api, self.out, TODAY)
        (made,) = self.api.posted("/v1/bundleIds")
        self.assertEqual(made["data"]["attributes"],
                         {"identifier": "eu.xippi.Xippi", "name": "Xippi", "platform": "UNIVERSAL"})
        (capability,) = self.api.posted("/v1/bundleIdCapabilities")
        self.assertEqual(capability["data"]["attributes"]["capabilityType"], "PUSH_NOTIFICATIONS")
        self.assertEqual(capability["data"]["relationships"]["bundleId"]["data"]["id"], "B3")

    def test_without_the_app_in_app_store_connect_nothing_is_made(self):
        self.api.apps = False
        self.assertEqual(signing.make(self.api, self.out, TODAY), 1)
        self.assertEqual(self.api.posted("/v1/certificates"), [])
        self.assertFalse(self.out.exists())

    def test_a_folder_that_already_holds_signing_files_is_refused(self):
        self.out.mkdir()
        (self.out / "distribution.p12").write_bytes(b"old")
        with self.assertRaisesRegex(signing.SigningError, "new folder"):
            signing.make(self.api, self.out, TODAY)
        self.assertEqual(self.api.posted("/v1/certificates"), [])
        self.assertEqual((self.out / "distribution.p12").read_bytes(), b"old")

    def test_an_intermediate_that_did_not_issue_the_certificate_is_refused(self):
        other = make_ca(self.dir, "Other CA")
        self.fetch.side_effect = lambda url: openssl("x509", "-in", str(other), "-outform", "DER")
        with self.assertRaisesRegex(signing.SigningError, "does not match"):
            signing.make(self.api, self.out, TODAY)


if __name__ == "__main__":
    unittest.main()
