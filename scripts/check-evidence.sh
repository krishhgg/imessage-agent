#!/bin/bash
# Checks a release-evidence.json before scripts/build.sh puts it in the app (docs/BUILD-PLAN.md, Release-test
# harness).
#
# Usage: scripts/check-evidence.sh [FILE]   (default packaging/release-evidence.json)
#
# The bridge reads the file once at launch (CapabilityRegistry in Sources/IMUI/Capabilities.swift) and treats a
# file over 1 MiB, or one that doesn't decode, as no records. That turns every gated capability off without an
# error, so the build checks the same shape first: a JSON array of objects, each with string macOS (major.minor),
# capability and bridgeVersion, string passedAt in ISO 8601 UTC as write-evidence.swift writes it, and integer
# releaseTest. Other keys may hold strings or integers. Exits 0 when the file is valid, 1 when it isn't.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${1:-$ROOT/packaging/release-evidence.json}"
MAX_BYTES=1048576

die() { echo "error: $FILE: $*" >&2; exit 1; }

[[ -f "$FILE" ]] || die "no such file"
(( $(stat -f %z "$FILE") <= MAX_BYTES )) || die "larger than 1 MiB, which the bridge ignores"
XML="$(plutil -convert xml1 -o - "$FILE" 2>/dev/null)" || die "not valid JSON"

# plutil writes one element per line. Anything but the shapes below means the file isn't a flat array of records.
result="$(awk '
function bad(why) { print why; failed = 1; exit 1 }
{ sub(/^\t+/, "") }
NR <= 3 { next }
NR == 4 {
    if ($0 == "<array/>") { empty = 1; next }
    if ($0 != "<array>") bad("not a JSON array")
    next
}
empty && $0 != "</plist>" { bad("not a JSON array") }
$0 == "<dict>" {
    if (inDict) bad("record " n " holds a nested object")
    inDict = 1; key = ""; split("", type); split("", value)
    next
}
/^<key>.*<\/key>$/ {
    if (!inDict || key != "") bad("not a flat array of records")
    key = $0; sub(/^<key>/, "", key); sub(/<\/key>$/, "", key)
    next
}
/^<string>.*<\/string>$/ || /^<integer>-?[0-9]+<\/integer>$/ {
    if (!inDict || key == "") bad("not a flat array of records")
    v = $0; sub(/^<[a-z]+>/, "", v); sub(/<\/[a-z]+>$/, "", v)
    type[key] = ($0 ~ /^<string>/) ? "string" : "integer"
    value[key] = v; key = ""
    next
}
$0 == "</dict>" {
    if (!inDict || key != "") bad("not a flat array of records")
    if (type["macOS"] != "string" || value["macOS"] !~ /^[0-9]+\.[0-9]+$/) bad("record " n " has no macOS major.minor")
    if (type["capability"] != "string" || value["capability"] == "") bad("record " n " has no capability")
    if (type["bridgeVersion"] != "string" || value["bridgeVersion"] == "") bad("record " n " has no bridgeVersion")
    if (type["releaseTest"] != "integer") bad("record " n " has no integer releaseTest")
    if (type["passedAt"] != "string" || value["passedAt"] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/)
        bad("record " n " passedAt is not an ISO 8601 UTC time like 2026-01-31T12:00:00Z")
    inDict = 0; n++
    next
}
$0 == "</array>" { if (inDict) bad("not a flat array of records"); closed = 1; next }
$0 == "</plist>" { next }
{ bad((inDict ? "record " n " has a value that is not a string or an integer" : "not a flat array of records")) }
END {
    if (failed) exit 1
    if (!empty && !closed) { print "not a JSON array"; exit 1 }
    print n + 0
}
' <<<"$XML")" || die "$result"
echo "release evidence: $result record(s) in $FILE"
