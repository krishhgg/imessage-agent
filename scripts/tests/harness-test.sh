#!/bin/bash
# Tests for the release-test harness logic that runs without Messages: run.sh argument checks, and the lib.sh
# helpers that parse CLI JSON, bridge markers and sampler output. A fake imessage CLI answers from the golden NDJSON
# in scripts/tests/fixtures, which NDJSONGoldenTests renders, and from a few hand-written variants.
#
# Usage: scripts/tests/harness-test.sh
#
# Nothing here sends a message, starts the sampler or posts input. HOME points at a temporary folder.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RT="$ROOT/scripts/release-tests"
FX="$ROOT/scripts/tests/fixtures"
T="$(mktemp -d "${TMPDIR:-/tmp}/imessage-harness-test.XXXXXX")"
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
is() { [[ "$1" == "$2" ]]; }
not() { ! "$@"; }

# run.sh refuses --only lists that would run nothing, before it touches the CLI.
run_sh() {
    env HOME="$T/home" IMSG_TEST_HANDLE=me@example.com IMSG_CLI="$T/no-cli" /bin/bash "$RT/run.sh" "$@" \
        >"$T/out.txt" 2>&1 </dev/null
    RC=$?
}
mkdir -p "$T/home"
results_before="$(ls "$RT/results" 2>/dev/null)"
run_sh --only t4
check "--only t4 without --foreground is refused" is "$RC" 2
check "the refusal says --foreground" grep -q "needs --foreground" "$T/out.txt"
run_sh --only t1,t9
check "an unknown --only name is refused" is "$RC" 2
check "the refusal lists the tests" grep -q "takes t1 t2 t3 t4 t5 t6a t6b t8, not t9" "$T/out.txt"
run_sh --only ,
check "an empty --only list is refused" is "$RC" 2
run_sh --bogus
check "an unknown run.sh argument is refused" is "$RC" 2
run_sh --foreground --only t4,t5,t6b
check "a valid --only list gets past the check" grep -q "no imessage CLI" "$T/out.txt"
check "run.sh wrote no results folder" is "$(ls "$RT/results" 2>/dev/null)" "$results_before"

# The fake CLI prints the file named by FAKE_<VERB> and exits with FAKE_RC_<VERB>, else FAKE_RC, else 0. FAKE_<VERB>
# may list several files split by ':'. Each call then prints the next one, and the last repeats, counted in
# FAKE_STATE. reset_fake clears the counts.
cat >"$T/imessage" <<'EOF'
#!/bin/bash
verb="$(echo "$1" | tr '[:lower:]-' '[:upper:]_')"
var="FAKE_$verb"
rcvar="FAKE_RC_$verb"
IFS=: read -r -a files <<<"${!var:-}"
n=0
if ((${#files[@]} > 1)); then
    n="$(cat "$FAKE_STATE/$verb.count" 2>/dev/null || echo 0)"
    echo $((n + 1)) >"$FAKE_STATE/$verb.count"
    ((n < ${#files[@]})) || n=$((${#files[@]} - 1))
fi
f="${files[$n]:-}"
[[ -n "$f" && -f "$f" ]] && cat "$f"
exit "${!rcvar:-${FAKE_RC:-0}}"
EOF
chmod 755 "$T/imessage"
FAKE_STATE="$T/fake-state"
mkdir -p "$FAKE_STATE"
export FAKE_STATE
reset_fake() { rm -f "$FAKE_STATE"/*.count; }

# The helpers, sourced the way the tests source them, with prompts and spacing turned off.
export HOME="$T/home" IMSG_CLI="$T/imessage" IMSG_TEST_HANDLE=me@example.com
# shellcheck source-path=SCRIPTDIR/../release-tests source=lib.sh
source "$RT/lib.sh"
# LOG and SEND_SPACING are read by lib.sh.
# shellcheck disable=SC2034
RESULTS="$T/results"
# shellcheck disable=SC2034
LOG="$RESULTS/log.txt"
OUTCOMES="$RESULTS/outcomes.txt"
mkdir -p "$RESULTS"
tell() { :; }
# shellcheck disable=SC2034
SEND_SPACING=0

j() { printf '%s\n' "$2" >"$T/$1.json"; echo "$T/$1.json"; }

FAKE_SEND="$(j send-text '{"parts":[{"part":"text","rowid":101,"result":{"code":"delivered","notes":[]}}]}')"
export FAKE_SEND
send me@example.com "hi"
check "send reads the text row" is "$SEND_ROWID" 101
check "send reads the result code" is "$SEND_CODE" delivered
check "a delivered send is ok" send_ok

FAKE_SEND="$(j send-file '{"parts":[{"part":"text","rowid":201,"result":{"code":"submitted","notes":[]}},{"part":"file","rowid":202,"result":{"code":"submitted","notes":["chat unconfirmed"]}}]}')"
send me@example.com "hi" --file x.heic
check "send reads the text row of a two-part send" is "$SEND_ROWID" 201
check "send reads the file row" is "$SEND_FILE_ROWID" 202
check "send reports the file part's result" is "$SEND_LINE" "submitted, chat unconfirmed"

FAKE_SEND="$(j send-visible '{"parts":[{"part":"text","rowid":301,"result":{"code":"delivered","notes":["error: Messages became visible"]}}]}')"
send me@example.com "hi"
check "a send where Messages became visible isn't ok" not send_ok

FAKE_SEND="$(j send-early '{"early":{"code":"denied","notes":["user denied"]}}')"
send me@example.com "hi"
check "an early result is read" is "$SEND_LINE" "denied, user denied"
check "an early result has no row" is "$SEND_ROWID" ""
check "a denied send isn't ok" not send_ok

FAKE_REACT="$FX/react.ndjson"
export FAKE_REACT
ui react 101 heart
check "ui reads the result" is "$UI_CODE" ok
check "an ok UI result is ok" ui_ok

# Lookups read the golden NDJSON in scripts/tests/fixtures, the exact bytes the CLI prints for those records
# (NDJSONGoldenTests renders them). A lookup that fails, or whose output lacks the line that proves the CLI
# answered, returns nonzero, so it can't pass a safety check.
FAKE_SEND="$FX/send-file.ndjson"
send me@example.com "hi" --file x.heic
check "send reads the golden text row" is "$SEND_ROWID" 201
check "send reads the golden file row" is "$SEND_FILE_ROWID" 202
check "send reads the golden file part's result" is "$SEND_LINE" "submitted, chat unconfirmed"
FAKE_SEND="$FX/send-denied.ndjson"
send me@example.com "hi"
check "send reads the golden early result" is "$SEND_CODE:$SEND_ROWID" "denied:"

FAKE_SHOW="$FX/show-heart.ndjson"
export FAKE_SHOW
check "show_json reads the message line" show_json 101
check "show_json keeps the message line" is "$(msg_get text)" hi
check "msg_get reads the send time" is "$(msg_get ns)" 815640000000000000
check "msg_get reads the delivery time" is "$(msg_get delivered)" 815640002000000000
check "msg_flag says false for a flag that isn't printed" is "$(msg_flag unsent)" false
check "my_reactions lists only my own" is "$(my_reactions 101)" heart
check "has_my_reaction finds the Heart" has_my_reaction 101 heart
has_my_reaction 101 like
check "has_my_reaction says absent for another person's like" is "$?:$REACTION_STATE" 1:absent
check "lacks_my_reaction is true for another person's like" lacks_my_reaction 101 like
check "lacks_my_reaction is false for my Heart" not lacks_my_reaction 101 heart
FAKE_SHOW="$FX/show-file.ndjson"
check "lacks_my_reaction is true when the message has no reactions" lacks_my_reaction 202 heart
show_json 202
check "msg_get reads the attachment's transfer state" is "$(msg_get att.0.state)" 5
check "msg_get reads the attachment's uti" is "$(msg_get att.0.uti)" public.heic
check "msg_get reads the attachment's name" is "$(msg_get att.0.name)" IMG_0001.HEIC
check "msg_get reads the attachment's id" is "$(msg_get att.0.id)" 9901
FAKE_SHOW="$FX/show-file-pending.ndjson"
show_json 203
check "msg_get reads a transfer that isn't done" is "$(msg_get att.0.state)" 1
check "a message that isn't delivered has no delivery time" not msg_get delivered

FAKE_RC_SHOW=1 FAKE_SHOW="$FX/show-heart.ndjson" show_json 101
check "show_json fails when the CLI exits nonzero, even with a message line" is "$?:$SHOW_JSON" 1:
check "msg_flag says unknown with no message" is "$(msg_flag edited)" unknown
FAKE_RC_SHOW=1 FAKE_SHOW="$FX/show-not-found.ndjson" show_json 101
check "show_json fails on an error line" is "$?:$SHOW_JSON" 1:
FAKE_SHOW="$FX/show-heart.ndjson"
check "show_json fails when the message line has another id" not show_json 555
check "show_json leaves SHOW_JSON empty on a mismatch" is "$SHOW_JSON" ""
head -n 1 "$FX/show-heart.ndjson" >"$T/show-chat-only.json"
FAKE_SHOW="$T/show-chat-only.json"
check "show_json fails when no message line came back" not show_json 101
FAKE_SHOW="$T/none.json"
check "show_json fails on empty output" not show_json 101
for case in "exit 1:$FX/show-file.ndjson:202:1" "an error line:$FX/show-not-found.ndjson:101:1" \
    "no output:$T/none.json:101:0" "another id:$FX/show-heart.ndjson:555:0"; do
    IFS=: read -r label file id rc <<<"$case"
    FAKE_SHOW="$file"
    FAKE_RC_SHOW="$rc" has_my_reaction "$id" heart
    check "has_my_reaction returns 2 when show fails ($label)" is "$?:$REACTION_STATE" 2:unknown
    FAKE_RC_SHOW="$rc"
    export FAKE_RC_SHOW
    check "lacks_my_reaction is false when show fails ($label), so a Heart remove can't pass" \
        not lacks_my_reaction "$id" heart
    unset FAKE_RC_SHOW
done

grep -v '"type":"chat"' "$FX/read.ndjson" >"$T/read-no-chat.json"
{ cat "$FX/read.ndjson"; echo '{"next":"imessage read 7 --before 1","type":"more"}'; } >"$T/read-more.json"
FAKE_READ="$FX/read.ndjson"
export FAKE_READ
check "read_messages prints the message lines and skips the chat line" is "$(read_messages me 5 | wc -l | tr -d ' ')" 5
check "read_messages keeps the order" is "$(read_messages me 5 | tail -n 1 | plutil -extract id raw -o - -)" 5
check "chat_total reads the chat line's total" is "$(chat_total me)" 5
READ_LINES="$(read_messages me 5)"
line_of() { printf '%s\n' "$READ_LINES" | sed -n "$1p"; }
check "editable_message takes a plain text of mine" editable_message "$(line_of 1)"
check "editable_message refuses someone else's message" not editable_message "$(line_of 2)"
check "editable_message refuses a multipart message with a photo" not editable_message "$(line_of 3)"
check "editable_message refuses an unsent message" not editable_message "$(line_of 4)"
check "multipart_id finds the message with two parts" is "$(multipart_id "$READ_LINES")" 3
check "multipart_id finds nothing among single parts" not multipart_id "$(line_of 1)"
FAKE_READ="$T/read-more.json"
check "read_messages skips a more record" is "$(read_messages me 5 | wc -l | tr -d ' ')" 5
FAKE_READ="$FX/read-reply.ndjson"
check "msg_get-style reads see the reply's parent" is "$(read_messages me 2 | tail -n 1 | plutil -extract reply raw -o - -)" 61
FAKE_READ="$FX/read-empty.ndjson"
check "read_messages accepts a chat with no messages" read_messages me 2
check "read_messages prints nothing for an empty chat" is "$(read_messages me 2)" ""
FAKE_RC_READ=1 FAKE_READ="$FX/read.ndjson" read_messages me 2 >/dev/null
check "read_messages fails when the CLI exits nonzero" is "$?" 1
FAKE_RC_READ=1 FAKE_READ="$FX/read.ndjson" chat_total me >/dev/null
check "chat_total fails when the CLI exits nonzero" is "$?" 1
FAKE_READ="$T/read-no-chat.json"
check "read_messages fails when no chat line came back" not read_messages me 2
FAKE_READ="$T/none.json"
check "read_messages fails on empty output" not read_messages me 2

FAKE_WAIT="$FX/wait.ndjson"
export FAKE_WAIT
im wait --from ann --timeout 1 --json
check "wait_message_id reads the message line, not the chat line" is "$(wait_message_id)" 61
FAKE_WAIT="$FX/wait-timeout.ndjson"
im wait --from ann --timeout 1 --json
check "wait_message_id prints nothing on a timeout" is "$(wait_message_id)" ""
check "wait_message_id fails on a timeout" not wait_message_id
FAKE_RC_WAIT=1 FAKE_WAIT="$FX/wait.ndjson" im wait --json
check "wait_message_id fails when the CLI exits nonzero" not wait_message_id

grep -v '"id":41,' "$FX/unread.ndjson" >"$T/unread-one.json"
grep -v '"type":"unread"' "$FX/unread.ndjson" >"$T/unread-no-header.json"
FAKE_UNREAD="$FX/unread.ndjson"
export FAKE_UNREAD
check "unread_ids lists the unread ids sorted, without context lines" is "$(unread_ids | tr '\n' ' ')" "41 42 "
FAKE_UNREAD="$FX/unread-none.ndjson"
check "unread_ids accepts no unread messages" unread_ids
check "unread_ids prints nothing when nothing is unread" is "$(unread_ids)" ""
FAKE_RC_UNREAD=1 FAKE_UNREAD="$FX/unread.ndjson" unread_ids >/dev/null
check "unread_ids fails when the CLI exits nonzero" is "$?" 1
FAKE_UNREAD="$T/none.json"
check "unread_ids fails on empty output" not unread_ids
FAKE_UNREAD="$T/unread-no-header.json"
check "unread_ids fails without the unread header" not unread_ids

# no_press_check, which t3 runs for ambiguous, unsupported_target and not_loaded: it passes only when every lookup
# worked. React prints its result and the unread lookup runs before and after it.
no_press() {
    reset_fake
    (
        export FAKE_REACT="$FX/react-ambiguous.ndjson" FAKE_UNREAD="${NP_UNREAD:-$FX/unread.ndjson}"
        export FAKE_SHOW="${NP_SHOW:-$FX/show-file.ndjson}"
        export FAKE_RC_UNREAD="${NP_RC_UNREAD:-0}" FAKE_RC_SHOW="${NP_RC_SHOW:-0}"
        no_press_check "${NP_ID:-202}" "${NP_WANT:-ambiguous}"
        echo "$CHECK_STATUS: $CHECK_DETAIL"
    )
}
check "no_press_check passes when nothing was pressed" is "$(no_press)" "pass: ambiguous"
check "no_press_check fails on another code" is "$(NP_WANT=not_loaded no_press)" "fail: wanted not_loaded, got ambiguous"
check "no_press_check fails when a Heart landed" \
    is "$(NP_ID=101 NP_SHOW="$FX/show-heart.ndjson" no_press)" "fail: ambiguous, but a Heart is on 101"
check "no_press_check fails when the unread messages changed" \
    is "$(NP_UNREAD="$FX/unread.ndjson:$T/unread-one.json" no_press)" "fail: ambiguous, but the unread messages changed"
check "no_press_check reruns, not passes, when show fails" \
    is "$(NP_RC_SHOW=1 no_press)" \
    "rerun: ambiguous, but imessage show 202 failed, so a Heart couldn't be ruled out"
check "no_press_check reruns, not passes, when show returns another message" \
    is "$(NP_ID=555 no_press | cut -d: -f1)" rerun
check "no_press_check reruns, not passes, when unread fails" \
    is "$(NP_RC_UNREAD=1 no_press)" "rerun: imessage unread failed before the press, so a read-state change couldn't be seen"
check "no_press_check reruns, not passes, when unread prints nothing" is "$(NP_UNREAD="$T/none.json" no_press | cut -d: -f1)" rerun
check "no_press_check reruns when only the unread lookup after the press fails" \
    is "$(NP_UNREAD="$FX/unread.ndjson:$T/none.json" no_press)" "rerun: ambiguous, but imessage unread failed after the press"

# parent_changed_check, t4's check that a changed parent leaves no reply row.
parent_changed() {
    (
        export FAKE_READ="${PC_READ:-$FX/read.ndjson}" FAKE_RC_READ="${PC_RC_READ:-0}"
        parent_changed_check peer "${PC_LINE:-aborted: parent changed}"
        echo "$CHECK_STATUS: $CHECK_DETAIL"
    )
}
check "parent_changed_check passes when the newest row is the other person's" \
    is "$(parent_changed)" "pass: aborted: parent changed, no reply row"
check "parent_changed_check fails on another result" is "$(PC_LINE=submitted parent_changed)" "fail: submitted"
check "parent_changed_check fails when a reply row is newest" \
    is "$(PC_READ="$FX/read-reply.ndjson" parent_changed)" "fail: aborted: parent changed, but the newest row 62 is from you"
check "parent_changed_check reruns, not passes, when read fails" \
    is "$(PC_RC_READ=1 parent_changed)" "rerun: aborted: parent changed, but imessage read failed, so a reply row couldn't be ruled out"
check "parent_changed_check reruns, not passes, when read prints no chat line" \
    is "$(PC_READ="$T/none.json" parent_changed | cut -d: -f1)" rerun
check "parent_changed_check reruns, not passes, when read prints no messages" \
    is "$(PC_READ="$FX/read-empty.ndjson" parent_changed)" "rerun: aborted: parent changed, but imessage read printed no messages"

# A failed lookup must not pass a "the reaction is gone" check, so no test negates has_my_reaction.
check "no release test writes ! has_my_reaction" not grep -n -E '!\s*has_my_reaction' "$RT"/t*.sh
check "run.sh runs require_grants before the tests" grep -q -x 'require_grants' "$RT/run.sh"
check "no release test reads a JSON key the CLI never prints" \
    not grep -n -E 'fromMe|partCount|attachments\.|dateNs|dateDeliveredNs|replyTo|message\.rowid|transferState|transferName' \
    "$RT"/*.sh

# require_grants, run.sh's preflight. Doctor exits 0 with failing checks, so the report decides.
grants() {
    (
        export FAKE_DOCTOR="$1" FAKE_RC_DOCTOR="${2:-0}"
        require_grants
    ) >/dev/null 2>"$T/grants.err"
    GRANTS_RC=$?
}
printf '%s\n' 'doctor · 5 checks, 0 failing' 'ok chat.db: 120 messages' 'ok Automation: granted' 'ok Accessibility: granted' \
    'ok Automation prompt: granted' 'ok Accessibility prompt: granted' >"$T/doctor-ok.txt"
printf '%s\n' 'doctor · 5 checks, 1 failing' 'ok chat.db: 120 messages' 'ok Automation: granted' \
    'fail Accessibility: denied fix: turn on iMessage Agent in Privacy & Security > Accessibility' \
    'ok Automation prompt: granted' 'ok Accessibility prompt: asked, answer the prompt on the Mac' >"$T/doctor-ax.txt"
printf '%s\n' 'doctor · 4 checks, 1 failing' 'ok chat.db: 120 messages' 'ok Automation: granted' \
    'fail Automation prompt: denied fix: turn on iMessage Agent in System Settings > Privacy & Security > Automation' >"$T/doctor-prompt.txt"
printf '%s\n' 'doctor · 4 checks, 2 failing' 'ok chat.db: 120 messages' 'ok Automation: granted' 'ok Accessibility: granted' \
    'fail action names: missing: Heart fix: imessage doctor' 'fail last run: crashed fix: imessage doctor' 'ok allowlist: 1 chats' >"$T/doctor-other.txt"
grants "$T/doctor-ok.txt"
check "require_grants passes a report with every grant" is "$GRANTS_RC" 0
grants "$T/doctor-ax.txt"
check "require_grants stops on a failing Accessibility check" is "$GRANTS_RC" 2
check "require_grants names the failing check" grep -q -F "fail Accessibility: denied" "$T/grants.err"
check "require_grants says to grant and run again" grep -q -F "grant them, then run again" "$T/grants.err"
grants "$T/doctor-prompt.txt"
check "require_grants stops on a denied Automation prompt" is "$GRANTS_RC" 2
grants "$T/doctor-other.txt"
check "require_grants ignores action names, last run and allowlist" is "$GRANTS_RC" 0
grants "$T/doctor-ok.txt" 3
check "require_grants stops when doctor exits nonzero" is "$GRANTS_RC" 2
grants "$T/none.json"
check "require_grants stops when doctor prints no report" is "$GRANTS_RC" 2

# Markers in bridge.log.
mkdir -p "$(dirname "$BRIDGE_LOG")"
# The lines are in the form ReleaseTestMarkers.line writes and MarkerTests asserts: release-test <ms> <event>.
cat >"$BRIDGE_LOG" <<'EOF'
release-test 1000 phase front
release-test 1500 field-set
release-test 2000 key return
release-test 2100 hide
release-test 2200 focus-restore com.apple.finder
EOF
check "first_marker finds a phase" is "$(first_marker 0 phase front)" 1000
check "first_marker matches the whole event words" is "$(first_marker 0 key return)" 2000
check "first_marker respects the start time" is "$(first_marker 2050 hide)" 2100
check "first_marker finds nothing before the start" is "$(first_marker 2150 hide)" ""
check "markers_since keeps the detail" is "$(markers_since 2200)" "2200 focus-restore com.apple.finder"
check "have_markers sees the phase lines" have_markers

# Sampler lines: a hide and a front change after the input count, earlier ones and an app already hidden don't.
cat >"$T/sample.jsonl" <<'EOF'
{"front":"com.apple.finder","messages_hidden":false,"type":"start","wall_ms":900}
{"bundle":"com.apple.MobileSMS","pid":5,"type":"front","wall_ms":1000}
{"hidden":true,"pids":[5],"type":"messages_app","wall_ms":2150}
{"bundle":"com.apple.finder","pid":6,"type":"front","wall_ms":2300}
{"type":"summary","verdict":"pass","wall_ms":2500}
EOF
check "sampled_effects reports a hide and a front change after the input" \
    is "$(sampled_effects "$T/sample.jsonl" 2000 1)" "Messages hid at 2150"$'\n'"front app changed to com.apple.finder at 2300"
check "sampled_effects can leave out front changes" is "$(sampled_effects "$T/sample.jsonl" 2000 0)" "Messages hid at 2150"
check "sampled_effects ignores what came before the input" is "$(sampled_effects "$T/sample.jsonl" 2400 1)" ""
cat >"$T/sample-hidden.jsonl" <<'EOF'
{"front":"com.apple.finder","messages_hidden":true,"type":"start","wall_ms":900}
{"hidden":true,"pids":[7],"type":"messages_app","wall_ms":2150}
EOF
check "sampled_effects doesn't count a relaunch that stays hidden" is "$(sampled_effects "$T/sample-hidden.jsonl" 2000 1)" ""
check "sampled_effects reports a missing sample" is "$(sampled_effects "$T/none.jsonl" 0 1)" "no sample file"

# Test 4's Return timing (return_timing in lib.sh) starts at the sampler's first sample with Messages frontmost, not
# at the bridge's `phase front` marker. Here the marker is 1000 ms late, so it would pass a Return 3500 ms after
# Messages came forward.
timing() {
    printf '%s\n' "$2" >"$BRIDGE_LOG"
    return_timing "$1" "${3:-0}"
    echo "$TIMING_OK: $TIMING_DETAIL"
}
cat >"$T/front.jsonl" <<'EOF'
{"front":"com.apple.finder","messages_hidden":true,"type":"start","wall_ms":500}
{"bundle":"com.apple.MobileSMS","pid":5,"type":"front","wall_ms":600}
{"bundle":"com.apple.finder","pid":6,"type":"front","wall_ms":700}
{"bundle":"io.github.krishhgg.imessage-agent","pid":8,"type":"front","wall_ms":800}
{"bundle":"com.apple.MobileSMS","pid":5,"type":"front","wall_ms":1000}
{"hidden":true,"pids":[5],"type":"messages_app","wall_ms":4700}
{"bundle":"com.apple.finder","pid":6,"type":"front","wall_ms":4800}
EOF
late_marker=$'release-test 2000 phase front\nrelease-test 4500 key return'
check "sampled_front_ms finds the first Messages front sample after the start" is "$(sampled_front_ms "$T/front.jsonl" 900)" 1000
check "sampled_front_ms skips other apps and earlier samples" is "$(sampled_front_ms "$T/front.jsonl" 650)" 1000
check "sampled_front_ms finds nothing after the last Messages front sample" not sampled_front_ms "$T/front.jsonl" 1001
check "sampled_front_ms fails on a missing sample" not sampled_front_ms "$T/none.jsonl" 0
check "return_timing fails a Return 3500 ms after the sampler saw Messages in front, though the marker is late" \
    is "$(timing "$T/front.jsonl" "$late_marker" 900)" \
    "0: Return 3500 ms after the sampler saw Messages in front; phase front marker +1000 ms from the sampler's"
check "return_timing passes a Return 3000 ms after the sampler saw Messages in front" \
    is "$(timing "$T/front.jsonl" $'release-test 1050 phase front\nrelease-test 4000 key return' 900)" \
    "1: Return 3000 ms after the sampler saw Messages in front; phase front marker +50 ms from the sampler's"
check "return_timing passes without the phase front marker and says it is missing" \
    is "$(timing "$T/front.jsonl" 'release-test 3000 key return' 900)" \
    "1: Return 2000 ms after the sampler saw Messages in front; no phase front marker"
check "return_timing fails when the sampler never saw Messages in front, even with markers" \
    is "$(timing "$T/sample-hidden.jsonl" $'release-test 2000 phase front\nrelease-test 2500 key return' 0)" \
    "0: the sampler never saw Messages in front"
check "return_timing fails a Return before the sampler saw Messages in front" \
    is "$(timing "$T/front.jsonl" $'release-test 950 phase front\nrelease-test 980 key return' 900)" \
    "0: Return 20 ms before the sampler saw Messages in front; phase front marker -50 ms from the sampler's"
check "return_timing fails when no Return was posted" \
    is "$(timing "$T/front.jsonl" 'release-test 2000 phase front' 900)" \
    "0: no Return was posted; phase front marker +1000 ms from the sampler's"
check "t4 times Return with return_timing against its sample file" \
    is "$(grep -c -F 'return_timing "$SAMPLE_FILE" "$ACTION_START"' "$RT/t4-foreground.sh")" 2
check "t4 has no timing check of its own" not grep -q -E '^[[:space:]]*return_timing\(\)' "$RT/t4-foreground.sh"

# Timed-edit pool: messages too close to their window's end are dropped.
now="$(date +%s)"
printf '%s\n' "11 $((now - 900))" "12 $((now - 100))" "13 $((now - 50))" >"$RESULTS/pool.txt"
check "pool_next skips an expired message" is "$(pool_next)" 12
check "pool_next keeps the rest" is "$(cat "$RESULTS/pool.txt")" "13 $((now - 50))"

# The cases below run functions from the release tests themselves. functions_of prints every function a script
# defines, so a test can load them without running the script's own steps.
functions_of() {
    awk '!body && /^[a-z_]+\(\) \{/ { print; if ($0 !~ /\}$/) body = 1; next } body { print; if ($0 ~ /^}/) body = 0 }' "$1"
}
# A fake sampler. It writes a start line and the ready file, then on SIGTERM prints a verdict and exits with the next
# code in FAKE_SAMPLER_RCS (0 pass, 1 fail, 3 rerun, 4 invalid). The last code repeats.
mkdir -p "$T/tools" "$RESULTS/samples"
cat >"$T/tools/sampler" <<'EOF'
#!/bin/bash
out="" ready=""
while (($#)); do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        --ready) ready="$2"; shift 2 ;;
        *) shift ;;
    esac
done
read -r -a rcs <<<"${FAKE_SAMPLER_RCS:-0}"
n="$(cat "$FAKE_STATE/sampler.count" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$FAKE_STATE/sampler.count"
((n < ${#rcs[@]})) || n=$((${#rcs[@]} - 1))
rc="${rcs[$n]}"
case "$rc" in 0) v=pass ;; 1) v=fail ;; 3) v=rerun ;; *) v=invalid ;; esac
ms=$(($(date +%s) * 1000))
echo "{\"front\":\"com.apple.finder\",\"messages_hidden\":true,\"type\":\"start\",\"wall_ms\":$ms}" >"$out"
echo "$ms" >"$ready"
trap 'echo "verdict $v fake sampler"; exit "$rc"' TERM
while :; do sleep 0.02; done
EOF
chmod 755 "$T/tools/sampler"

# Test 1's Heart cases through run_sampled. A try whose sample is invalid runs again, so each try's setup must put
# the Heart back the way the action needs it, or the second press returns `already` and a good sample fails. This
# fake CLI keeps the Heart on message 101 in a file, and react answers `already` when nothing would change.
cat >"$T/imessage-heart" <<'EOF'
#!/bin/bash
heart="$FAKE_STATE/heart"
case "$1" in
    react)
        if [[ " $* " == *" --remove "* ]]; then
            if [[ -e "$heart" ]]; then rm -f "$heart"; code=ok; else code=already; fi
        elif [[ -e "$heart" ]]; then
            code=already
        else
            touch "$heart"
            code=ok
        fi
        echo "{\"result\":{\"code\":\"$code\",\"notes\":[]},\"type\":\"ui\"}" ;;
    show)
        echo '{"group":false,"id":7,"label":"Me","type":"chat"}'
        if [[ -e "$heart" ]]; then
            echo '{"id":101,"me":true,"ns":815640000000000000,"react":[{"by":"You","kind":"heart","part":0}],"text":"hi","type":"message"}'
        else
            echo '{"id":101,"me":true,"ns":815640000000000000,"text":"hi","type":"message"}'
        fi ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$T/imessage-heart"
# t1_heart <case> <Heart at the start: present or absent> <sampler codes>: runs the case with the setup and action
# t1-bridge.sh passes to run_sampled, and prints the status for its outcome line.
t1_heart() {
    local name="$1" start="$2" setup action
    read -r setup action < <(awk -v n="$name" '$1 == "run_sampled" && $2 == n { print $4, $5; exit }' "$RT/t1-bridge.sh")
    rm -f "$FAKE_STATE/heart" "$FAKE_STATE/sampler.count"
    [[ "$start" == present ]] && touch "$FAKE_STATE/heart"
    # The t1 functions read TARGET and call the stand-ins, which shellcheck can't see through the eval.
    # shellcheck disable=SC2034,SC2329
    (
        eval "$(functions_of "$RT/t1-bridge.sh")"
        IMSG="$T/imessage-heart" TOOLS="$T/tools" TARGET=101 FAKE_SAMPLER_RCS="$3"
        export FAKE_SAMPLER_RCS
        wait_messages_quit() { :; }
        front_other_app() { :; }
        messages_running() { :; }
        sleep() { command sleep 0.01; }
        run_sampled "$name" hidden "$setup" "$action" >/dev/null
        echo "$(sampled_status) after $(cat "$FAKE_STATE/sampler.count") tries: $ACTION_DETAIL"
    )
}
check "t1's Heart add passes when an invalid sample makes it run again" \
    is "$(t1_heart t1-cold-ui absent "4 0")" "pass after 2 tries: react heart: ok; Heart in chat.db: present"
check "t1's Heart remove passes when an invalid sample makes it run again" \
    is "$(t1_heart t1-heart-remove present "4 0")" "pass after 2 tries: react heart --remove: ok; Heart in chat.db: absent"
check "t1's Heart remove still presses when the Heart add left no Heart" \
    is "$(t1_heart t1-heart-remove absent 0)" "pass after 1 tries: react heart --remove: ok; Heart in chat.db: absent"

# Test 5's case loop with a fake sampler and injector. The fake edit writes a `phase front` marker and the fake
# injector posts 5 ms after it, so the case lands at before-field and the bridge stops there. The sampler's pass,
# fail and rerun are about the end state, which a takeover changes, but an invalid sample can miss a hide or a
# front-app change, so that try must run again.
cat >"$T/tools/hid-inject" <<'EOF'
#!/bin/bash
out=""
while (($#)); do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
for ((i = 0; i < 500; i++)); do
    if [[ -s "$FAKE_STATE/inject.go" ]]; then
        echo "{\"type\":\"inject\",\"wall_ms\":$(($(cat "$FAKE_STATE/inject.go") + 5))}" >"$out"
        rm -f "$FAKE_STATE/inject.go"
        exit 0
    fi
    sleep 0.01
done
exit 3
EOF
chmod 755 "$T/tools/hid-inject"
# t5_case <sampler codes>: runs before-field with a letter and prints the case's outcome line and how many tries ran.
t5_case() {
    rm -f "$FAKE_STATE/sampler.count" "$FAKE_STATE/inject.go"
    : >"$BRIDGE_LOG"
    # The t5 functions read the globals and call the stand-ins, which shellcheck can't see through the eval.
    # shellcheck disable=SC2034,SC2329
    (
        eval "$(grep -E '^[A-Z_]+=' "$RT/t5-abort.sh")"
        eval "$(functions_of "$RT/t5-abort.sh")"
        TOOLS="$T/tools" FAKE_SAMPLER_RCS="$1"
        export FAKE_SAMPLER_RCS
        setup_case() { :; }
        cleanup_case() { :; }
        abort_target() { ABORT_TARGET=101; }
        yes_no() { :; }
        sleep() { command sleep 0.01; }
        ui() {
            local ms=$(($(now_ms) + 10))
            echo "release-test $ms phase front" >>"$BRIDGE_LOG"
            echo "$ms" >"$FAKE_STATE/inject.go"
            UI_LINE="aborted: user took over"
            UI_CODE="$UI_LINE"
        }
        run_case before-field letter >/dev/null
        echo "$(tail -n 1 "$OUTCOMES" | cut -d' ' -f1-3) after $(cat "$FAKE_STATE/sampler.count") tries"
    )
}
check "t5 passes a landed case with a valid sample" is "$(t5_case 0)" "case pass t5-before-field-letter after 1 tries"
check "t5 judges a case whose sampler says rerun, since that is about the end state" \
    is "$(t5_case 3)" "case pass t5-before-field-letter after 1 tries"
check "t5 runs a case again after an invalid sample" is "$(t5_case "4 3")" "case pass t5-before-field-letter after 2 tries"
check "t5 never passes a case whose samples are all invalid" is "$(t5_case 4)" "case rerun t5-before-field-letter after 3 tries"

# Outcome lines.
cap pass unsend 1 detail here >/dev/null
gate fail fullscreen-panel 6 Messages showed >/dev/null
check "cap writes an outcome line" grep -q -x "cap pass unsend 1 detail here" "$OUTCOMES"
check "gate writes an outcome line" grep -q -x "gate fail fullscreen-panel 6 Messages showed" "$OUTCOMES"

echo "harness tests: $PASSED passed, $FAILED failed"
((FAILED == 0))
