#!/bin/bash
# shellcheck disable=SC2034  # globals for the scripts that source this file
# Shared helpers for the release tests. run.sh and t1 to t8 source this file. It doesn't run on its own.
#
# Every action goes through the imessage CLI, so the bridge performs it under its own grants. The sampler runs as
# its own process. Sends go only to IMSG_TEST_HANDLE, plus the opt-in IMSG_TEST_PEER and IMSG_TEST_GROUP chats when
# IMSG_TEST_CONSENT=1 says their people agreed. See README.md.

RT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RT_DIR/../.." && pwd)"
IMSG="${IMSG_CLI:-$HOME/.local/bin/imessage}"
APP="$HOME/Applications/iMessage Agent.app"
BRIDGE_LOG="$HOME/Library/Application Support/iMessage Agent/bridge.log"
STAGING_DIR="$HOME/Pictures/iMessage Agent"
MESSAGES_BUNDLE=com.apple.MobileSMS
SEND_SPACING=21
EDIT_WINDOW=900

die() { echo "error: $*" >&2; exit 2; }

require_handle() {
    [[ -n "${IMSG_TEST_HANDLE:-}" ]] \
        || die "IMSG_TEST_HANDLE is not set fix: export IMSG_TEST_HANDLE=<your own Apple ID email or +phone>. The tests send only to it"
    case "$IMSG_TEST_HANDLE" in
        *@*.*|+[0-9]*) ;;
        *) die "IMSG_TEST_HANDLE must be an email address or a +phone number" ;;
    esac
}

# Opt-in chats with other people. Each needs IMSG_TEST_CONSENT=1, which says everyone in it agreed to get test
# messages and tapbacks.
peer_ready() { [[ -n "${IMSG_TEST_PEER:-}" && "${IMSG_TEST_CONSENT:-}" == 1 ]]; }
group_ready() { [[ -n "${IMSG_TEST_GROUP:-}" && "${IMSG_TEST_CONSENT:-}" == 1 ]]; }
consented() { [[ -n "${1:-}" && "${IMSG_TEST_CONSENT:-}" == 1 ]]; }

# rt_init <test> [manual]: sets RESULTS, TOOLS, LOG and OUTCOMES. run.sh exports IMSG_RT_RESULTS so every test
# shares one folder. A manual test (test 7) skips the release-test build check and the sampler.
rt_init() {
    TEST_NUMBER="$1"
    local manual="${2:-}"
    require_handle
    [[ -x "$IMSG" ]] || die "no imessage CLI at $IMSG fix: install the release-test build (README.md)"
    if [[ -z "${IMSG_RT_RESULTS:-}" ]]; then
        IMSG_RT_RESULTS="$RT_DIR/results/$(macos_major_minor)-$(date +%Y%m%d-%H%M%S)-t$TEST_NUMBER"
    fi
    RESULTS="$IMSG_RT_RESULTS"
    TOOLS="$RESULTS/bin"
    LOG="$RESULTS/t$TEST_NUMBER.log"
    OUTCOMES="$RESULTS/outcomes.txt"
    if ! { mkdir -p "$RESULTS/samples" "$RESULTS/files" "$TOOLS" && chmod 700 "$RESULTS" && touch "$OUTCOMES"; }; then
        die "can't write the results folder $RESULTS fix: set IMSG_RT_RESULTS to a folder you can write"
    fi
    if [[ "$manual" != manual ]]; then
        if [[ -z "${IMSG_RT_CHECKED:-}" ]]; then
            check_release_build
            IMSG_RT_CHECKED=1
        fi
        need_tool sampler
    fi
    msg "== release test $TEST_NUMBER, results in $RESULTS"
}

macos_major_minor() {
    local v
    v="$(sw_vers -productVersion)"
    case "$v" in
        *.*) echo "$v" | cut -d. -f1-2 ;;
        *) echo "$v.0" ;;
    esac
}

bridge_version() { plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo unknown; }

# The release-test build reports every capability as supported and says so in the caps header.
check_release_build() {
    local out
    out="$("$IMSG" caps 2>&1)" || die "imessage caps failed: $out"
    grep -q -i 'release-test build' <<<"$out" \
        || die "the installed bridge isn't the release-test build fix: install out/release-tests/ as README.md says"
}

# Runs `imessage doctor --ui` and dies unless the grants are in place. Doctor exits 0 even when a check fails, so this
# reads its report. The bridge's chat.db, Automation and Accessibility checks and the Automation and Accessibility
# prompt checks must not fail. Action names, last run and allowlist don't stop a run.
require_grants() {
    im doctor --ui
    [[ "$IM_RC" == 0 ]] || die "imessage doctor --ui failed (exit $IM_RC). Fix the grants and run again. Output is in $LOG"
    grep -q '^doctor ' <<<"$IM_OUT" || die "imessage doctor --ui printed no report. Output is in $LOG"
    local missing
    missing="$(printf '%s\n' "$IM_OUT" | grep -E '^fail (chat\.db|Automation|Accessibility)')"
    [[ -z "$missing" ]] || die "imessage doctor --ui reports missing grants:"$'\n'"$missing"$'\n'"grant them, then run again"
}

# Compiles one Swift tool into $TOOLS once per results folder.
need_tool() {
    local name="$1"
    [[ -x "$TOOLS/$name" ]] && return 0
    msg "compiling $name.swift"
    swiftc -swift-version 5 -O -o "$TOOLS/$name" "$RT_DIR/$name.swift" >>"$RESULTS/compile.log" 2>&1 \
        || die "compiling $name.swift failed, see $RESULTS/compile.log"
}

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }
msg() { echo "$*"; log "$*"; }

# Prompts read from the terminal, so they work while stdout goes to a pipe.
ask() {
    printf '\n>> %s\n   Press Return when ready, or type s and Return to skip this case: ' "$1" >/dev/tty
    local answer
    read -r answer </dev/tty
    log "asked: $1 -> ${answer:-ready}"
    [[ "$answer" != s ]]
}
yes_no() {
    local answer
    while true; do
        printf '\n>> %s [y/n] ' "$1" >/dev/tty
        read -r answer </dev/tty
        case "$answer" in
            y|Y) log "asked: $1 -> y"; return 0 ;;
            n|N) log "asked: $1 -> n"; return 1 ;;
        esac
    done
}
tell() { printf '   %s\n' "$*" >/dev/tty; log "told: $*"; }

# Outcome lines for run.sh and write-evidence.swift.
#   cap <pass|fail|skip|rerun> <capability> <test> <detail>
#   gate <pass|fail|rerun|skip> <name> <test> <detail>
cap() {
    local status="$1" capability="$2" test="$3"
    shift 3
    echo "cap $status $capability $test $*" >>"$OUTCOMES"
    msg "   -> $status: $capability (test $test) $*"
}
gate() {
    local status="$1" name="$2" test="$3"
    shift 3
    echo "gate $status $name $test $*" >>"$OUTCOMES"
    msg "   -> gate $status: $name (test $test) $*"
}

now_ms() { echo $(($(date +%s) * 1000)); }

# Runs the CLI. Sets IM_RC, IM_OUT, IM_ERR and IM_JSON (the last JSON line of stdout). Send, ui, caps and att print
# one JSON line, so IM_JSON is their result. Reads print several records, so pick them by type with json_record.
im() {
    local o e
    o="$(mktemp "$RESULTS/.out.XXXXXX")"
    e="$(mktemp "$RESULTS/.err.XXXXXX")"
    "$IMSG" "$@" >"$o" 2>"$e"
    IM_RC=$?
    IM_OUT="$(cat "$o")"
    IM_ERR="$(cat "$e")"
    rm -f "$o" "$e"
    IM_JSON="$(printf '%s\n' "$IM_OUT" | grep '^{' | tail -n 1)"
    {
        echo "\$ imessage $* (exit $IM_RC)"
        [[ -n "$IM_OUT" ]] && printf '%s\n' "$IM_OUT"
        [[ -n "$IM_ERR" ]] && printf 'stderr: %s\n' "$IM_ERR"
    } >>"$LOG"
}

# A JSON lookup with plutil. A keypath like parts.0.rowid. The key names are the CLI's `--json` names, pinned by
# the golden files in scripts/tests/fixtures (NDJSONGoldenTests). A message record has id, ns, me (only when
# true), reply (the parent's ROWID), parts (only past 1), delivered (Apple ns, once set), att.N.id/name/kind/state/uti
# and react.N.kind/by. Send and ui results use their wire names: parts.N.part/rowid/result, early and result.
jget() { printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null; }

# "<code>[, <note>]..." from an ActionResult at keypath $2 of JSON $1.
result_line() {
    local j="$1" k="$2" code out i n
    code="$(jget "$j" "$k.code")" || { echo "no result"; return; }
    out="$code"
    i=0
    while n="$(jget "$j" "$k.notes.$i")"; do
        out="$out, $n"
        i=$((i + 1))
    done
    echo "$out"
}

test_text() { echo "imessage-agent release test $* $(date +%Y%m%d-%H%M%S)"; }

wait_for_send_spacing() {
    local last now
    last="$(cat "$RESULTS/.last-send" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if ((now - last < SEND_SPACING)); then sleep $((SEND_SPACING - (now - last))); fi
}

# send <who> [args...]: a send through the CLI, spaced for the per-chat rate limit. Sets SEND_CODE (the first
# part's result, or the early result), SEND_LINE, SEND_ROWID and SEND_FILE_ROWID.
send() {
    local who="$1"
    shift
    wait_for_send_spacing
    tell "If an iMessage Agent dialog appears for this send, click Allow once."
    im send "$who" "$@" --json
    date +%s >"$RESULTS/.last-send"
    SEND_ROWID=""
    SEND_FILE_ROWID=""
    if jget "$IM_JSON" early.code >/dev/null; then
        SEND_LINE="$(result_line "$IM_JSON" early)"
    else
        SEND_LINE="$(result_line "$IM_JSON" parts.0.result)"
        local i=0 kind
        while kind="$(jget "$IM_JSON" "parts.$i.part")"; do
            if [[ "$kind" == file ]]; then
                SEND_FILE_ROWID="$(jget "$IM_JSON" "parts.$i.rowid")"
                SEND_LINE="$(result_line "$IM_JSON" "parts.$i.result")"
            elif [[ -z "$SEND_ROWID" ]]; then
                SEND_ROWID="$(jget "$IM_JSON" "parts.$i.rowid")"
            fi
            i=$((i + 1))
        done
    fi
    SEND_CODE="${SEND_LINE%%,*}"
    log "send result: $SEND_LINE rowid=$SEND_ROWID file_rowid=$SEND_FILE_ROWID"
}
send_ok() { [[ "$SEND_CODE" == delivered || "$SEND_CODE" == submitted ]] && [[ "$SEND_LINE" != *"became visible"* ]]; }

# react <rowid> <kind> [--remove], unsend <rowid>, edit <rowid> <text>. Always with --again, so a repeat in the
# same test presses again instead of returning the first result. Sets UI_CODE and UI_LINE.
ui() {
    im "$@" --again --json
    UI_LINE="$(result_line "$IM_JSON" result)"
    UI_CODE="${UI_LINE%%,*}"
    log "ui result: $UI_LINE"
}
ui_ok() { [[ "$UI_CODE" == ok ]] && [[ "$UI_LINE" != *"became visible"* ]]; }

# Lookups fail closed. Each one returns nonzero when the CLI failed or its output lacks the record that proves it
# answered, so a failed lookup can't pass for "no Heart", "nothing marked read" or "no reply row". An empty answer
# that the CLI did give, such as no unread messages, still counts.

# json_lines: the JSON object lines of IM_OUT. `--json` prints one record per line, each with a `type`.
json_lines() { printf '%s\n' "$IM_OUT" | grep '^{'; }

# json_record <type>: the first JSON line of IM_OUT whose type is <type>. Returns 1 when there is none.
json_record() {
    local line
    while IFS= read -r line; do
        if [[ "$(jget "$line" type)" == "$1" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done < <(json_lines)
    return 1
}

# wait_message_id: the id of the message `imessage wait --json` printed after its chat line. Prints nothing and
# returns 1 on a timeout or a failed wait.
wait_message_id() {
    [[ "$IM_RC" == 0 ]] || return 1
    local m
    m="$(json_record message)" || return 1
    jget "$m" id
}

# show_json <rowid>: sets SHOW_JSON to the message line of `imessage show <rowid> --json`. Returns 1, with SHOW_JSON
# empty, unless the CLI exited 0 and printed a message line whose id is <rowid>.
show_json() {
    SHOW_JSON=""
    im show "$1" --json
    [[ "$IM_RC" == 0 ]] || return 1
    local line
    while IFS= read -r line; do
        [[ "$(jget "$line" type)" == message ]] || continue
        [[ "$(jget "$line" id)" == "$1" ]] || return 1
        SHOW_JSON="$line"
        return 0
    done < <(json_lines)
    return 1
}
msg_get() { jget "$SHOW_JSON" "$1"; }
# msg_flag <key>: true or false for a flag of SHOW_JSON, which prints only when true, or unknown with no message.
msg_flag() {
    [[ -n "$SHOW_JSON" ]] || { echo unknown; return; }
    msg_get "$1" || echo false
}

# my_reactions <rowid>: kinds of the user's own reactions on <rowid>, one per line. Each `react` entry has a kind,
# and `by` is "You" for the user's own. Returns 1 when show_json fails.
my_reactions() {
    show_json "$1" || return 1
    local i=0 kind
    while kind="$(jget "$SHOW_JSON" "react.$i.kind")"; do
        if [[ "$(jget "$SHOW_JSON" "react.$i.by")" == You ]]; then echo "$kind"; fi
        i=$((i + 1))
    done
    return 0
}
# has_my_reaction <rowid> <kind>: 0 when the user's <kind> reaction is on <rowid>, 1 when it isn't, 2 when the
# lookup failed. Sets REACTION_STATE to present, absent or unknown. Write `lacks_my_reaction`, never
# `! has_my_reaction`, because `!` turns a failed lookup into a pass.
has_my_reaction() {
    local kinds
    if ! kinds="$(my_reactions "$1")"; then
        REACTION_STATE=unknown
        return 2
    fi
    if grep -q -x -F -- "$2" <<<"$kinds"; then
        REACTION_STATE=present
        return 0
    fi
    REACTION_STATE=absent
    return 1
}
# lacks_my_reaction <rowid> <kind>: true only when the lookup worked and the reaction isn't there.
lacks_my_reaction() {
    has_my_reaction "$1" "$2"
    (($? == 1))
}

# Removes the user's reaction <kind> from <rowid> if it is there, outside any sample.
clear_reaction() { if has_my_reaction "$1" "$2"; then ui react "$1" "$2" --remove; fi; }

# read_messages <who> <n> [read options]: the message lines of `imessage read <who> -n <n> --json`, oldest first.
# The chat line and a `more` record are left out. The output cap keeps about 12 KB, so a page can hold fewer than
# <n> messages. Returns 1 unless the CLI exited 0 and printed the chat line that heads every page. A chat with no
# messages prints nothing.
read_messages() {
    local who="$1" n="$2"
    shift 2
    im read "$who" -n "$n" "$@" --json
    [[ "$IM_RC" == 0 ]] || return 1
    local line have_chat=0 out=""
    while IFS= read -r line; do
        case "$(jget "$line" type)" in
            chat) have_chat=1 ;;
            message) out+="$line"$'\n' ;;
        esac
    done < <(json_lines)
    ((have_chat)) || return 1
    printf '%s' "$out"
}

# chat_total <who>: how many visible messages the chat has, from the chat line of `imessage read`. Returns 1 when the
# read failed.
chat_total() {
    im read "$1" -n 1 --json
    [[ "$IM_RC" == 0 ]] || return 1
    local c
    c="$(json_record chat)" || return 1
    jget "$c" total
}

# unread_ids: ids of the unread messages `imessage unread --json` lists, sorted, one per line. Context lines it
# prints around them don't count. Returns 1 unless the CLI exited 0 and printed its unread header. No unread
# messages prints nothing and returns 0.
unread_ids() {
    im unread --json
    [[ "$IM_RC" == 0 ]] || return 1
    local line have_header=0 ids=""
    while IFS= read -r line; do
        case "$(jget "$line" type)" in
            unread) have_header=1 ;;
            message) if [[ "$(jget "$line" unread)" == true ]]; then ids+="$(jget "$line" id)"$'\n'; fi ;;
        esac
    done < <(json_lines)
    ((have_header)) || return 1
    printf '%s' "$ids" | sort -n
}

# no_press_check <rowid> <code>: a Heart on <rowid> must give <code> and press nothing, so no Heart lands and the
# unread messages don't change. Sets CHECK_STATUS to pass, fail or rerun, and CHECK_DETAIL. A wrong code or a Heart
# found is a fail. A lookup that failed is a rerun, never a pass.
no_press_check() {
    local rowid="$1" want="$2" before after after_rc heart_rc
    if ! before="$(unread_ids)"; then
        CHECK_STATUS=rerun
        CHECK_DETAIL="imessage unread failed before the press, so a read-state change couldn't be seen"
        return
    fi
    ui react "$rowid" heart
    after="$(unread_ids)"
    after_rc=$?
    has_my_reaction "$rowid" heart
    heart_rc=$?
    CHECK_STATUS=fail
    if [[ "$UI_CODE" != "$want" ]]; then
        CHECK_DETAIL="wanted $want, got $UI_LINE"
    elif ((heart_rc == 0)); then
        CHECK_DETAIL="$UI_LINE, but a Heart is on $rowid"
    elif ((after_rc != 0)); then
        CHECK_STATUS=rerun
        CHECK_DETAIL="$UI_LINE, but imessage unread failed after the press"
    elif ((heart_rc != 1)); then
        CHECK_STATUS=rerun
        CHECK_DETAIL="$UI_LINE, but imessage show $rowid failed, so a Heart couldn't be ruled out"
    elif [[ "$before" != "$after" ]]; then
        CHECK_DETAIL="$UI_LINE, but the unread messages changed"
    else
        CHECK_STATUS=pass
        CHECK_DETAIL="$UI_LINE"
    fi
}

# parent_changed_check <who> <result line>: a threaded reply whose parent changed after approval must give
# `aborted: parent changed` and leave no reply row, so the newest message in the chat isn't the user's. Sets
# CHECK_STATUS to pass, fail or rerun, and CHECK_DETAIL. A read that failed or came back empty is a rerun.
parent_changed_check() {
    local who="$1" line="$2" lines newest read_rc=0
    lines="$(read_messages "$who" 3)" || read_rc=$?
    newest="$(printf '%s\n' "$lines" | tail -n 1)"
    CHECK_STATUS=fail
    if [[ "$line" != "aborted: parent changed"* ]]; then
        CHECK_DETAIL="$line"
    elif ((read_rc != 0)); then
        CHECK_STATUS=rerun
        CHECK_DETAIL="$line, but imessage read failed, so a reply row couldn't be ruled out"
    elif [[ -z "$newest" ]]; then
        CHECK_STATUS=rerun
        CHECK_DETAIL="$line, but imessage read printed no messages"
    elif [[ "$(jget "$newest" me)" == true ]]; then
        CHECK_DETAIL="$line, but the newest row $(jget "$newest" id) is from you"
    else
        CHECK_STATUS=pass
        CHECK_DETAIL="$line, no reply row"
    fi
}

apple_ns_to_epoch() { echo $(($1 / 1000000000 + 978307200)); }
today_start_epoch() { date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s; }

# Front app bundle id, from Launch Services' read-only app list.
front_bundle() { lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*="\(.*\)"/\1/p'; }

messages_running() { pgrep -x Messages >/dev/null; }

front_other_app() {
    ask "If a Messages window shows, hide Messages with Command-H. Then click a Finder window so Finder is in front. After you press Return, touch nothing except an iMessage Agent dialog until this case finishes." || return 1
    if [[ "$(front_bundle)" == "$MESSAGES_BUNDLE" ]]; then
        tell "Messages is still in front."
        return 1
    fi
}

wait_messages_quit() {
    ask "Quit Messages with Command-Q if it is open." || return 1
    local i=0
    while messages_running && ((i < 60)); do sleep 1; i=$((i + 1)); done
    if messages_running; then
        tell "Messages is still running."
        return 1
    fi
}

# run_sampled <name> <hidden|foreground> <setup function> <action function> [--also BUNDLE]
# Runs setup, starts the sampler, runs the action, waits 1.5 s, stops the sampler. Repeats up to 3 times while the
# sampler says rerun or invalid. The action sets ACTION_OK (1 or 0) and ACTION_DETAIL, and ACTION_RERUN=1 when its
# own result doesn't count (a timed edit that missed its moment). Sets SAMPLE_STATUS to pass, fail, rerun, invalid
# or skip, and SAMPLE_REASON.
run_sampled() {
    local name="$1" mode="$2" setup="$3" action="$4" try verdict_file ready
    shift 4
    SAMPLE_STATUS=skip
    SAMPLE_REASON="setup skipped"
    ACTION_OK=0
    ACTION_DETAIL=""
    for try in 1 2 3; do
        msg "-- $name (try $try)"
        if ! "$setup"; then
            SAMPLE_STATUS=skip
            SAMPLE_REASON="setup skipped"
            return
        fi
        SAMPLE_FILE="$RESULTS/samples/$name-$try.jsonl"
        verdict_file="$RESULTS/samples/$name-$try.verdict"
        ready="$RESULTS/samples/.$name-$try.ready"
        rm -f "$ready"
        "$TOOLS/sampler" --out "$SAMPLE_FILE" --mode "$mode" --ready "$ready" "$@" >"$verdict_file" 2>&1 &
        SAMPLER_PID=$!
        local i=0
        while [[ ! -e "$ready" ]] && ((i < 500)); do sleep 0.01; i=$((i + 1)); done
        if [[ ! -e "$ready" ]]; then
            kill "$SAMPLER_PID" 2>/dev/null
            die "the sampler didn't start, see $verdict_file"
        fi
        SAMPLE_START_MS="$(head -n 1 "$ready")"
        ACTION_OK=0
        ACTION_DETAIL=""
        ACTION_RERUN=0
        "$action"
        sleep 1.5
        kill -TERM "$SAMPLER_PID" 2>/dev/null
        wait "$SAMPLER_PID"
        local rc=$?
        SAMPLE_REASON="$(sed -n 's/^verdict [a-z]* //p' "$verdict_file")"
        case "$rc" in
            0) SAMPLE_STATUS=pass ;;
            1) SAMPLE_STATUS=fail ;;
            3) SAMPLE_STATUS=rerun ;;
            *) SAMPLE_STATUS=invalid ;;
        esac
        msg "   sampler: $SAMPLE_STATUS $SAMPLE_REASON; action: $([[ $ACTION_OK == 1 ]] && echo ok || echo failed) $ACTION_DETAIL"
        if [[ "$ACTION_RERUN" == 1 && "$SAMPLE_STATUS" != fail ]]; then
            SAMPLE_STATUS=rerun
            SAMPLE_REASON="the action asked for a rerun"
        fi
        [[ "$SAMPLE_STATUS" == pass || "$SAMPLE_STATUS" == fail ]] && return
        tell "Rerun: $SAMPLE_REASON"
    done
}

# Status for an outcome line from the last run_sampled: pass only when both the sample and the action passed.
sampled_status() {
    case "$SAMPLE_STATUS" in
        pass) [[ "$ACTION_OK" == 1 ]] && echo pass || echo fail ;;
        fail) echo fail ;;
        skip) echo skip ;;
        *) echo rerun ;;
    esac
}
sampled_detail() { echo "sample $SAMPLE_STATUS ($SAMPLE_REASON); $ACTION_DETAIL"; }

# Bridge markers. The release-test build writes `release-test <unix ms> <event> [detail]` lines to bridge.log right
# before each foreground step (README.md lists them). markers_since <ms> prints "<ms> <event> [detail]" lines.
markers_since() {
    [[ -f "$BRIDGE_LOG" ]] || return 0
    grep -a -o 'release-test [0-9][0-9]* .*' "$BRIDGE_LOG" | awk -v s="$1" '$2 + 0 >= s { sub(/^release-test /, ""); print }'
}
# first_marker <since ms> <event words...>: the ms of the first marker that starts with those words.
first_marker() {
    local since="$1"
    shift
    markers_since "$since" | awk -v e="$*" 'index(substr($0, index($0, " ") + 1), e) == 1 { print $1; exit }'
}
have_markers() { [[ -f "$BRIDGE_LOG" ]] && grep -a -q 'release-test [0-9][0-9]* phase ' "$BRIDGE_LOG"; }

# sampled_front_ms <sample file> <since ms>: wall ms of the first sample at or after that time in which the sampler
# saw Messages frontmost. Prints nothing and returns 1 when it saw none.
sampled_front_ms() {
    local file="$1" since="$2" line ms
    [[ -f "$file" ]] || return 1
    while IFS= read -r line; do
        [[ "$(jget "$line" bundle)" == "$MESSAGES_BUNDLE" ]] || continue
        ms="$(jget "$line" wall_ms)" || continue
        if ((ms >= since)); then
            echo "$ms"
            return 0
        fi
    done < <(grep -E '"type":"front"' "$file")
    return 1
}

# return_timing <sample file> <since ms>: test 4's check that Return comes within 3 s of t_front. t_front is the
# sampler's first sample with Messages frontmost. The bridge's `phase front` marker comes from the bridge's own
# record of t_front, which a slow activation call can delay, so the detail gives it only as a cross-check. Sets
# TIMING_OK and TIMING_DETAIL.
return_timing() {
    local file="$1" since="$2" t_front t_return t_marker
    t_front="$(sampled_front_ms "$file" "$since")"
    t_return="$(first_marker "$since" key return)"
    t_marker="$(first_marker "$since" phase front)"
    TIMING_OK=0
    if [[ -z "$t_front" ]]; then
        TIMING_DETAIL="the sampler never saw Messages in front"
    elif [[ -z "$t_return" ]]; then
        TIMING_DETAIL="no Return was posted"
    elif ((t_return < t_front)); then
        TIMING_DETAIL="Return $((t_front - t_return)) ms before the sampler saw Messages in front"
    else
        TIMING_DETAIL="Return $((t_return - t_front)) ms after the sampler saw Messages in front"
        ((t_return - t_front <= 3000)) && TIMING_OK=1
    fi
    if [[ -z "$t_marker" ]]; then
        TIMING_DETAIL="$TIMING_DETAIL; no phase front marker"
    elif [[ -n "$t_front" ]]; then
        TIMING_DETAIL="$TIMING_DETAIL; phase front marker $(printf '%+d' $((t_marker - t_front))) ms from the sampler's"
    fi
}

# sampled_effects <sample file> <after ms> <check front: 1 or 0>: Messages hides, and front-app changes when asked,
# that the sampler saw after that time, one per line.
sampled_effects() {
    local file="$1" after="$2" front="$3" line type ms hidden=""
    [[ -f "$file" ]] || { echo "no sample file"; return; }
    while IFS= read -r line; do
        type="$(jget "$line" type)"
        ms="$(jget "$line" wall_ms)"
        case "$type" in
            start) hidden="$(jget "$line" messages_hidden)" ;;
            messages_app)
                if [[ "$(jget "$line" hidden)" == true && "$hidden" != true ]] && ((ms > after)); then
                    echo "Messages hid at $ms"
                fi
                hidden="$(jget "$line" hidden)" ;;
            front)
                if ((front == 1 && ms > after)); then echo "front app changed to $(jget "$line" bundle) at $ms"; fi ;;
        esac
    done < <(grep -E '"type":"(start|messages_app|front)"' "$file")
}

foreground_mode_on() {
    im caps --json
    [[ "$(jget "$IM_JSON" foregroundMode)" == true ]]
}
require_foreground_mode() {
    foreground_mode_on && return 0
    tell "Foreground mode is off. The next command asks for it in an iMessage Agent dialog. Click Allow once."
    im allow --foreground
    foreground_mode_on || die "foreground mode is still off"
}

# Messages the test may edit: sent by the user, single part (no `parts` key) and text only.
editable_message() {
    [[ "$(jget "$1" me)" == true && "$(jget "$1" unsent)" != true ]] && ! jget "$1" parts >/dev/null \
        && ! jget "$1" att.0.id >/dev/null && [[ -n "$(jget "$1" text)" ]]
}

# multipart_id <message lines>: the id of the newest multipart message that isn't unsent. The `parts` key is there
# only past one part.
multipart_id() {
    local m multi=""
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        if (("$(jget "$m" parts || echo 1)" > 1)) && [[ "$(jget "$m" unsent)" != true ]]; then multi="$(jget "$m" id)"; fi
    done <<<"$1"
    [[ -n "$multi" ]] && echo "$multi"
}

# Seconds since <rowid> was sent, from chat.db's date.
message_age() {
    show_json "$1"
    local ns
    ns="$(msg_get ns)" || { echo 99999; return; }
    echo $(($(date +%s) - $(apple_ns_to_epoch "$ns")))
}

# Timed edits. The edit is timed so its 15-minute window closes after Messages comes forward and before Return.
# That makes the bridge take its own cleanup path (a bridge-owned failure). The maintainer clicks Allow once on a
# countdown. NEAR_LEAD is how many seconds before the window closes the click should land. It adapts after each try.
#
# near_expiry_wait <rowid>: sleeps until the edit should start. Returns 1 and sets NE_RESULT=skip if the message is
# already too old. A caller that samples or injects input starts those after this returns.
# near_expiry_edit <rowid> <new text>: runs the edit with the countdown. Sets NE_RESULT to cleanup, early (the edit
# went through), late (it expired before Messages came forward), plus NE_START_MS, UI_CODE and UI_LINE.
NEAR_LEAD="${NEAR_LEAD:-3}"
near_expiry_wait() {
    show_json "$1"
    local sent_epoch now start_epoch
    sent_epoch="$(apple_ns_to_epoch "$(msg_get ns || echo 0)")"
    NE_CLICK_EPOCH=$((sent_epoch + EDIT_WINDOW - NEAR_LEAD))
    start_epoch=$((NE_CLICK_EPOCH - 8))
    now="$(date +%s)"
    if ((start_epoch < now)); then
        NE_RESULT=skip
        tell "Message $1 is too old for a timed edit."
        return 1
    fi
    if ((start_epoch - now > 30)); then
        tell "Timed edit of $1 starts in $((start_epoch - now)) s. You can use the Mac until the 20 s warning."
        sleep $((start_epoch - now - 20))
        printf '\a' >/dev/tty
        now="$(date +%s)"
    fi
    tell "Timed edit starts in $((start_epoch - now)) s. Go back to the app that was in front and touch nothing. When the dialog shows, wait for the countdown, then click Allow once."
    sleep $((start_epoch - now))
}
near_expiry_edit() {
    local rowid="$1" text="$2" out="$RESULTS/.near-$1.json" edit_pid
    NE_START_MS="$(now_ms)"
    "$IMSG" edit "$rowid" "$text" --again --json >"$out" 2>>"$LOG" &
    edit_pid=$!
    while (($(date +%s) < NE_CLICK_EPOCH)); do
        printf '\r   click Allow once in %2d s ' $((NE_CLICK_EPOCH - $(date +%s))) >/dev/tty
        sleep 0.2
    done
    printf '\r   click Allow once NOW          \n' >/dev/tty
    wait "$edit_pid"
    IM_JSON="$(grep '^{' "$out" | tail -n 1)"
    UI_LINE="$(result_line "$IM_JSON" result)"
    UI_CODE="${UI_LINE%%,*}"
    log "timed edit $rowid lead $NEAR_LEAD: $UI_LINE"
    if [[ -n "$(first_marker "$NE_START_MS" phase bridgeOwnedCleanup)" ]]; then
        NE_RESULT=cleanup
    elif [[ -n "$(first_marker "$NE_START_MS" key return)" ]]; then
        NE_RESULT=early
        NEAR_LEAD=$((NEAR_LEAD > 1 ? NEAR_LEAD - 1 : 1))
    else
        NE_RESULT=late
        NEAR_LEAD=$((NEAR_LEAD + 1))
    fi
    msg "   timed edit: $NE_RESULT ($UI_LINE), next lead $NEAR_LEAD s"
}

# prepare_pool <count> <spacing s>: sends that many messages to the test handle for timed edits, one every spacing
# seconds, so their windows close one after another at that pace. Writes "<rowid> <sent epoch>" lines to
# $RESULTS/pool.txt.
prepare_pool() {
    local n="$1" spacing="$2" i next
    : >"$RESULTS/pool.txt"
    msg "sending $n messages for timed edits, one every $spacing s"
    for ((i = 1; i <= n; i++)); do
        next=$(($(date +%s) + spacing))
        send "$IMSG_TEST_HANDLE" "$(test_text timed edit target "$i")"
        if send_ok && [[ -n "$SEND_ROWID" ]]; then echo "$SEND_ROWID $(date +%s)" >>"$RESULTS/pool.txt"; fi
        ((i < n && next > $(date +%s))) && sleep $((next - $(date +%s)))
    done
}
# Next pool message whose window isn't too close to closing. Prints its rowid and drops it, and every message
# that is already too old, from the pool.
pool_next() {
    local now rowid sent picked="" rest=""
    now="$(date +%s)"
    while read -r rowid sent; do
        [[ -n "$rowid" ]] || continue
        ((sent + EDIT_WINDOW - NEAR_LEAD - 10 > now)) || continue
        if [[ -z "$picked" ]]; then picked="$rowid"; else rest="$rest$rowid $sent"$'\n'; fi
    done <"$RESULTS/pool.txt"
    printf '%s' "$rest" >"$RESULTS/pool.txt"
    [[ -n "$picked" ]] && echo "$picked"
}
