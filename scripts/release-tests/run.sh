#!/bin/bash
# Runs the release tests on this Mac, then records passing capabilities in packaging/release-evidence.json
# (DESIGN.md "Release tests", docs/BUILD-PLAN.md "Release-test harness"). README.md in this folder has the setup.
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> scripts/release-tests/run.sh [--foreground] [--only t1,t2,...]
#            [--with-t7 FILE] [--no-evidence]
#
#   --foreground    also runs tests 4, 5 and 6b, for a tag that ships foreground actions
#   --only LIST     runs only these tests: t1 t2 t3 t4 t5 t6a t6b t8, comma-separated
#   --with-t7 FILE  merges the outcome file t7-fresh-account.sh wrote on a fresh account
#   --no-evidence   leaves packaging/release-evidence.json alone
#
# Order: t1 t2 t3 t4 t5 t6a t6b t8. Results go to results/<macOS>-<date>/, which stays on this Mac.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

usage() { die "usage: run.sh [--foreground] [--only t1,t2,...] [--with-t7 FILE] [--no-evidence]"; }
FOREGROUND=0
ONLY=""
WITH_T7=""
EVIDENCE=1
while (($#)); do
    case "$1" in
        --foreground) FOREGROUND=1; shift ;;
        --only) [[ $# -ge 2 ]] || usage; ONLY=",$2,"; shift 2 ;;
        --with-t7) [[ $# -ge 2 ]] || usage; WITH_T7="$2"; shift 2 ;;
        --no-evidence) EVIDENCE=0; shift ;;
        *) usage ;;
    esac
done
# Every --only name must be a test, and the foreground tests need --foreground, so a typo can't run nothing.
if [[ -n "$ONLY" ]]; then
    [[ -n "${ONLY//,/}" ]] || die "--only needs at least one test"
    for name in ${ONLY//,/ }; do
        case "$name" in
            t1|t2|t3|t6a|t8) ;;
            t4|t5|t6b) ((FOREGROUND)) || die "--only $name needs --foreground" ;;
            *) die "--only takes t1 t2 t3 t4 t5 t6a t6b t8, not $name" ;;
        esac
    done
fi
require_handle
[[ -x "$IMSG" ]] || die "no imessage CLI at $IMSG fix: install the release-test build (README.md)"
[[ -z "$WITH_T7" || -f "$WITH_T7" ]] || die "no file at $WITH_T7"

MM="$(macos_major_minor)"
IMSG_RT_RESULTS="$RT_DIR/results/$MM-$(date +%Y%m%d-%H%M%S)"
export IMSG_RT_RESULTS
RESULTS="$IMSG_RT_RESULTS"
TOOLS="$RESULTS/bin"
LOG="$RESULTS/run.log"
OUTCOMES="$RESULTS/outcomes.txt"
if ! { mkdir -p "$RESULTS/samples" "$RESULTS/files" "$TOOLS" && chmod 700 "$RESULTS" && touch "$OUTCOMES"; }; then
    die "can't write the results folder $RESULTS"
fi

{
    sw_vers
    echo "arch: $(uname -m)"
    echo "bridge version: $(bridge_version)"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "foreground: $FOREGROUND"
} >"$RESULTS/env.txt"
msg "== release tests on macOS $MM, results in $RESULTS"

check_release_build
export IMSG_RT_CHECKED=1
need_tool sampler
((FOREGROUND)) && need_tool hid-inject
((EVIDENCE)) && need_tool write-evidence

# Preflight: grants and your own chat allowed with files, so most sends don't ask.
tell "imessage doctor --ui checks the grants. Allow any prompt it raises for iMessage Agent."
require_grants
tell "Next, imessage allow asks to allow your own chat with files. Click Allow once."
im allow "$IMSG_TEST_HANDLE" --files
[[ "$IM_RC" == 0 ]] || die "imessage allow failed (exit $IM_RC), see $LOG"

selected() { [[ -z "$ONLY" || "$ONLY" == *",$1,"* ]]; }
run_test() {
    local name="$1" script="$2"
    shift 2
    selected "$name" || return 0
    msg ""
    /bin/bash "$RT_DIR/$script" "$@"
    local rc=$?
    if ((rc != 0)); then
        msg "$name exited $rc"
        echo "case rerun $name 0 exited $rc" >>"$OUTCOMES"
    fi
}

run_test t1 t1-bridge.sh
run_test t2 t2-tapbacks.sh
run_test t3 t3-targeting.sh
if ((FOREGROUND)); then
    run_test t4 t4-foreground.sh
    run_test t5 t5-abort.sh
fi
run_test t6a t6-fullscreen.sh a
((FOREGROUND)) && run_test t6b t6-fullscreen.sh b
run_test t8 t8-files-groups.sh

# Test 7 ran on another account. Its file has an env line and a gate line.
if [[ -n "$WITH_T7" ]]; then
    t7_mm="$(awk '$1 == "env" && $2 == "macos" { print $3; exit }' "$WITH_T7")"
    if [[ "$t7_mm" != "$MM" ]]; then
        echo "gate fail fresh-account 7 ran on macOS ${t7_mm:-unknown}, not $MM" >>"$OUTCOMES"
    else
        grep -E '^gate [a-z]+ fresh-account 7( |$)' "$WITH_T7" >>"$OUTCOMES"
    fi
fi

# Summary. The last line for each capability or gate wins.
latest() { awk -v k="$1" '$1 == k { last[$3] = $0 } END { for (n in last) print last[n] }' "$OUTCOMES" | sort -k3; }
msg ""
msg "== capabilities"
latest cap | while read -r _ status name test detail; do msg "   $status  $name (test $test) $detail"; done
msg "== gates"
latest gate | while read -r _ status name test detail; do msg "   $status  $name (test $test) $detail"; done

# Tag check: gates that must pass, and any failed gate.
BLOCKED=""
for g in cold-text-send cold-file-send cold-ui-action warm-text-send no-window-relaunch other-space-busy fullscreen-space-busy fullscreen-panel fresh-account; do
    status="$(awk -v g="$g" '$1 == "gate" && $3 == g { s = $2 } END { print s }' "$OUTCOMES")"
    [[ "$status" == pass ]] || BLOCKED="$BLOCKED $g(${status:-not run})"
done
while read -r g; do
    [[ -n "$g" && "$BLOCKED" != *" $g("* ]] && BLOCKED="$BLOCKED $g(fail)"
done < <(awk '$1 == "gate" { s[$3] = $2 } END { for (n in s) if (s[n] == "fail") print n }' "$OUTCOMES")
if [[ -n "$BLOCKED" ]]; then
    msg "== tag: blocked by$BLOCKED"
else
    msg "== tag: not blocked by any gate"
fi

if ((EVIDENCE)); then
    "$TOOLS/write-evidence" --outcomes "$OUTCOMES" --macos "$MM" --bridge-version "$(bridge_version)" \
        --evidence "$ROOT/packaging/release-evidence.json" 2>&1 | tee -a "$LOG"
    if ((PIPESTATUS[0] == 0)); then
        msg "evidence: $ROOT/packaging/release-evidence.json. scripts/build.sh copies it into the app at the next build."
    else
        msg "write-evidence failed, so packaging/release-evidence.json is unchanged"
    fi
fi
if ((FOREGROUND)); then
    im revoke --foreground
    msg "foreground mode revoked (exit $IM_RC)"
fi
msg "Your own chat stays allowed with files. To undo: $IMSG revoke $IMSG_TEST_HANDLE"
msg "Reinstall the release build when you're done (README.md)."
