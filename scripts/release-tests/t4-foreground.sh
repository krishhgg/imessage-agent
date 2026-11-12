#!/bin/bash
# Release test 4: foreground edit and threaded reply (DESIGN.md "Release tests" item 4, section 4 "Foreground
# mode"). run.sh runs it only with --foreground.
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t4-foreground.sh
# The threaded-reply cases need IMSG_TEST_PEER and IMSG_TEST_CONSENT=1: a person who agreed to send you messages
# and get threaded replies and tapbacks. Your own chat has no incoming messages to reply to.
#
# Checks: Return within 3 s of Messages coming forward (the sampler's first sample with Messages in front against
# the `key return` marker in bridge.log, with return_timing in lib.sh), Messages hidden and the earlier app in front
# afterwards (sampled), the change in chat.db, and a background tapback that lands right after. A failed part turns
# that action off for this macOS version.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 4
require_foreground_mode

SELF="$IMSG_TEST_HANDLE"
ACTION_START=0

setup_front() {
    front_other_app || return 1
    tell "The action asks for approval. Click Allow once, then touch nothing until Messages hides again."
}
setup_hidden() { front_other_app; }

# background_heart <rowid>: a hidden Heart add and remove right after a foreground action.
background_heart() {
    HEART_ROWID="$1"
    act_bg_add() {
        ui react "$HEART_ROWID" heart
        if ui_ok && has_my_reaction "$HEART_ROWID" heart; then ACTION_OK=1; fi
        ACTION_DETAIL="background heart: $UI_LINE"
    }
    run_sampled "$2-tapback" hidden setup_hidden act_bg_add
    BG_STATUS="$(sampled_status)"
    BG_DETAIL="$(sampled_detail)"
    clear_reaction "$HEART_ROWID" heart
}

# Edit.
send "$SELF" "$(test_text t4 edit target)"
EDIT_TARGET="$SEND_ROWID"
NEW_TEXT="$(test_text t4 edited)"
act_edit() {
    ACTION_START=$(($(now_ms) - 1000))
    ui edit "$EDIT_TARGET" "$NEW_TEXT"
    return_timing "$SAMPLE_FILE" "$ACTION_START"
    show_json "$EDIT_TARGET"
    if ui_ok && [[ "$TIMING_OK" == 1 && "$(msg_get edited)" == true && "$(msg_get text)" == "$NEW_TEXT" ]]; then
        ACTION_OK=1
    fi
    ACTION_DETAIL="edit: $UI_LINE; $TIMING_DETAIL; edited in chat.db: $(msg_flag edited)"
}
if [[ -n "$EDIT_TARGET" ]]; then
    run_sampled t4-edit foreground setup_front act_edit
    EDIT_STATUS="$(sampled_status)"
    EDIT_DETAIL="$(sampled_detail)"
    if [[ "$EDIT_STATUS" == pass ]]; then
        background_heart "$EDIT_TARGET" t4-edit
        EDIT_STATUS="$BG_STATUS"
        EDIT_DETAIL="$EDIT_DETAIL; $BG_DETAIL"
    fi
    cap "$EDIT_STATUS" edit 4 "$EDIT_DETAIL"
else
    cap fail edit 4 "the target send failed: $SEND_LINE"
fi

# Threaded reply.
if ! peer_ready; then
    cap skip threaded-reply 4 "IMSG_TEST_PEER and IMSG_TEST_CONSENT=1 aren't set"
    msg "== release test 4 done"
    exit 0
fi

wait_incoming() {
    tell "Ask $IMSG_TEST_PEER to send you one message now. The test waits up to 5 minutes."
    im wait --from "$IMSG_TEST_PEER" --timeout 300 --json
    INCOMING="$(wait_message_id)"
}

wait_incoming
PARENT="$INCOMING"
REPLY_TEXT="$(test_text t4 threaded reply)"
act_reply() {
    ACTION_START=$(($(now_ms) - 1000))
    send "$IMSG_TEST_PEER" "$REPLY_TEXT" --thread
    return_timing "$SAMPLE_FILE" "$ACTION_START"
    REPLY_ROWID="$SEND_ROWID"
    local parent_seen=""
    if [[ -n "$REPLY_ROWID" ]]; then
        show_json "$REPLY_ROWID"
        parent_seen="$(msg_get reply)"
    fi
    if send_ok && [[ "$TIMING_OK" == 1 && -n "$PARENT" && "$parent_seen" == "$PARENT" ]]; then ACTION_OK=1; fi
    ACTION_DETAIL="reply: $SEND_LINE; $TIMING_DETAIL; parent in chat.db ${parent_seen:-none}, bound $PARENT"
}
REPLY_STATUS=skip
REPLY_DETAIL="no message from $IMSG_TEST_PEER arrived"
if [[ -n "$PARENT" ]]; then
    run_sampled t4-reply foreground setup_front act_reply
    REPLY_STATUS="$(sampled_status)"
    REPLY_DETAIL="$(sampled_detail)"
    if [[ "$REPLY_STATUS" == pass ]]; then
        background_heart "$REPLY_ROWID" t4-reply
        REPLY_STATUS="$BG_STATUS"
        REPLY_DETAIL="$REPLY_DETAIL; $BG_DETAIL"
    fi
fi

# A new incoming message after approval: aborted: parent changed, and no reply row.
CHANGED_STATUS=skip
CHANGED_DETAIL="no message from $IMSG_TEST_PEER arrived"
wait_incoming
if [[ -n "$INCOMING" ]] && front_other_app; then
    out="$RESULTS/.t4-parent-changed.json"
    wait_for_send_spacing
    tell "When the dialog shows, don't click yet."
    "$IMSG" send "$IMSG_TEST_PEER" "$(test_text t4 parent changed)" --thread --json >"$out" 2>>"$LOG" &
    send_pid=$!
    tell "Ask $IMSG_TEST_PEER to send one more message now."
    im wait --from "$IMSG_TEST_PEER" --timeout 110 --json
    NEWER="$(wait_message_id)"
    tell "Now click Allow once."
    wait "$send_pid"
    date +%s >"$RESULTS/.last-send"
    IM_JSON="$(grep '^{' "$out" | tail -n 1)"
    if jget "$IM_JSON" early.code >/dev/null; then line="$(result_line "$IM_JSON" early)"; else line="$(result_line "$IM_JSON" parts.0.result)"; fi
    if [[ -z "$NEWER" ]]; then
        CHANGED_STATUS=skip
        CHANGED_DETAIL="the second message didn't arrive before approval"
    else
        # A failed or empty read is a rerun, never a pass (parent_changed_check in lib.sh).
        parent_changed_check "$IMSG_TEST_PEER" "$line"
        CHANGED_STATUS="$CHECK_STATUS"
        CHANGED_DETAIL="$CHECK_DETAIL"
    fi
fi
msg "   parent changed: $CHANGED_STATUS $CHANGED_DETAIL"

if [[ "$REPLY_STATUS" == fail || "$CHANGED_STATUS" == fail ]]; then
    cap fail threaded-reply 4 "reply: $REPLY_DETAIL; parent changed: $CHANGED_DETAIL"
elif [[ "$REPLY_STATUS" == pass && "$CHANGED_STATUS" == pass ]]; then
    cap pass threaded-reply 4 "reply and parent changed"
else
    cap "$([[ "$REPLY_STATUS" == skip || "$CHANGED_STATUS" == skip ]] && echo skip || echo rerun)" threaded-reply 4 \
        "reply: $REPLY_DETAIL; parent changed: $CHANGED_DETAIL"
fi
msg "== release test 4 done"
