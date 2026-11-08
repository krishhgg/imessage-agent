#!/bin/bash
# Release test 1: actions from the bridge under its own grants, sampled (DESIGN.md "Release tests" item 1).
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t1-bridge.sh   (run.sh runs it for you)
#
# Every case sends to or presses in your own chat with IMSG_TEST_HANDLE. Cases:
#   cold text send, cold file send, cold UI action (Heart add), warm text send, Heart remove, unsend,
#   hidden chat switch, no-window quit and relaunch, Messages open on another Space, Messages full screen in its
#   own Space.
# A sampled launch or send that shows Messages or changes the front app blocks the tag. So does a hidden action that
# doesn't answer busy while Messages has a window on another Space. A failed Heart or unsend turns that action off.
# A failed chat switch turns off every UI action.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 1

SELF="$IMSG_TEST_HANDLE"
NOTE_FILE="$RESULTS/files/release-test-note.txt"
echo "imessage-agent release test file $(date +%Y%m%d-%H%M%S)" >"$NOTE_FILE"
TARGET=""

setup_cold() { wait_messages_quit && front_other_app; }
setup_warm() {
    if ! messages_running; then
        tell "Messages isn't running, so this wouldn't be a warm case."
        return 1
    fi
    front_other_app
}

act_text() {
    send "$SELF" "$(test_text t1 "$1")"
    if send_ok; then ACTION_OK=1; fi
    ACTION_DETAIL="send: $SEND_LINE"
}
act_cold_text() { act_text "cold text"; TARGET="$SEND_ROWID"; }
act_warm_text() { act_text "warm text"; }
act_file() {
    send "$SELF" --file "$NOTE_FILE"
    if send_ok; then ACTION_OK=1; fi
    ACTION_DETAIL="file send: $SEND_LINE"
}

# Heart add or remove on TARGET, checked in chat.db afterwards. A failed chat.db lookup fails the action.
act_heart_add() {
    ui react "$TARGET" heart
    if ui_ok && has_my_reaction "$TARGET" heart; then ACTION_OK=1; fi
    ACTION_DETAIL="react heart: $UI_LINE; Heart in chat.db: $REACTION_STATE"
}
act_heart_remove() {
    ui react "$TARGET" heart --remove
    if ui_ok && lacks_my_reaction "$TARGET" heart; then ACTION_OK=1; fi
    ACTION_DETAIL="react heart --remove: $UI_LINE; Heart in chat.db: $REACTION_STATE"
}

# a. Cold launch before a text send.
run_sampled t1-cold-text hidden setup_cold act_cold_text
gate "$(sampled_status)" cold-text-send 1 "$(sampled_detail)"

if [[ -z "$TARGET" ]]; then
    send "$SELF" "$(test_text t1 heart target)"
    TARGET="$SEND_ROWID"
fi
[[ -n "$TARGET" ]] || die "no message to press on. The text send didn't return a rowid"
clear_reaction "$TARGET" heart

# b. Cold launch before a file send.
run_sampled t1-cold-file hidden setup_cold act_file
gate "$(sampled_status)" cold-file-send 1 "$(sampled_detail)"

# c. Cold launch before a UI action. This is also the Heart add.
run_sampled t1-cold-ui hidden setup_cold act_heart_add
gate "$(sampled_status)" cold-ui-action 1 "$(sampled_detail)"
HEART_ADD="$(sampled_status)"
HEART_ADD_DETAIL="$(sampled_detail)"

# d. Warm text send.
run_sampled t1-warm-text hidden setup_warm act_warm_text
gate "$(sampled_status)" warm-text-send 1 "$(sampled_detail)"

# e. Heart remove.
run_sampled t1-heart-remove hidden setup_warm act_heart_remove
HEART_REMOVE="$(sampled_status)"
if [[ "$HEART_ADD" == pass && "$HEART_REMOVE" == pass ]]; then
    cap pass tapback.heart 1 "add and remove verified in chat.db"
elif [[ "$HEART_ADD" == fail || "$HEART_REMOVE" == fail ]]; then
    cap fail tapback.heart 1 "add: $HEART_ADD_DETAIL; remove: $(sampled_detail)"
else
    cap "$([[ "$HEART_ADD" == skip || "$HEART_REMOVE" == skip ]] && echo skip || echo rerun)" tapback.heart 1 "add $HEART_ADD, remove $HEART_REMOVE"
fi

# f. Unsend a fresh message. Unsend always asks.
UNSEND_TARGET=""
setup_unsend() {
    send "$SELF" "$(test_text t1 unsend target)"
    UNSEND_TARGET="$SEND_ROWID"
    [[ -n "$UNSEND_TARGET" ]] || return 1
    setup_warm || return 1
    tell "Unsend asks for approval. Click Allow once in the iMessage Agent dialog."
}
act_unsend() {
    ui unsend "$UNSEND_TARGET"
    show_json "$UNSEND_TARGET"
    if ui_ok && [[ "$(msg_get unsent)" == true ]]; then ACTION_OK=1; fi
    ACTION_DETAIL="unsend: $UI_LINE, unsent in chat.db: $(msg_flag unsent)"
}
run_sampled t1-unsend hidden setup_unsend act_unsend
cap "$(sampled_status)" unsend 1 "$(sampled_detail)"

# g. Hidden chat switch: the hidden window shows another chat, and the Heart must land in the test chat.
setup_switch() {
    clear_reaction "$TARGET" heart
    ask "Open Messages, click any chat other than the one with $SELF, then hide Messages with Command-H." || return 1
    front_other_app
}
act_switch() {
    act_heart_add
    if [[ "$ACTION_OK" == 1 && "$UI_LINE" == *"wrong chat"* ]]; then ACTION_OK=0; fi
}
run_sampled t1-chat-switch hidden setup_switch act_switch
cap "$(sampled_status)" hidden-chat-switch 1 "$(sampled_detail)"

# h. No window: Messages runs with its window closed, so the bridge quits and relaunches it hidden.
setup_no_window() {
    clear_reaction "$TARGET" heart
    ask "Open Messages, close its window with Command-W and leave Messages running." || return 1
    if ! messages_running; then
        tell "Messages isn't running."
        return 1
    fi
    front_other_app
}
# If Messages keeps the closed window in the window server's list, the first try is busy with the hide fix and presses
# nothing (BUILD-PLAN 49). Then the maintainer hides Messages and the second try must quit, relaunch and press.
NO_WINDOW_BUSY=0
act_no_window() {
    act_heart_add
    if [[ "$ACTION_OK" != 1 && "$UI_CODE" == "busy: Messages is open" && "$UI_LINE" == *"hide Messages"* ]] \
        && lacks_my_reaction "$TARGET" heart; then
        NO_WINDOW_BUSY=1
        ACTION_OK=1
        ACTION_DETAIL="closed window still listed, busy with the hide fix: $UI_LINE"
    fi
}
setup_no_window_hidden() {
    clear_reaction "$TARGET" heart
    ask "Messages kept its closed window. Switch to Messages with Command-Tab, hide it with Command-H, then click a Finder window." || return 1
    if ! messages_running; then
        tell "Messages isn't running."
        return 1
    fi
    front_other_app
}
run_sampled t1-no-window hidden setup_no_window act_no_window
NO_WINDOW_STATUS="$(sampled_status)"
NO_WINDOW_DETAIL="$(sampled_detail)"
if [[ "$NO_WINDOW_STATUS" == pass && "$NO_WINDOW_BUSY" == 1 ]]; then
    run_sampled t1-no-window-hidden hidden setup_no_window_hidden act_heart_add
    NO_WINDOW_STATUS="$(sampled_status)"
    NO_WINDOW_DETAIL="first try: $NO_WINDOW_DETAIL; after Command-H: $(sampled_detail)"
fi
gate "$NO_WINDOW_STATUS" no-window-relaunch 1 "$NO_WINDOW_DETAIL"
clear_reaction "$TARGET" heart

# i and j. Messages isn't hidden and its window is on another Space, where AX and the on-screen window list don't
# show it. A hidden action must answer busy with the hide fix, press nothing, and leave Messages running with its
# window. The same Messages pid before and after shows it wasn't quit and relaunched.
SPACE_PID=""
setup_window_elsewhere() {
    clear_reaction "$TARGET" heart
    ask "$1 Don't hide Messages. Come back to the first desktop and click a Finder window so Finder is in front. After you press Return, touch nothing until this case finishes." || return 1
    SPACE_PID="$(pgrep -x Messages)"
    if [[ -z "$SPACE_PID" ]]; then
        tell "Messages isn't running."
        return 1
    fi
    if [[ "$(front_bundle)" == "$MESSAGES_BUNDLE" ]]; then
        tell "Messages is in front."
        return 1
    fi
}
setup_other_space() {
    setup_window_elsewhere "Open Messages and move its window to another desktop: open Mission Control, add a desktop with + if there is only one, and drag the Messages window onto the other desktop."
}
setup_fullscreen_space() {
    setup_window_elsewhere "Switch to Messages and click the green button in its window, so the window goes full screen in its own Space."
}
act_busy_elsewhere() {
    local pid
    ui react "$TARGET" heart
    pid="$(pgrep -x Messages)"
    if [[ "$UI_CODE" == "busy: Messages is open" && "$UI_LINE" == *"hide Messages"* && -n "$pid" && "$pid" == "$SPACE_PID" ]] \
        && lacks_my_reaction "$TARGET" heart; then
        ACTION_OK=1
    fi
    ACTION_DETAIL="react heart: $UI_LINE; Messages pid before $SPACE_PID, after ${pid:-none}; Heart in chat.db: $REACTION_STATE"
}
# space_case <name> <setup> <gate>
space_case() {
    local status detail
    run_sampled "$1" hidden "$2" act_busy_elsewhere
    status="$(sampled_status)"
    detail="$(sampled_detail)"
    if [[ "$status" == pass ]] && ! yes_no "Switch to Messages. Is its window still open where you left it?"; then
        status=fail
        detail="$detail; the window was gone"
    fi
    gate "$status" "$3" 1 "$detail"
}
space_case t1-other-space setup_other_space other-space-busy
space_case t1-fullscreen-space setup_fullscreen_space fullscreen-space-busy
tell "Leave full screen in Messages with Control-Command-F, then hide Messages with Command-H."

msg "== release test 1 done"
