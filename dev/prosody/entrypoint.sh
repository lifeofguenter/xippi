#!/bin/bash
# Creates the test accounts, then hands over to the image's own entrypoint.
# prosodyctl register resets the password of an account that already exists,
# so a restarted container ends up with the same accounts.
set -euo pipefail

for user in alice bob carol admin; do
    prosodyctl register "$user" prosody.test xippi-test
done

exec /entrypoint.sh "$@"
