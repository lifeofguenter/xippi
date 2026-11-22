#!/usr/bin/env python3
"""Sets up the GitHub environment the release job uses (app-store, for v* tags only) and
all its secrets, from the files Apple gave you and a few answers. Run it again to replace
them, e.g. when the certificates are renewed.

Needs the GitHub CLI, signed in: brew install gh && gh auth login

Usage: scripts/release_secrets.py --api-key AuthKey_<id>.p8 --issuer <issuer id>
           --distribution <Apple Distribution .p12> --installer <Mac Installer .p12>
           --profile <Mac App Store .provisionprofile>
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
    "DIST_CERT_PASSWORD": ("Apple Distribution .p12 password", True),
    "INSTALLER_CERT_PASSWORD": ("Mac Installer Distribution .p12 password", True),
    "OPENAI_API_KEY": ("OpenAI API key", True),
    "REVIEW_FIRST_NAME": ("App Review contact, first name", False),
    "REVIEW_LAST_NAME": ("App Review contact, last name", False),
    "REVIEW_PHONE": ("App Review contact, phone with country code (+46 ...)", False),
    "REVIEW_DEMO_USER": ("App Review test account, address", False),
    "REVIEW_DEMO_PASSWORD": ("App Review test account, password", True),
}


def key_id(path: pathlib.Path) -> str:
    """The key's ID, from the name Apple gives the file: AuthKey_<id>.p8."""
    match = re.fullmatch(r"AuthKey_([A-Z0-9]+)\.p8", path.name)
    if not match:
        raise ValueError(f"{path.name}: not an App Store Connect key (AuthKey_<id>.p8)")
    return match.group(1)


def encoded(path: pathlib.Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()


def secrets(arguments: argparse.Namespace, answers: dict[str, str]) -> dict[str, str]:
    """Every secret the release job reads, by name."""
    values = {
        "ASC_KEY_ID": key_id(arguments.api_key),
        "ASC_ISSUER_ID": arguments.issuer,
        "ASC_KEY_P8": encoded(arguments.api_key),
        "DIST_CERT_P12": encoded(arguments.distribution),
        "INSTALLER_CERT_P12": encoded(arguments.installer),
        "MAS_PROFILE": encoded(arguments.profile),
    }
    values.update(answers)
    return values


def gh(*arguments: str, value: str | None = None) -> None:
    subprocess.run(["gh", *arguments], input=value, text=True, check=True, capture_output=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="The release job's GitHub environment and secrets")
    for option in ("api-key", "distribution", "installer", "profile"):
        parser.add_argument(f"--{option}", type=pathlib.Path, required=True)
    parser.add_argument("--issuer", required=True)
    arguments = parser.parse_args()
    for path in (arguments.api_key, arguments.distribution, arguments.installer, arguments.profile):
        if not path.is_file():
            parser.error(f"no file {path}")
    try:
        key_id(arguments.api_key)
    except ValueError as error:
        parser.error(str(error))

    answers = {}
    for name, (prompt, hidden) in QUESTIONS.items():
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

    for name, value in secrets(arguments, answers).items():
        gh("secret", "set", name, "--env", ENVIRONMENT, value=value)
        print(f"Set {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
