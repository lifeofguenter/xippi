#!/usr/bin/env python3
"""Sets up the GitHub environment the release job uses (app-store, for v* tags only) and
its secrets: the signing files from the folder scripts/signing.py wrote, and with the API
key all the others too, asking for those no file holds.

Needs the GitHub CLI, signed in: brew install gh && gh auth login

Usage: scripts/release_secrets.py --api-key AuthKey_<id>.p8 --issuer <issuer id> --signing <folder>
       scripts/release_secrets.py --signing <folder>    (renewed certificates: those only)
"""

import argparse
import base64
import getpass
import pathlib
import re
import subprocess
import sys

ENVIRONMENT = "app-store"

# What is asked for, by secret: the prompt, and whether it is hidden as it is typed.
QUESTIONS = {
    "OPENAI_API_KEY": ("OpenAI API key", True),
    "REVIEW_FIRST_NAME": ("App Review contact, first name", False),
    "REVIEW_LAST_NAME": ("App Review contact, last name", False),
    "REVIEW_PHONE": ("App Review contact, phone with country code (+46 ...)", False),
    "REVIEW_DEMO_USER": ("App Review test account, address", False),
    "REVIEW_DEMO_PASSWORD": ("App Review test account, password", True),
}


# The files scripts/signing.py writes, and the secret each goes into.
SIGNING_FILES = {"distribution.p12": "DIST_CERT", "installer.p12": "INSTALLER_CERT"}
PASSWORDS = "passwords.txt"


def key_id(path: pathlib.Path) -> str:
    """The key's ID, from the name Apple gives the file: AuthKey_<id>.p8."""
    match = re.fullmatch(r"AuthKey_([A-Z0-9]+)\.p8", path.name)
    if not match:
        raise ValueError(f"{path.name}: not an App Store Connect key (AuthKey_<id>.p8)")
    return match.group(1)


def encoded(path: pathlib.Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()


def signing(folder: pathlib.Path) -> dict[str, str]:
    """The signing secrets, from the folder scripts/signing.py wrote: both .p12 files with
    their passwords, and the one profile."""
    passwords = {}
    if (folder / PASSWORDS).is_file():
        for line in (folder / PASSWORDS).read_text().splitlines():
            name, _, password = line.partition("\t")
            passwords[name] = password
    values = {}
    for file, secret in SIGNING_FILES.items():
        if not (folder / file).is_file() or not passwords.get(file):
            raise ValueError(f"{folder}: no {file} with its password in {PASSWORDS}")
        values[f"{secret}_P12"] = encoded(folder / file)
        values[f"{secret}_PASSWORD"] = passwords[file]
    profiles = sorted(folder.glob("*.provisionprofile"))
    if len(profiles) != 1:
        raise ValueError(f"{folder}: {len(profiles)} profiles, not one")
    values["MAS_PROFILE"] = encoded(profiles[0])
    return values


def secrets(arguments: argparse.Namespace, answers: dict[str, str]) -> dict[str, str]:
    """The secrets to set, by name: the signing ones, and with the API key every other one
    the release job reads."""
    values = signing(arguments.signing)
    if arguments.api_key:
        values.update({
            "ASC_KEY_ID": key_id(arguments.api_key),
            "ASC_ISSUER_ID": arguments.issuer,
            "ASC_KEY_P8": encoded(arguments.api_key),
        })
        values.update(answers)
    return values


def gh(*arguments: str, value: str | None = None) -> None:
    subprocess.run(["gh", *arguments], input=value, text=True, check=True, capture_output=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="The release job's GitHub environment and secrets")
    parser.add_argument("--signing", type=pathlib.Path, required=True)
    parser.add_argument("--api-key", type=pathlib.Path)
    parser.add_argument("--issuer")
    arguments = parser.parse_args()
    if bool(arguments.api_key) != bool(arguments.issuer):
        parser.error("--api-key and --issuer go together")
    try:
        signing(arguments.signing)
        if arguments.api_key:
            if not arguments.api_key.is_file():
                raise ValueError(f"no file {arguments.api_key}")
            key_id(arguments.api_key)
    except ValueError as error:
        parser.error(str(error))

    answers = {}
    for name, (prompt, hidden) in QUESTIONS.items() if arguments.api_key else ():
        value = (getpass.getpass if hidden else input)(f"{prompt}: ").strip()
        if not value:
            print(f"Aborted: no {prompt}", file=sys.stderr)
            return 1
        answers[name] = value

    # The environment, open to v* tags only, so no branch or pull request reaches its secrets.
    gh("api", "-X", "PUT", f"repos/{{owner}}/{{repo}}/environments/{ENVIRONMENT}",
       "-F", "deployment_branch_policy[protected_branches]=false",
       "-F", "deployment_branch_policy[custom_branch_policies]=true")
    policies = subprocess.run(
        ["gh", "api", f"repos/{{owner}}/{{repo}}/environments/{ENVIRONMENT}/deployment-branch-policies",
         "--jq", ".branch_policies[] | .type + \" \" + .name"],
        text=True, check=True, capture_output=True,
    ).stdout.split("\n")
    if "tag v*" not in policies:
        gh("api", "-X", "POST",
           f"repos/{{owner}}/{{repo}}/environments/{ENVIRONMENT}/deployment-branch-policies",
           "-f", "name=v*", "-f", "type=tag")

    values = secrets(arguments, answers)
    for name, value in values.items():
        gh("secret", "set", name, "--env", ENVIRONMENT, value=value)
    # A count, not the names: nothing that came out of secrets() reaches the terminal.
    print(f"Done: {len(values)} secrets set in {ENVIRONMENT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
