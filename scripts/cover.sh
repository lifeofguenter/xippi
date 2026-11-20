#!/bin/bash
# Package tests with code coverage, for `make cover` and CI.
#
#   scripts/cover.sh PACKAGE...        FILTER=<Suite> narrows the tests, as in make test
#
# Every package runs even after one fails, so one run shows every failing test. Writes:
#   test-results/<Package>*.xml   xUnit results    (scripts/test-summary.py)
#   coverage/coverage.json        llvm-cov export  (scripts/coverage-summary.mjs)
#   coverage/coverage.xml         Cobertura        (GitHub code coverage)
# Both coverage reports hold each package's own sources only: a package's profile also
# covers the local packages it depends on and its tests, which would count those twice.
set -eo pipefail
cd "$(dirname "$0")/.."

rm -rf coverage test-results
mkdir -p coverage test-results
failed=()
reports=()
lcov=()
for p in "$@"; do
    echo "==> $p"
    codecov="$(dirname "$(swift test --package-path "Packages/$p" --show-codecov-path)")"
    rm -f "$codecov"/*.profraw

    args=(--package-path "Packages/$p" --enable-code-coverage --xunit-output "test-results/$p.xml")
    if [ -n "$FILTER" ]; then args+=(--filter "$FILTER"); fi
    swift test "${args[@]}" || failed+=("$p")

    # SwiftPM merges and exports the profile only when every test passed: do it here, so a
    # failing run still has its coverage.
    profiles=("$codecov"/*.profraw)
    if [ ! -e "${profiles[0]}" ]; then
        echo "No coverage for $p: its tests did not run"
        continue
    fi
    xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "coverage/$p.profdata"
    objects=()
    for bundle in "$(swift build --package-path "Packages/$p" --show-bin-path)"/*.xctest; do
        objects+=(-object "$bundle/Contents/MacOS/$(basename "$bundle" .xctest)")
    done
    xcrun llvm-cov export -format=text -instr-profile="coverage/$p.profdata" "${objects[@]}" |
        jq --arg keep "/Packages/$p/Sources/" \
            '.data[].files |= map(select(.filename | contains($keep)))' > "coverage/$p.json"
    xcrun llvm-cov export -format=lcov -instr-profile="coverage/$p.profdata" "${objects[@]}" \
        > "coverage/$p.lcov"
    reports+=("coverage/$p.json")
    lcov+=("$p=coverage/$p.lcov")
done

if [ ${#reports[@]} -gt 0 ]; then
    jq -s '{type: .[0].type, version: .[0].version, data: [.[].data[] | {files: .files}]}' \
        "${reports[@]}" > coverage/coverage.json
    python3 scripts/lcov-to-cobertura.py . "${lcov[@]}" > coverage/coverage.xml
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
    exit 1
fi
