#!/bin/bash
# Release test 6: full screen (DESIGN.md "Release tests" item 6).
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t6-fullscreen.sh a|b   (run.sh runs a, and b with --foreground)
#
# 6a: the approval panel shows above a full-screen app on that app's Space, and Allow once works there. The test
#     unsends a fresh message in your own chat, because unsend always asks. The gate needs a clean hidden sample,
#     a result that shows the approval went through, and your answer. Whether the unsend itself worked is test 1's
#     question, so it only goes into the detail. A failure blocks the tag.
# 6b: from a full-screen app, after a foreground edit, a threaded reply and a bridge-owned abort, that app is in
#     front on its Space, it gained no window, and Messages is hidden. Each action is sampled in foreground mode with
#     --also <the full-screen app>. The threaded reply needs IMSG_TEST_PEER and IMSG_TEST_CONSENT=1. The abort is a
#     timed edit (near_expiry_edit in lib.sh), so 6b takes about 20 minutes. A failure turns off foreground mode.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
PART="${1:-}"
[[ "$PART" == a || "$PART" == b ]] || die "usage: t6-fullscreen.sh a|b"
rt_init 6

SELF="$IMSG_TEST_HANDLE"
FS_BUNDLE=""

# Asks for a full-screen app and records its bundle id.
choose_fullscreen_app() {
    ask "Put an app other than Messages and Finder in full screen (Control-Command-F), stay on its Space and click in its window." || return 1
    FS_BUNDLE="$(front_bundle)"
    if [[ -z "$FS_BUNDLE" || "$FS_BUNDLE" == "$MESSAGES_BUNDLE" || "$FS_BUNDLE" == com.apple.finder ]]; then
        tell "The front app is ${FS_BUNDLE:-unknown}. It must be another app in full screen."
        FS_BUNDLE=""
        return 1
    fi
    msg "   full-screen app: $FS_BUNDLE"
}

# Puts the maintainer back on the full-screen app before each sampled case.
on_fullscreen_app() {
    ask "Go to the full-screen app's Space and click in its window. After you press Return, touch nothing except an iMessage Agent dialog until this case finishes." || return 1
    if [[ "$(front_bundle)" != "$FS_BUNDLE" ]]; then
        tell "The front app is $(front_bundle), not $FS_BUNDLE."
        return 1
    fi
}

back_on_space() {
    yes_no "Are you on the full-screen app's Space, with that app in front and Messages out of sight?"
}

# 6a.
UNSEND_TARGET=""
setup_6a() {
    on_fullscreen_app || return 1
    send "$SELF" "$(test_text t6a unsend target)"
    send_ok && [[ -n "$SEND_ROWID" ]] || { tell "The send failed: $SEND_LINE"; return 1; }
    UNSEND_TARGET="$SEND_ROWID"
    tell "The unsend asks for approval. Look for the panel on this Space and click Allow once there."
}
# The approval went through unless the result is a denial, a wait for approval, a timeout or nothing.
approval_passed() {
    case "$UI_CODE" in
        ""|"no result"|denied*|pending*|timeout*) return 1 ;;
        *) [[ "$UI_LINE" != *"became visible"* ]] ;;
    esac
}
act_6a() {
    ui unsend "$UNSEND_TARGET"
    show_json "$UNSEND_TARGET"
    if approval_passed; then ACTION_OK=1; fi
    ACTION_DETAIL="unsend: $UI_LINE; unsent in chat.db: $(msg_flag unsent)"
}
if [[ "$PART" == a ]]; then
    choose_fullscreen_app || { gate skip fullscreen-panel 6 "no full-screen app"; exit 0; }
    run_sampled t6a-panel hidden setup_6a act_6a
    STATUS="$(sampled_status)"
    DETAIL="$(sampled_detail)"
    if [[ "$STATUS" == pass ]] \
        && ! yes_no "Did the approval panel show on top of the full-screen app without leaving its Space, and did Allow once work there?"; then
        STATUS=fail
        DETAIL="$DETAIL; the panel didn't show above the full-screen app"
    fi
    gate "$STATUS" fullscreen-panel 6 "$FS_BUNDLE: $DETAIL"
    msg "== release test 6a done"
    exit 0
fi

# 6b.
require_foreground_mode
choose_fullscreen_app || {
    cap skip foreground-mode 6 "no full-screen app"
    cap skip edit 6 "no full-screen app"
    cap skip threaded-reply 6 "no full-screen app"
    exit 0
}
setup_fg() {
    on_fullscreen_app || return 1
    tell "The action asks for approval. Click Allow once, then touch nothing until Messages hides again."
}

# finish_case <status var> <detail var>: asks about the Space after a sampled pass.
finish_case() {
    local status detail
    status="$(sampled_status)"
    detail="$(sampled_detail)"
    if [[ "$status" == pass ]] && ! back_on_space; then
        status=fail
        detail="$detail; not back on the full-screen Space"
    fi
    printf -v "$1" '%s' "$status"
    printf -v "$2" '%s' "$detail"
}

# Messages for the abort go first, so their edit windows close after the edit and the reply.
prepare_pool 3 75

# Edit.
EDIT_STATUS=fail
EDIT_DETAIL="the target send failed"
send "$SELF" "$(test_text t6b edit target)"
EDIT_TARGET="$SEND_ROWID"
NEW_TEXT="$(test_text t6b edited)"
act_edit() {
    ui edit "$EDIT_TARGET" "$NEW_TEXT"
    show_json "$EDIT_TARGET"
    if ui_ok && [[ "$(msg_get edited)" == true && "$(msg_get text)" == "$NEW_TEXT" ]]; then ACTION_OK=1; fi
    ACTION_DETAIL="edit: $UI_LINE; edited in chat.db: $(msg_flag edited)"
}
if [[ -n "$EDIT_TARGET" ]]; then
    run_sampled t6b-edit foreground setup_fg act_edit --also "$FS_BUNDLE"
    finish_case EDIT_STATUS EDIT_DETAIL
fi
cap "$EDIT_STATUS" edit 6 "$FS_BUNDLE: $EDIT_DETAIL"

# Threaded reply.
REPLY_STATUS=skip
REPLY_DETAIL="IMSG_TEST_PEER and IMSG_TEST_CONSENT=1 aren't set"
if peer_ready; then
    tell "Ask $IMSG_TEST_PEER to send you one message now. The test waits up to 5 minutes."
    im wait --from "$IMSG_TEST_PEER" --timeout 300 --json
    PARENT="$(wait_message_id)"
    REPLY_DETAIL="no message from $IMSG_TEST_PEER arrived"
    act_reply() {
        send "$IMSG_TEST_PEER" "$(test_text t6b threaded reply)" --thread
        local parent_seen=""
        if [[ -n "$SEND_ROWID" ]]; then
            show_json "$SEND_ROWID"
            parent_seen="$(msg_get reply)"
        fi
        if send_ok && [[ "$parent_seen" == "$PARENT" ]]; then ACTION_OK=1; fi
        ACTION_DETAIL="reply: $SEND_LINE; parent in chat.db ${parent_seen:-none}, bound $PARENT"
    }
    if [[ -n "$PARENT" ]]; then
        run_sampled t6b-reply foreground setup_fg act_reply --also "$FS_BUNDLE"
        finish_case REPLY_STATUS REPLY_DETAIL
    fi
fi
cap "$REPLY_STATUS" threaded-reply 6 "$FS_BUNDLE: $REPLY_DETAIL"

# Bridge-owned abort: a timed edit whose window closes after Messages comes forward.
ABORT_ROWID=""
setup_abort() {
    ABORT_ROWID="$(pool_next)"
    if [[ -z "$ABORT_ROWID" ]]; then
        tell "No timed-edit message is left."
        return 1
    fi
    tell "Next is the timed edit. Stay on or return to the full-screen app when the 20 s warning sounds."
    near_expiry_wait "$ABORT_ROWID" || return 1
    if [[ "$(front_bundle)" != "$FS_BUNDLE" ]]; then
        tell "The front app is $(front_bundle), not $FS_BUNDLE."
        return 1
    fi
}
act_abort() {
    near_expiry_edit "$ABORT_ROWID" "$(test_text t6b timed edit)"
    # A failed show leaves SHOW_JSON empty, which fails the action instead of reading as "not edited".
    show_json "$ABORT_ROWID"
    case "$NE_RESULT" in
        cleanup)
            if [[ "$UI_CODE" == expired && -n "$SHOW_JSON" && "$(msg_get edited)" != true ]]; then ACTION_OK=1; fi ;;
        *) ACTION_RERUN=1 ;;
    esac
    ACTION_DETAIL="timed edit $NE_RESULT: $UI_LINE; edited in chat.db: $(msg_flag edited)"
}
run_sampled t6b-abort foreground setup_abort act_abort --also "$FS_BUNDLE"
finish_case ABORT_STATUS ABORT_DETAIL

SUMMARY="edit $EDIT_STATUS; reply $REPLY_STATUS; abort $ABORT_STATUS ($ABORT_DETAIL)"
if [[ "$EDIT_STATUS" == fail || "$REPLY_STATUS" == fail || "$ABORT_STATUS" == fail ]]; then
    cap fail foreground-mode 6 "$FS_BUNDLE: $SUMMARY"
elif [[ "$EDIT_STATUS" == pass && "$ABORT_STATUS" == pass ]] && [[ "$REPLY_STATUS" == pass || "$REPLY_STATUS" == skip ]]; then
    cap pass foreground-mode 6 "$FS_BUNDLE: $SUMMARY"
else
    cap rerun foreground-mode 6 "$FS_BUNDLE: $SUMMARY"
fi
msg "== release test 6b done"
