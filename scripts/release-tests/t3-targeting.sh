#!/bin/bash
# Release test 3: targeting (DESIGN.md "Release tests" item 3, section 4 "Targeting").
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t3-targeting.sh   (run.sh runs it for you)
#
# Cases in your own chat run on their own. Cases with other people need IMSG_TEST_CONSENT=1, which says everyone in
# those chats agreed to get test tapbacks, plus the chat numbers `imessage chats` prints:
#   IMSG_TEST_TWIN_A, IMSG_TEST_TWIN_B   two 1:1 chats whose contacts share a display name
#   IMSG_TEST_OLD_CHAT                   a 1:1 chat whose newest message is from an earlier day
#   IMSG_TEST_GROUP                      a group chat
#   IMSG_TEST_SIG_A, IMSG_TEST_SIG_B     two 1:1 chats you can give identical newest messages
#   IMSG_TEST_MERGED                     a contact with both an iMessage and an SMS chat
# The same-minute case needs two days. The first run sends the text and saves the minute. A run on a later day at
# that minute finishes it.
#
# Targeting is recorded only when every case ran and passed. A failure turns off every UI action.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 3

SELF="$IMSG_TEST_HANDLE"
STATE_DIR="$RT_DIR/results/state"
mkdir -p "$STATE_DIR"
FAILED=""
SKIPPED=""

result() {
    local name="$1" status="$2"
    shift 2
    msg "   case $name: $status $*"
    echo "case $status t3-$name 3 $*" >>"$OUTCOMES"
    case "$status" in
        fail) FAILED="$FAILED $name" ;;
        skip|rerun) SKIPPED="$SKIPPED $name" ;;
    esac
}

# newest_rowid <who>: the id of the chat's newest message. Prints nothing and returns 1 when the read fails.
newest_rowid() {
    local lines
    lines="$(read_messages "$1" 5)" || return 1
    jget "$(printf '%s\n' "$lines" | tail -n 1)" id
}

switch_away() {
    ask "Open Messages, click a chat that isn't part of this case, then hide Messages with Command-H." || return 1
    front_other_app
}

# expect_ok <case> <rowid>: Heart must land on rowid. Removes it afterwards.
expect_ok() {
    local name="$1" rowid="$2"
    clear_reaction "$rowid" heart
    ui react "$rowid" heart
    if ui_ok && has_my_reaction "$rowid" heart; then
        result "$name" pass "$UI_LINE"
    else
        result "$name" fail "react heart on $rowid: $UI_LINE"
    fi
    clear_reaction "$rowid" heart
}

# expect_no_press <case> <rowid> <code>: the result must be <code>, with no reaction and no read-state change
# (no_press_check in lib.sh). A lookup that failed makes the case a rerun.
expect_no_press() {
    local name="$1" rowid="$2" want="$3"
    if [[ -z "$rowid" ]]; then
        result "$name" rerun "looking up the message to press on failed"
        return
    fi
    no_press_check "$rowid" "$want"
    result "$name" "$CHECK_STATUS" "$CHECK_DETAIL"
    clear_reaction "$rowid" heart
}

# row_minute <rowid>: the local HH:MM of the message's chat.db date, the minute Messages shows.
row_minute() {
    local ns
    show_json "$1"
    ns="$(msg_get ns)" || return 1
    date -r "$(apple_ns_to_epoch "$ns")" +%H:%M
}

# a. Same text in the same minute on different days: ambiguous.
same_minute() {
    local state="$STATE_DIR/t3-same-minute.txt" day hm text today target now got
    today="$(date +%Y-%m-%d)"
    if [[ -f "$state" ]]; then
        read -r day hm text <"$state"
    else
        day=""
    fi
    if [[ -z "$day" || "$day" == "$today" ]]; then
        text="imessage-agent release test t3 same minute $(date +%Y%m%d%H%M%S)"
        send "$SELF" "$text"
        if send_ok && [[ -n "$SEND_ROWID" ]] && hm="$(row_minute "$SEND_ROWID")"; then
            echo "$today $hm $text" >"$state"
            result same-minute skip "sent today at $hm. Run t3 again on a later day at that minute"
        else
            result same-minute skip "the first send failed: $SEND_LINE"
        fi
        return
    fi
    target="$(date -j -f '%Y-%m-%d %H:%M:%S' "$today $hm:05" +%s)"
    now="$(date +%s)"
    if ((target < now - 40 || target - now > 3600)); then
        result same-minute skip "run t3 again within the hour before $hm"
        return
    fi
    if ((target > now)); then
        tell "Waiting $((target - now)) s for $hm to send the same text as on $day."
        sleep $((target - now))
    fi
    send "$SELF" "$text" --again
    if ! send_ok || [[ -z "$SEND_ROWID" ]]; then
        result same-minute fail "the second send failed: $SEND_LINE"
        return
    fi
    # A slow approval can push the row into the next minute, and then ambiguous isn't the expected result.
    got="$(row_minute "$SEND_ROWID")"
    if [[ "$got" != "$hm" ]]; then
        result same-minute rerun "the second send landed at ${got:-an unknown minute}, not $hm. Run t3 again on a later day"
        return
    fi
    expect_no_press same-minute "$SEND_ROWID" ambiguous
}

# b. Same text at different minutes: the Heart lands on the right GUID.
different_minutes() {
    local text first second
    text="imessage-agent release test t3 same text $(date +%Y%m%d%H%M%S)"
    send "$SELF" "$text"
    first="$SEND_ROWID"
    sleep $((61 - $(date +%S | sed 's/^0//')))
    send "$SELF" "$text" --again
    second="$SEND_ROWID"
    if [[ -z "$first" || -z "$second" ]]; then
        result different-minutes fail "a send failed: $SEND_LINE"
        return
    fi
    clear_reaction "$first" heart
    ui react "$first" heart
    if ui_ok && has_my_reaction "$first" heart && lacks_my_reaction "$second" heart; then
        result different-minutes pass "$UI_LINE"
    else
        result different-minutes fail "react heart on $first: $UI_LINE"
    fi
    clear_reaction "$first" heart
}

# c and d. Two chats with the same display name.
twins() {
    if ! consented "${IMSG_TEST_TWIN_A:-}" || [[ -z "${IMSG_TEST_TWIN_B:-}" ]]; then
        result twins-same-preview skip "IMSG_TEST_TWIN_A, IMSG_TEST_TWIN_B and IMSG_TEST_CONSENT=1 aren't set"
        result twins-different-preview skip "same"
        return
    fi
    local a b unread
    if ask "Have both people in chats $IMSG_TEST_TWIN_A and $IMSG_TEST_TWIN_B send you the same text in the same minute. Leave both unread." && switch_away; then
        a="$(newest_rowid "$IMSG_TEST_TWIN_A")"
        expect_no_press twins-same-preview "$a" ambiguous
    else
        result twins-same-preview skip "setup skipped"
    fi
    if ask "Have the person in chat $IMSG_TEST_TWIN_B send one more, different message. Leave both chats unread." && switch_away; then
        a="$(newest_rowid "$IMSG_TEST_TWIN_A")"
        b="$(newest_rowid "$IMSG_TEST_TWIN_B")"
        expect_ok twins-different-preview "$a"
        if ! unread="$(unread_ids)"; then
            result twins-different-preview rerun "imessage unread failed, so chat $IMSG_TEST_TWIN_B's read state is unknown"
        elif ! grep -q -x -F -- "$b" <<<"$unread"; then
            result twins-different-preview fail "chat $IMSG_TEST_TWIN_B was marked read"
        fi
    else
        result twins-different-preview skip "setup skipped"
    fi
}

# e. Row matching when the chat's newest row is from an earlier day, a tapback or an attachment.
newest_row_kinds() {
    local s0 s1 file="$RESULTS/files/t3-attachment.txt"
    if consented "${IMSG_TEST_OLD_CHAT:-}"; then
        if switch_away; then
            expect_ok newest-earlier-day "$(newest_rowid "$IMSG_TEST_OLD_CHAT")"
        else
            result newest-earlier-day skip "setup skipped"
        fi
    else
        result newest-earlier-day skip "IMSG_TEST_OLD_CHAT and IMSG_TEST_CONSENT=1 aren't set"
    fi

    send "$SELF" "$(test_text t3 tapback case first)"
    s0="$SEND_ROWID"
    send "$SELF" "$(test_text t3 tapback case second)"
    s1="$SEND_ROWID"
    ui react "$s1" heart
    if [[ -n "$s0" ]] && ui_ok && switch_away; then
        expect_ok newest-tapback "$s0"
    else
        result newest-tapback skip "setup failed: $UI_LINE"
    fi
    clear_reaction "$s1" heart

    echo "imessage-agent release test t3 attachment" >"$file"
    send "$SELF" "$(test_text t3 attachment case)"
    s0="$SEND_ROWID"
    send "$SELF" --file "$file"
    if [[ -n "$s0" ]] && send_ok && switch_away; then
        expect_ok newest-attachment "$s0"
    else
        result newest-attachment skip "setup failed: $SEND_LINE"
    fi
}

# f. A group chat: unsupported_target, no press.
group() {
    if group_ready; then
        expect_no_press group "$(newest_rowid "$IMSG_TEST_GROUP")" unsupported_target
    else
        result group skip "IMSG_TEST_GROUP and IMSG_TEST_CONSENT=1 aren't set"
    fi
}

# g. Two chats whose newest text rows are the same: ambiguous, no press.
same_signature() {
    if ! consented "${IMSG_TEST_SIG_A:-}" || [[ -z "${IMSG_TEST_SIG_B:-}" ]]; then
        result same-signature skip "IMSG_TEST_SIG_A, IMSG_TEST_SIG_B and IMSG_TEST_CONSENT=1 aren't set"
        return
    fi
    if ask "Make the newest text messages in chats $IMSG_TEST_SIG_A and $IMSG_TEST_SIG_B the same: the same senders' direction and text, newest first, for up to 5 messages. Leave both unread." && switch_away; then
        expect_no_press same-signature "$(newest_rowid "$IMSG_TEST_SIG_A")" ambiguous
    else
        result same-signature skip "setup skipped"
    fi
}

# h. A contact with merged iMessage and SMS chats passes the chat check.
merged() {
    if consented "${IMSG_TEST_MERGED:-}"; then
        if switch_away; then
            expect_ok merged "$(newest_rowid "$IMSG_TEST_MERGED")"
        else
            result merged skip "setup skipped"
        fi
    else
        result merged skip "IMSG_TEST_MERGED and IMSG_TEST_CONSENT=1 aren't set"
    fi
}

# i. A message that isn't loaded: not_loaded. j. A multipart message: unsupported_target.
old_and_multipart() {
    local lines count oldest="" multi="" m
    # The chat line counts every visible message. --after 1 lists the oldest ones, since a page holds about 12 KB.
    count="$(chat_total "$SELF")" || count=0
    if ((count >= 200)) && lines="$(read_messages "$SELF" 20 --after 1)"; then
        while IFS= read -r m; do
            if [[ -n "$m" ]] && editable_message "$m"; then
                oldest="$(jget "$m" id)"
                break
            fi
        done <<<"$lines"
    fi
    if ((count >= 200)) && [[ -n "$oldest" ]]; then
        expect_no_press not-loaded "$oldest" not_loaded
    else
        result not-loaded skip "your chat has $count messages, or none of its oldest 20 is a plain text of yours. It needs 200 so the oldest isn't loaded"
    fi
    multi="$(multipart_id "$(read_messages "$SELF" 60)")"
    if [[ -z "$multi" ]] && ask "No multipart message in your chat. From your iPhone, send yourself one photo with a caption in the same message."; then
        sleep 10
        multi="$(multipart_id "$(read_messages "$SELF" 10)")"
    fi
    if [[ -n "$multi" ]]; then
        expect_no_press multipart "$multi" unsupported_target
    else
        result multipart skip "no multipart message found"
    fi
}

same_minute
different_minutes
twins
newest_row_kinds
group
same_signature
merged
old_and_multipart

if [[ -n "$FAILED" ]]; then
    cap fail targeting 3 "failed:$FAILED"
elif [[ -n "$SKIPPED" ]]; then
    cap skip targeting 3 "not run:$SKIPPED"
else
    cap pass targeting 3 "every case passed"
fi
msg "== release test 3 done"
