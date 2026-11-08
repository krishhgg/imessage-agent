#!/bin/bash
# Release test 5: the foreground abort path (DESIGN.md "Release tests" item 5, section 4 "Ownership check").
# run.sh runs it only with --foreground.
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t5-abort.sh
#
# hid-inject posts a modifier key, a letter key, a mouse click and Command-Tab at the HID tap, each at five points
# of an edit in your own chat:
#   before-field          after Messages comes forward, before the field is set
#   field-restore         while a bridge-owned failure restores the field
#   between-escapes       between that failure's cleanup Escapes
#   before-hide           after Return, right before the hide
#   before-focus-restore  after the hide, right before the focus restore
# The bridge-owned failure comes from an edit timed so its 15-minute window closes after Messages comes forward
# (near_expiry_edit in lib.sh). The terminal app needs Accessibility so hid-inject can post events.
#
# The release-test markers in bridge.log aim the injection and show where it landed. Each injection goes out as
# soon as its marker shows. A case that didn't land at its point, or whose sample is invalid, is tried again, up to
# 3 times. Each case passes when:
#   - before Return, the result is `aborted: user took over` and no Return was posted
#   - after Return, the result is step 7's result plus `user took over`
#   - no key event, hide or focus restore marker comes more than 15 ms after the injection (the field reset is the
#     only write allowed)
#   - at the points before the hide, the sampler saw no Messages hide more than 100 ms after the injection, and,
#     for events other than the app switch, no front-app change. This doesn't rely on the bridge's own markers.
#   - you confirm the field rule in Messages
# Foreground mode is recorded only when every case passes here and test 6b passes.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 5
need_tool hid-inject
require_foreground_mode

SELF="$IMSG_TEST_HANDLE"
EVENTS="modifier letter click app-switch"
GRACE_MS=15
SAMPLE_GRACE_MS=100
FAILED=""
UNLANDED=""

trigger_for() {
    case "$1" in
        before-field) echo 'release-test [0-9]+ phase front( |$)' ;;
        field-restore) echo 'release-test [0-9]+ phase bridgeOwnedCleanup( |$)' ;;
        between-escapes) echo 'release-test [0-9]+ key escape( |$)' ;;
        before-hide) echo 'release-test [0-9]+ phase finishing( |$)' ;;
        before-focus-restore) echo 'release-test [0-9]+ hide( |$)' ;;
    esac
}

# Targets. An aborted edit leaves the message as it was, so before-field reuses one message while its window is
# open. A committed edit counts toward Messages' limit of 5 per message, so those targets change after 4.
ABORT_TARGET=""
COMMIT_TARGET=""
COMMIT_EDITS=0
fresh_target() {
    send "$SELF" "$(test_text t5 "$1")"
    send_ok && [[ -n "$SEND_ROWID" ]] || die "the target send failed: $SEND_LINE"
    FRESH_ROWID="$SEND_ROWID"
}
abort_target() {
    if [[ -z "$ABORT_TARGET" ]] || (($(message_age "$ABORT_TARGET") > 720)); then
        fresh_target abort target
        ABORT_TARGET="$FRESH_ROWID"
    fi
}
commit_target() {
    if [[ -z "$COMMIT_TARGET" ]] || ((COMMIT_EDITS >= 4)) || (($(message_age "$COMMIT_TARGET") > 720)); then
        fresh_target commit target
        COMMIT_TARGET="$FRESH_ROWID"
        COMMIT_EDITS=0
    fi
}

setup_case() {
    local event="$1"
    foreground_mode_on || require_foreground_mode
    if [[ "$event" == click ]]; then
        ask "Move the pointer over an empty part of the menu bar and leave it there. The test clicks where it is." || return 1
    fi
    front_other_app || return 1
    tell "Click Allow once when the dialog shows, then touch nothing. The test posts the input itself."
}

cleanup_case() {
    ask "Put Messages back: press Escape in Messages until no edit field shows, delete any x the test typed in the edit field or the message field, then hide Messages with Command-H." || true
}

# landed <point> <inj ms> <since ms>: true when the injection came at its point.
landed() {
    local point="$1" inj="$2" s="$3" a b
    case "$point" in
        before-field) a="$(first_marker "$s" phase front)"; b="$(first_marker "$s" field-set)" ;;
        field-restore)
            a="$(first_marker "$s" phase bridgeOwnedCleanup)"
            b="$([[ -n "$a" ]] && first_marker "$a" key escape)" ;;
        between-escapes)
            a="$(first_marker "$s" phase bridgeOwnedCleanup)"
            a="$([[ -n "$a" ]] && first_marker "$a" key escape)"
            b="$(first_marker "$s" hide)" ;;
        before-hide) a="$(first_marker "$s" key return)"; b="$(first_marker "$s" hide)" ;;
        before-focus-restore) a="$(first_marker "$s" hide)"; b="$(first_marker "$s" focus-restore)" ;;
    esac
    [[ -n "$a" ]] && ((inj >= a)) && { [[ -z "$b" ]] || ((inj < b)); }
}

# run_case <point> <event>
run_case() {
    local point="$1" event="$2" name="$1-$2" try inj_file inj_pid inj since rowid text sample_ready sampler_rc
    for try in 1 2 3; do
        msg "-- $name (try $try)"
        if ! setup_case "$event"; then
            UNLANDED="$UNLANDED $name"
            echo "case skip t5-$name 5 setup skipped" >>"$OUTCOMES"
            return
        fi
        text="$(test_text t5 "$name" edit)"
        case "$point" in
            before-field) abort_target; rowid="$ABORT_TARGET" ;;
            before-hide|before-focus-restore) commit_target; rowid="$COMMIT_TARGET" ;;
            *)
                rowid="$(pool_next)"
                if [[ -z "$rowid" ]]; then
                    msg "   no timed-edit message left in the pool"
                    break
                fi
                near_expiry_wait "$rowid" || continue ;;
        esac
        sample_ready="$RESULTS/samples/.t5-$name-$try.ready"
        rm -f "$sample_ready"
        "$TOOLS/sampler" --out "$RESULTS/samples/t5-$name-$try.jsonl" --mode foreground --ready "$sample_ready" \
            >"$RESULTS/samples/t5-$name-$try.verdict" 2>&1 &
        local sampler_pid=$! i=0
        while [[ ! -e "$sample_ready" ]] && ((i < 500)); do sleep 0.01; i=$((i + 1)); done
        if [[ ! -e "$sample_ready" ]]; then
            kill "$sampler_pid" 2>/dev/null
            die "the sampler didn't start, see $RESULTS/samples/t5-$name-$try.verdict"
        fi
        inj_file="$RESULTS/samples/t5-$name-$try.inject.json"
        "$TOOLS/hid-inject" "$event" --when-log "$BRIDGE_LOG" --pattern "$(trigger_for "$point")" \
            --timeout-ms 150000 --out "$inj_file" >/dev/null 2>>"$LOG" &
        inj_pid=$!
        since=$(($(now_ms) - 1000))
        case "$point" in
            field-restore|between-escapes) near_expiry_edit "$rowid" "$text" ;;
            *)
                ui edit "$rowid" "$text"
                [[ "$point" != before-field ]] && COMMIT_EDITS=$((COMMIT_EDITS + 1)) ;;
        esac
        wait "$inj_pid"
        sleep 1.5
        kill -TERM "$sampler_pid" 2>/dev/null
        wait "$sampler_pid"
        sampler_rc=$?
        # The sampler's pass, fail and rerun are about the end state, which a takeover changes, so judge reads the
        # samples instead. An invalid sample can miss a hide or a front-app change, so that try runs again.
        if ((sampler_rc != 0 && sampler_rc != 1 && sampler_rc != 3)); then
            msg "   the sample is invalid: $(sed -n 's/^verdict [a-z]* //p' "$RESULTS/samples/t5-$name-$try.verdict")"
            cleanup_case
            continue
        fi
        inj="$(jget "$(tail -n 1 "$inj_file" 2>/dev/null)" wall_ms)"
        if [[ -z "$inj" ]]; then
            msg "   the trigger didn't come: $UI_LINE"
            cleanup_case
            continue
        fi
        if ! landed "$point" "$inj" "$since"; then
            msg "   the injection at $inj didn't land at $point: $UI_LINE"
            cleanup_case
            continue
        fi
        judge "$name" "$inj" "$since" "$RESULTS/samples/t5-$name-$try.jsonl" "$point" "$event"
        cleanup_case
        return
    done
    UNLANDED="$UNLANDED $name"
    echo "case rerun t5-$name 5 didn't land with a valid sample in 3 tries" >>"$OUTCOMES"
}

# judge <case> <inj ms> <since ms> <sample file> <point> <event>: checks the result line, the markers and the sample
# after the injection, and the field.
judge() {
    local name="$1" inj="$2" s="$3" sample="$4" point="$5" event="$6" ret late seen check_front=1 problems=""
    ret="$(first_marker "$s" key return)"
    late="$(markers_since $((inj + GRACE_MS + 1)) | awk '$2 == "key" || $2 == "hide" || $2 == "focus-restore" { print }' | head -n 3)"
    if [[ -n "$late" ]]; then problems="$problems; bridge acted after the input: $(echo "$late" | tr '\n' ' ')"; fi
    # After the hide, macOS itself may bring another app forward, so the sample can't judge that point.
    if [[ "$point" != before-focus-restore ]]; then
        [[ "$event" == app-switch ]] && check_front=0
        seen="$(sampled_effects "$sample" $((inj + SAMPLE_GRACE_MS)) "$check_front" | head -n 3)"
        if [[ -n "$seen" ]]; then problems="$problems; the sampler saw: $(echo "$seen" | tr '\n' ' ')"; fi
    fi
    if [[ -z "$ret" ]] || ((inj < ret)); then
        [[ "$UI_CODE" == "aborted: user took over" ]] || problems="$problems; before Return the result is $UI_LINE"
    else
        [[ "$UI_LINE" == *"user took over"* && "$UI_CODE" != aborted* ]] || problems="$problems; after Return the result is $UI_LINE"
    fi
    tell "Result: $UI_LINE"
    if ! yes_no "Field rule: if the field still held exactly the test's new text, it now shows its earlier text. If the injected x changed it, it was left alone and the result says agent text may still be in the field. Does Messages match?"; then
        problems="$problems; field rule not met"
    fi
    if [[ -z "$problems" ]]; then
        echo "case pass t5-$name 5 $UI_LINE" >>"$OUTCOMES"
        msg "   case $name: pass"
    else
        FAILED="$FAILED $name"
        echo "case fail t5-$name 5 ${problems#; }" >>"$OUTCOMES"
        msg "   case $name: fail ${problems#; }"
    fi
}

for point in before-field before-hide before-focus-restore; do
    for event in $EVENTS; do run_case "$point" "$event"; done
done

if [[ -n "$FAILED" ]]; then
    msg "skipping the timed edits, because a case already failed"
else
    prepare_pool 12 75
    for point in field-restore between-escapes; do
        for event in $EVENTS; do run_case "$point" "$event"; done
    done
fi

if ! have_markers; then
    cap rerun foreground-mode 5 "no release-test markers in bridge.log"
elif [[ -n "$FAILED" ]]; then
    cap fail foreground-mode 5 "failed:$FAILED"
elif [[ -n "$UNLANDED" ]]; then
    cap rerun foreground-mode 5 "didn't land or skipped:$UNLANDED"
else
    cap pass foreground-mode 5 "20 cases"
fi
msg "== release test 5 done"
