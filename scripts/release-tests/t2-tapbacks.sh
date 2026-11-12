#!/bin/bash
# Release test 2: tapback kinds, sampled (DESIGN.md "Release tests" item 2).
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t2-tapbacks.sh   (run.sh runs it for you)
#
# Optional:
#   IMSG_TEST_EMOJI=<emoji>   one emoji Messages lists as recent in its tapback menu, for the emoji case
#   IMSG_TEST_PEER=<who> and IMSG_TEST_CONSENT=1   a person who agreed to send you a message and get a Heart on it
#
# Each of like, dislike, laugh, emphasize and question, and the emoji, is added and then removed on a fresh message
# in your own chat, each step checked in chat.db. Heart also runs on a loaded message from an earlier day and on the
# chat's newest message. A failed kind turns that kind off.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 2

SELF="$IMSG_TEST_HANDLE"
TARGET=""
KIND=""

setup_hidden() {
    if messages_running && [[ "$(front_bundle)" == "$MESSAGES_BUNDLE" ]]; then
        tell "Messages is in front. Hide it with Command-H."
    fi
    front_other_app
}
act_add() {
    ui react "$TARGET" "$KIND"
    if ui_ok && has_my_reaction "$TARGET" "$KIND"; then ACTION_OK=1; fi
    ACTION_DETAIL="react $KIND: $UI_LINE"
}
act_remove() {
    ui react "$TARGET" "$KIND" --remove
    if ui_ok && lacks_my_reaction "$TARGET" "$KIND"; then ACTION_OK=1; fi
    ACTION_DETAIL="react $KIND --remove: $UI_LINE; in chat.db: $REACTION_STATE"
}

# add_remove <case name>: sampled add, then sampled remove, of KIND on TARGET. Sets AR_STATUS and AR_DETAIL.
add_remove() {
    local name="$1" add_status add_detail
    clear_reaction "$TARGET" "$KIND"
    run_sampled "$name-add" hidden setup_hidden act_add
    add_status="$(sampled_status)"
    add_detail="$(sampled_detail)"
    if [[ "$add_status" != pass ]]; then
        AR_STATUS="$add_status"
        AR_DETAIL="add: $add_detail"
        clear_reaction "$TARGET" "$KIND"
        return
    fi
    run_sampled "$name-remove" hidden setup_hidden act_remove
    AR_STATUS="$(sampled_status)"
    AR_DETAIL="add: $add_detail; remove: $(sampled_detail)"
}

send "$SELF" "$(test_text t2 tapback target)"
send_ok && [[ -n "$SEND_ROWID" ]] || die "the target send failed: $SEND_LINE"
TARGET="$SEND_ROWID"

for KIND in like dislike laugh emphasize question; do
    add_remove "t2-$KIND"
    cap "$AR_STATUS" "tapback.$KIND" 2 "$AR_DETAIL"
done

if [[ -n "${IMSG_TEST_EMOJI:-}" ]]; then
    KIND="$IMSG_TEST_EMOJI"
    add_remove t2-emoji
    cap "$AR_STATUS" tapback.emoji 2 "$KIND: $AR_DETAIL"
else
    cap skip tapback.emoji 2 "IMSG_TEST_EMOJI isn't set"
fi

# Heart on the newest loaded message from an earlier day.
KIND=heart
EARLIER=""
today="$(today_start_epoch)"
while IFS= read -r m; do
    editable_message "$m" || continue
    ns="$(jget "$m" ns)" || continue
    if (($(apple_ns_to_epoch "$ns") < today)); then EARLIER="$(jget "$m" id)"; fi
done < <(read_messages "$SELF" 60)
HEART_EARLIER=skip
HEART_EARLIER_DETAIL="no message of yours from an earlier day in the last 60 of this chat"
if [[ -n "$EARLIER" ]]; then
    TARGET="$EARLIER"
    add_remove t2-heart-earlier-day
    HEART_EARLIER="$AR_STATUS"
    HEART_EARLIER_DETAIL="$AR_DETAIL"
    if [[ "$AR_DETAIL" == *not_loaded* ]]; then
        HEART_EARLIER=skip
        HEART_EARLIER_DETAIL="message $EARLIER isn't loaded in Messages. Rerun on a day with fewer new messages in this chat"
    fi
fi

# Heart on the chat's newest message.
send "$SELF" "$(test_text t2 newest message)"
HEART_NEWEST=fail
HEART_NEWEST_DETAIL="the send failed: $SEND_LINE"
if send_ok && [[ -n "$SEND_ROWID" ]]; then
    TARGET="$SEND_ROWID"
    add_remove t2-heart-newest
    HEART_NEWEST="$AR_STATUS"
    HEART_NEWEST_DETAIL="$AR_DETAIL"
fi

if [[ "$HEART_EARLIER" == fail || "$HEART_NEWEST" == fail ]]; then
    cap fail tapback.heart 2 "earlier day: $HEART_EARLIER_DETAIL; newest: $HEART_NEWEST_DETAIL"
elif [[ "$HEART_EARLIER" == pass && "$HEART_NEWEST" == pass ]]; then
    cap pass tapback.heart 2 "earlier day and newest message"
else
    cap "$([[ "$HEART_EARLIER" == skip || "$HEART_NEWEST" == skip ]] && echo skip || echo rerun)" tapback.heart 2 \
        "earlier day: $HEART_EARLIER_DETAIL; newest: $HEART_NEWEST_DETAIL"
fi

# Heart on an incoming message from a consenting sender.
if peer_ready; then
    tell "Ask $IMSG_TEST_PEER to send you one message now. The test waits up to 5 minutes."
    im wait --from "$IMSG_TEST_PEER" --timeout 300 --json
    INCOMING="$(wait_message_id)"
    if [[ -n "$INCOMING" ]]; then
        TARGET="$INCOMING"
        add_remove t2-heart-incoming
        cap "$AR_STATUS" tapback.incoming 2 "$AR_DETAIL"
    else
        cap skip tapback.incoming 2 "no message from $IMSG_TEST_PEER arrived"
    fi
else
    cap skip tapback.incoming 2 "IMSG_TEST_PEER and IMSG_TEST_CONSENT=1 aren't set"
fi

msg "== release test 2 done"
