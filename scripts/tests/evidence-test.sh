#!/bin/bash
# Tests for scripts/release-tests/write-evidence.swift and scripts/check-evidence.sh, on outcome files written here.
#
# Usage: scripts/tests/evidence-test.sh
#
# write-evidence is compiled with swiftc into a temporary folder. Nothing outside that folder is written.
# The $1 in the bash -c string is meant literally.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/imessage-evidence-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "ok    $*"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL  $*"; }
check() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

if ! swiftc -swift-version 5 -O -o "$T/write-evidence" "$ROOT/scripts/release-tests/write-evidence.swift" 2>"$T/compile.log"; then
    sed 's/^/      /' "$T/compile.log"
    fail "write-evidence.swift compiles"
    echo "evidence tests: $PASSED passed, $FAILED failed"
    exit 1
fi
pass "write-evidence.swift compiles"

EV="$T/evidence.json"
RC=0
# we <outcome lines> -- [args]: writes the outcome lines to a file and runs write-evidence on $EV for macOS 26.2.
we() {
    local lines=()
    while [[ $# -gt 0 && "$1" != -- ]]; do lines+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && shift
    printf '%s\n' ${lines[@]+"${lines[@]}"} >"$T/outcomes.txt"
    "$T/write-evidence" --outcomes "$T/outcomes.txt" --macos 26.2 --bridge-version 0.1.0 --evidence "$EV" "$@" \
        >"$T/out.txt" 2>&1
    RC=$?
}
# count <capability> [macOS]: records for that capability on that macOS (default 26.2).
count() {
    local i=0 n=0
    while [[ -n "$(plutil -type "$i" "$EV" 2>/dev/null)" ]]; do
        if [[ "$(plutil -extract "$i.capability" raw -o - "$EV")" == "$1" \
            && "$(plutil -extract "$i.macOS" raw -o - "$EV")" == "${2:-26.2}" ]]; then n=$((n + 1)); fi
        i=$((i + 1))
    done
    echo "$n"
}
is() { [[ "$1" == "$2" ]]; }
valid() { "$ROOT/scripts/check-evidence.sh" "$1" >/dev/null 2>&1; }
invalid() { ! valid "$1"; }

# Usage errors write nothing.
for bad in "26" "26.2.1" "26." ".2" "x.2" "٢٦.٢" "26.½" "２６.2"; do
    "$T/write-evidence" --outcomes /dev/null --macos "$bad" --bridge-version 0.1.0 --evidence "$EV" >/dev/null 2>&1
    check "--macos $bad is a usage error" is "$?" 2
done
for bad in "unknown" "0.1" "0.1.0.1" "0.1.x" "٠.1.0"; do
    "$T/write-evidence" --outcomes /dev/null --macos 26.2 --bridge-version "$bad" --evidence "$EV" >/dev/null 2>&1
    check "--bridge-version $bad is a usage error" is "$?" 2
done
"$T/write-evidence" --macos 26.2 --bridge-version 0.1.0 --evidence "$EV" >/dev/null 2>&1
check "a missing --outcomes is a usage error" is "$?" 2
check "usage errors write no file" test ! -e "$EV"

# Passes for every needed test write one record per test.
we "cap pass unsend 1 ok" "cap pass tapback.heart 1 ok" "cap pass tapback.heart 2 ok" "case pass t3-x 3 ignored" \
    "gate pass cold-text-send 1 ignored" "env macos 26.2 bridge 0.1.0"
check "a passing run exits 0" is "$RC" 0
check "unsend gets one record" is "$(count unsend)" 1
check "tapback.heart gets records for tests 1 and 2" is "$(count tapback.heart)" 2
check "the output passes check-evidence.sh" valid "$EV"
check "passedAt is ISO 8601 UTC" bash -c '[[ "$(plutil -extract 0.passedAt raw -o - "$1")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]' _ "$EV"
check "bridgeVersion is recorded" is "$(plutil -extract 0.bridgeVersion raw -o - "$EV")" 0.1.0

# A capability that needs two tests stays unchanged when only one passed.
we "cap pass edit 4 ok" "cap skip edit 6 not run"
check "a partial pass exits 0" is "$RC" 0
check "edit with only test 4 gets no record" is "$(count edit)" 0
check "the partial pass is reported" grep -q "edit: test 6 didn't pass in this run, records unchanged" "$T/out.txt"
we "cap pass edit 4 ok" "cap pass edit 6 ok"
check "edit with tests 4 and 6 gets two records" is "$(count edit)" 2
we "cap rerun edit 4 again" "cap skip edit 6 not run"
check "rerun and skip leave records alone" is "$(count edit)" 2

# A failure removes the capability's records for this macOS only.
echo "cap pass unsend 1 ok" >"$T/other-macos.txt"
"$T/write-evidence" --outcomes "$T/other-macos.txt" --macos 15.7 --bridge-version 0.1.0 --evidence "$EV" >/dev/null 2>&1
check "a record for another macOS is added" is "$(count unsend 15.7)" 1
we "cap pass unsend 1 ok" "cap fail unsend 1 Messages showed"
check "a run with a pass and a fail exits 0" is "$RC" 0
check "a fail removes the records for this macOS" is "$(count unsend)" 0
check "a fail keeps other macOS records" is "$(count unsend 15.7)" 1
we "cap fail edit 6 front app changed"
check "a fail in one needed test removes every record" is "$(count edit)" 0
check "the other capabilities stay" is "$(count tapback.heart)" 2

# Bad input changes nothing.
cp "$EV" "$T/before.json"
we "cap pass tapback.sparkle 2 ok"
check "an unknown capability exits 1" is "$RC" 1
check "an unknown capability leaves the file alone" cmp -s "$EV" "$T/before.json"
we "cap maybe unsend 1 ok"
check "a bad status exits 1" is "$RC" 1
we "cap pass unsend one ok"
check "a bad test number exits 1" is "$RC" 1
check "bad outcome lines leave the file alone" cmp -s "$EV" "$T/before.json"
we "cap pass unsend 1 ok" -- --dry-run
check "a dry run exits 0" is "$RC" 0
check "a dry run leaves the file alone" cmp -s "$EV" "$T/before.json"
printf '{"not": "an array"}\n' >"$EV"
we "cap pass unsend 1 ok"
check "a malformed evidence file exits 1" is "$RC" 1
check "a malformed evidence file is left as it was" grep -q '"not"' "$EV"

# check-evidence.sh on files the bridge would ignore.
GOOD='{"macOS":"26.2","capability":"unsend","releaseTest":1,"passedAt":"2026-01-31T12:00:00Z","bridgeVersion":"0.1.0"}'
printf '[]\n' >"$T/empty.json"
check "check-evidence accepts an empty array" valid "$T/empty.json"
printf '[%s]\n' "$GOOD" >"$T/good.json"
check "check-evidence accepts a good record" valid "$T/good.json"
printf '%s\n' "$GOOD" >"$T/object.json"
check "check-evidence refuses an object" invalid "$T/object.json"
printf '[%s\n' "$GOOD" >"$T/truncated.json"
check "check-evidence refuses broken JSON" invalid "$T/truncated.json"
printf '[%s]\n' "${GOOD/\"releaseTest\":1/\"releaseTest\":\"1\"}" >"$T/string-test.json"
check "check-evidence refuses a string releaseTest" invalid "$T/string-test.json"
printf '[%s]\n' "${GOOD/2026-01-31T12:00:00Z/2026-01-31T12:00:00.5Z}" >"$T/fraction.json"
check "check-evidence refuses fractional seconds, which the decoder rejects" invalid "$T/fraction.json"
printf '[%s]\n' "${GOOD/\"capability\":\"unsend\",/}" >"$T/missing.json"
check "check-evidence refuses a missing field" invalid "$T/missing.json"
printf '[%s,1]\n' "$GOOD" >"$T/mixed.json"
check "check-evidence refuses a non-object element" invalid "$T/mixed.json"
printf '[%s]\n' "${GOOD/26.2/26}" >"$T/major.json"
check "check-evidence refuses a macOS without a minor" invalid "$T/major.json"
{ printf '['; for ((i = 0; i < 12000; i++)); do printf '%s,' "$GOOD"; done; printf '%s]\n' "$GOOD"; } >"$T/big.json"
check "check-evidence refuses a file over 1 MiB" invalid "$T/big.json"
check "check-evidence refuses a missing file" invalid "$T/none.json"

echo "evidence tests: $PASSED passed, $FAILED failed"
((FAILED == 0))
