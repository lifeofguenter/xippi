#!/usr/bin/env python3
"""Makes what the release job signs with, through the App Store Connect API: the Apple
Distribution and Mac Installer Distribution certificates, as .p12 files with their
passwords, and a Mac App Store profile for eu.xippi.Xippi. Registers the App ID first if
there is none. Run it to set up from scratch and to renew, then hand the folder to
scripts/release_secrets.py --signing.

Needs an App Store Connect team key (App Manager is enough).

Usage: scripts/signing.py --api-key AuthKey_<id>.p8 --issuer <issuer id> --out <new folder>
"""

import argparse
import base64
import datetime
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BUNDLE = "eu.xippi.Xippi"
API = "https://api.appstoreconnect.apple.com"
# macOS's own: its .p12 files are the kind `security import` reads on every macOS.
OPENSSL = "/usr/bin/openssl"
# The file name each certificate is written to, by type.
CERTIFICATES = {"DISTRIBUTION": "distribution.p12", "MAC_INSTALLER_DISTRIBUTION": "installer.p12"}
PASSWORDS = "passwords.txt"


class SigningError(Exception):
    pass


def openssl(*arguments: str, data: bytes | None = None, env: dict | None = None) -> bytes:
    result = subprocess.run(
        [OPENSSL, *arguments], input=data, capture_output=True,
        env={**os.environ, **(env or {})})
    if result.returncode != 0:
        raise SigningError(f"openssl {arguments[0]}: {result.stderr.decode().strip()}")
    return result.stdout


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der: bytes) -> bytes:
    """An ECDSA signature as JWT wants it, r and s of 32 bytes each, from the DER that
    openssl writes: SEQUENCE { INTEGER r, INTEGER s }."""
    def integer(at: int) -> tuple[bytes, int]:
        if der[at] != 0x02:
            raise SigningError("not an ECDSA signature")
        length = der[at + 1]
        value = der[at + 2 : at + 2 + length].lstrip(b"\0")
        return value.rjust(32, b"\0"), at + 2 + length

    if der[0] != 0x30:
        raise SigningError("not an ECDSA signature")
    start = 3 if der[1] & 0x80 else 2
    r, after = integer(start)
    s, _ = integer(after)
    return r + s


def token(key: pathlib.Path, issuer: str, now: int | None = None) -> str:
    """A token for the API, valid 10 minutes, signed with the team key (ES256)."""
    now = int(time.time()) if now is None else now
    header = {"alg": "ES256", "kid": key_id(key), "typ": "JWT"}
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signed = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
    der = openssl("dgst", "-sha256", "-sign", str(key), data=signed.encode())
    return f"{signed}.{b64url(raw_signature(der))}"


def key_id(path: pathlib.Path) -> str:
    """The key's ID, from the name Apple gives the file: AuthKey_<id>.p8."""
    match = re.fullmatch(r"AuthKey_([A-Z0-9]+)\.p8", path.name)
    if not match:
        raise SigningError(f"{path.name}: not an App Store Connect key (AuthKey_<id>.p8)")
    return match.group(1)


class Api:
    def __init__(self, key: pathlib.Path, issuer: str):
        self.key, self.issuer = key, issuer

    def send(self, request: urllib.request.Request) -> dict:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
        return json.loads(body) if body else {}

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        request = urllib.request.Request(
            API + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {token(self.key, self.issuer)}",
                     "Content-Type": "application/json"})
        try:
            return self.send(request)
        except urllib.error.HTTPError as error:
            errors = json.loads(error.read() or b"{}").get("errors") or [{}]
            raise SigningError(
                f"{method} {path}: {error.code} {errors[0].get('title')}: {errors[0].get('detail')}")


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def app_id(api: Api) -> str:
    """The App ID's resource id; registered, for every platform and with push, if missing."""
    found = api.call("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE}")["data"]
    for bundle in found:
        if bundle["attributes"]["identifier"] == BUNDLE:
            return bundle["id"]
    made = api.call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE, "name": "Xippi", "platform": "UNIVERSAL"}}})["data"]
    api.call("POST", "/v1/bundleIdCapabilities", {"data": {
        "type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": made["id"]}}}}})
    print(f"Registered App ID {BUNDLE}")
    return made["id"]


def has_app(api: Api) -> bool:
    found = api.call("GET", f"/v1/apps?filter[bundleId]={BUNDLE}")["data"]
    return any(app["attributes"]["bundleId"] == BUNDLE for app in found)


def intermediate(certificate_pem: bytes) -> bytes:
    """The Apple intermediate that issued the certificate, as PEM, from Apple's site over
    HTTPS (the address in the certificate is plain HTTP)."""
    text = openssl("x509", "-noout", "-text", data=certificate_pem).decode()
    match = re.search(r"CA Issuers - URI:http://certs\.apple\.com/wwdrg(\d+)\.der", text)
    if not match:
        raise SigningError("the certificate names no Apple intermediate it knows")
    der = fetch(f"https://www.apple.com/certificateauthority/AppleWWDRCAG{match.group(1)}.cer")
    pem = openssl("x509", "-inform", "DER", data=der)
    issuer = openssl("x509", "-noout", "-issuer", data=certificate_pem).split(b"=", 1)[1]
    subject = openssl("x509", "-noout", "-subject", data=pem).split(b"=", 1)[1]
    if issuer.strip() != subject.strip():
        raise SigningError("Apple's intermediate does not match the certificate's issuer")
    return pem


def certificate(api: Api, kind: str, out: pathlib.Path, work: pathlib.Path) -> tuple[str, str]:
    """A new certificate of `kind`, written to `out` as a .p12 with a new password: its
    resource id and the password."""
    key, csr = work / f"{kind}.key", work / f"{kind}.csr"
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
            "-subj", "/CN=xippi-ci", "-out", str(csr))
    made = api.call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": kind, "csrContent": csr.read_text()}}})["data"]
    attributes = made["attributes"]
    pem = openssl("x509", "-inform", "DER",
                  data=base64.b64decode(attributes["certificateContent"]))
    (work / f"{kind}.pem").write_bytes(pem)
    (work / f"{kind}-ca.pem").write_bytes(intermediate(pem))
    password = secrets.token_urlsafe(24)
    openssl("pkcs12", "-export", "-inkey", str(key), "-in", str(work / f"{kind}.pem"),
            "-certfile", str(work / f"{kind}-ca.pem"), "-name", attributes["name"],
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
            "-passout", "env:XIPPI_P12_PASSWORD", "-out", str(out),
            env={"XIPPI_P12_PASSWORD": password})
    out.chmod(0o600)
    print(f"Made {attributes['name']} ({kind}), until {attributes['expirationDate'][:10]}: {out}")
    return made["id"], password


def profile(api: Api, bundle: str, distribution: str, out: pathlib.Path, today: datetime.date) -> pathlib.Path:
    """A Mac App Store profile for the App ID and the distribution certificate, named for
    the day so it never clashes with the one it replaces."""
    name = f"Xippi Mac App Store {today.isoformat()}"
    made = api.call("POST", "/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": name, "profileType": "MAC_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
            "certificates": {"data": [{"type": "certificates", "id": distribution}]}}}})["data"]
    path = out / "Xippi_Mac_App_Store.provisionprofile"
    path.write_bytes(base64.b64decode(made["attributes"]["profileContent"]))
    print(f"Made profile {name}, until {made['attributes']['expirationDate'][:10]}: {path}")
    return path


def make(api: Api, out: pathlib.Path, today: datetime.date) -> int:
    bundle = app_id(api)
    if not has_app(api):
        print(f"No app for {BUNDLE} in App Store Connect: make it (docs/app-store-setup.md), "
              "then run this again", file=sys.stderr)
        return 1
    current = api.call(
        "GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION,MAC_INSTALLER_DISTRIBUTION"
        "&limit=200")["data"]
    for item in current:
        attributes = item["attributes"]
        print(f"Existing {attributes['certificateType']} until "
              f"{attributes['expirationDate'][:10]}: {item['id']}")

    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    taken = [name for name in [*CERTIFICATES.values(), PASSWORDS] if (out / name).exists()]
    if taken or list(out.glob("*.provisionprofile")):
        raise SigningError(f"{out} already holds signing files: use a new folder")
    passwords = {}
    with tempfile.TemporaryDirectory() as work:
        ids = {}
        for kind, file in CERTIFICATES.items():
            ids[kind], passwords[file] = certificate(api, kind, out / file, pathlib.Path(work))
    profile(api, bundle, ids["DISTRIBUTION"], out, today)
    descriptor = os.open(out / PASSWORDS, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as file:
        for name, password in passwords.items():
            file.write(f"{name}\t{password}\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Signing certificates and profile for the release job")
    parser.add_argument("--api-key", type=pathlib.Path, required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    if not arguments.api_key.is_file():
        parser.error(f"no file {arguments.api_key}")
    try:
        key_id(arguments.api_key)
        return make(Api(arguments.api_key, arguments.issuer), arguments.out, datetime.date.today())
    except SigningError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
