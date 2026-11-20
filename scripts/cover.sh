#!/bin/bash
# Package tests with code coverage, for `make cover` and CI.
#
#   scripts/cover.sh PACKAGE...        FILTER=<Suite> narrows the tests, as in make test
#
# Every package runs even after one fails, so one run shows every failing test. Writes:
#   test-results/<Package>*.xml   xUnit results    (scripts/test-summary.py)
#   test-results/<Package>.log    console output   (names the tests that did not finish)
#   coverage/coverage.json        llvm-cov export  (scripts/coverage-summary.mjs)
#   coverage/coverage.xml         Cobertura        (GitHub code coverage)
# Both coverage reports hold each package's own sources only: a package's profile also
# covers the local packages it depends on and its tests, which would count those twice.
set -eo pipefail
cd "$(dirname "$0")/.."

# A package's tests get at most this long, in seconds. A package that hangs is stopped and
# counted as failed, and what its tests were waiting on is written to test-results/.
TEST_TIME_LIMIT="${TEST_TIME_LIMIT:-600}"

# The tests' processes of package $1: SwiftPM runs each test bundle in a process of its own.
test_processes() {
    pgrep -f "Packages/$1/\.build/.*\.xctest" || true
}

# What the hung tests of package $1 wait on: the suspended async tasks and every thread.
diagnose() {
    local pid
    for pid in $(test_processes "$1"); do
        swift-inspect dump-concurrency "$pid" > "test-results/$1-tasks-$pid.txt" 2>&1 \
            || sudo -n swift-inspect dump-concurrency "$pid" > "test-results/$1-tasks-$pid.txt" 2>&1 \
            || true
        sample "$pid" 2 -file "test-results/$1-threads-$pid.txt" > /dev/null 2>&1 || true
    done
}

# swift test with the arguments given, for package $1, stopped after TEST_TIME_LIMIT.
run_tests() {
    local p="$1" waited=0 pid
    shift
    swift test "$@" > >(tee "test-results/$p.log") 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null; do
        if [ "$waited" -ge "$TEST_TIME_LIMIT" ]; then
            echo "$p: tests did not finish within ${TEST_TIME_LIMIT}s, stopped"
            diagnose "$p"
            for process in $(test_processes "$p"); do kill "$process" 2> /dev/null || true; done
            kill "$pid" 2> /dev/null || true
            wait "$pid" 2> /dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

rm -rf coverage test-results
mkdir -p coverage test-results
failed=()
reports=()
lcov=()
for p in "$@"; do
    echo "==> $p"
    codecov="$(dirname "$(swift test --package-path "Packages/$p" --show-codecov-path)")"
    rm -f "$codecov"/*.profraw

    # Built first, so the time limit counts the tests alone.
    if ! swift build --package-path "Packages/$p" --build-tests --enable-code-coverage; then
        failed+=("$p")
        continue
    fi
    # The packages' tests are Swift Testing only: the XCTest pass would run nothing. On the
    # runner, the calls package hung before that pass printed anything.
    args=(--package-path "Packages/$p" --skip-build --enable-code-coverage --disable-xctest
        --xunit-output "test-results/$p.xml")
    if [ -n "$FILTER" ]; then args+=(--filter "$FILTER"); fi
    run_tests "$p" "${args[@]}" || failed+=("$p")

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
