#!/bin/bash
# Release test 8: files and groups, sampled (DESIGN.md "Release tests" item 8).
#
# Usage: IMSG_TEST_HANDLE=<your Apple ID> t8-files-groups.sh   (run.sh runs it for you)
#
# Cases:
#   image send       IMSG_TEST_HEIC=<path to a HEIC photo of at least 2 MB>, sent to your own chat. A staged copy
#                    must show up in ~/Pictures/iMessage Agent during the send, the row must reach transfer_state 5
#                    and get a delivery date, and the bridge must then delete the staged copy.
#   att conversion   IMSG_TEST_PEER and IMSG_TEST_CONSENT=1. The person sends you a HEIC photo. `imessage att` must
#                    return a JPEG no larger than 1600 px on its long side, which you then open in Preview.
#   group send       IMSG_TEST_GROUP (a chat number from `imessage chats`) and IMSG_TEST_CONSENT=1, which says
#                    everyone in the group agreed to get two test messages. A text send and a file send.
# A sampled send that shows Messages or changes the front app blocks the tag. Any other failure turns off that part.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
rt_init 8

SELF="$IMSG_TEST_HANDLE"
NOTE_FILE="$RESULTS/files/t8-group-note.txt"
echo "imessage-agent release test group file $(date +%Y%m%d-%H%M%S)" >"$NOTE_FILE"

setup_hidden() { front_other_app; }

# Gate status from the sample alone: did Messages stay hidden and the front app stay put.
sample_gate_status() {
    case "$SAMPLE_STATUS" in
        pass) echo pass ;;
        fail) echo fail ;;
        skip) echo skip ;;
        *) echo rerun ;;
    esac
}

# wait_transfer <attachment message rowid> <seconds>: true once the attachment reaches transfer_state 5.
wait_transfer() {
    local rowid="$1" limit="$2" i=0
    while ((i < limit)); do
        show_json "$rowid"
        [[ "$(msg_get att.0.state)" == 5 ]] && return 0
        sleep 5
        i=$((i + 5))
    done
    return 1
}

# Files in the staging folder, one path per line, sorted.
staged_files() {
    [[ -d "$STAGING_DIR" ]] || return 0
    find "$STAGING_DIR" -type f 2>/dev/null | LC_ALL=C sort
}

# Lines of file $2 that aren't in file $1. Both are sorted.
new_lines() { LC_ALL=C comm -13 "$1" "$2"; }

# watch_staging <out file>: lists the staging folder every 0.2 s into the file, for at most 15 minutes, until
# stop_watch. Sets WATCH_PID.
WATCH_PID=""
watch_staging() {
    local out="$1"
    stop_watch
    : >"$out"
    (for ((n = 0; n < 4500; n++)); do staged_files >>"$out"; sleep 0.2; done) &
    WATCH_PID=$!
}
stop_watch() {
    if [[ -n "$WATCH_PID" ]]; then
        kill "$WATCH_PID" 2>/dev/null
        wait "$WATCH_PID" 2>/dev/null
        WATCH_PID=""
    fi
}
trap stop_watch EXIT

# wait_delivered <rowid> <seconds>: true once the message has a delivery date.
wait_delivered() {
    local rowid="$1" limit="$2" i=0 ns
    while ((i < limit)); do
        show_json "$rowid"
        ns="$(msg_get delivered)"
        [[ -n "$ns" && "$ns" != 0 ]] && return 0
        sleep 5
        i=$((i + 5))
    done
    return 1
}

# a. Image send.
HEIC="${IMSG_TEST_HEIC:-}"
if [[ -z "$HEIC" ]]; then
    cap skip image-send 8 "IMSG_TEST_HEIC isn't set"
    gate skip image-send 8 "IMSG_TEST_HEIC isn't set"
elif [[ ! -f "$HEIC" ]] || ! [[ "$(echo "$HEIC" | tr '[:upper:]' '[:lower:]')" == *.heic ]] \
    || (($(stat -f %z "$HEIC") < 2000000)); then
    cap skip image-send 8 "IMSG_TEST_HEIC must be a .heic file of at least 2 MB"
    gate skip image-send 8 "IMSG_TEST_HEIC must be a .heic file of at least 2 MB"
else
    STAGED_BEFORE="$RESULTS/.t8-staged-before"
    STAGED_SEEN="$RESULTS/.t8-staged-seen"
    STAGED_NEW="$RESULTS/.t8-staged-new"
    act_image() {
        staged_files >"$STAGED_BEFORE"
        watch_staging "$STAGED_SEEN.raw"
        send "$SELF" --file "$HEIC"
        if send_ok && [[ -n "$SEND_FILE_ROWID" ]]; then ACTION_OK=1; fi
        ACTION_DETAIL="image send: $SEND_LINE"
    }
    run_sampled t8-image hidden setup_hidden act_image
    IMAGE_GATE="$(sample_gate_status)"
    IMAGE_STATUS="$(sampled_status)"
    IMAGE_DETAIL="$(sampled_detail)"
    if [[ "$IMAGE_STATUS" == pass ]]; then
        if ! wait_transfer "$SEND_FILE_ROWID" 300; then
            IMAGE_STATUS=fail
            IMAGE_DETAIL="$IMAGE_DETAIL; transfer_state $(msg_get att.0.state || echo unknown) after 300 s"
        elif ! wait_delivered "$SEND_FILE_ROWID" 120; then
            IMAGE_STATUS=fail
            IMAGE_DETAIL="$IMAGE_DETAIL; transfer_state 5 but no delivery date after 120 s more"
        else
            # The bridge deletes the copy at transfer_state 5. Give it up to 2 minutes.
            i=0
            while ((i < 120)); do
                staged_files | new_lines "$STAGED_BEFORE" /dev/stdin >"$STAGED_NEW"
                [[ -s "$STAGED_NEW" ]] || break
                sleep 5
                i=$((i + 5))
            done
            stop_watch
            LC_ALL=C sort -u "$STAGED_SEEN.raw" | new_lines "$STAGED_BEFORE" /dev/stdin >"$STAGED_SEEN"
            if [[ -s "$STAGED_NEW" ]]; then
                IMAGE_STATUS=fail
                IMAGE_DETAIL="$IMAGE_DETAIL; the staged copy is still in $STAGING_DIR after 120 s"
            elif [[ ! -s "$STAGED_SEEN" ]]; then
                IMAGE_STATUS=rerun
                IMAGE_DETAIL="$IMAGE_DETAIL; delivered and transfer_state 5, but no staged copy showed up in $STAGING_DIR"
            else
                IMAGE_DETAIL="$IMAGE_DETAIL; staged in $STAGING_DIR, delivered, transfer_state 5, staged copy deleted"
            fi
        fi
    fi
    stop_watch
    gate "$IMAGE_GATE" image-send 8 "$IMAGE_DETAIL"
    cap "$IMAGE_STATUS" image-send 8 "$IMAGE_DETAIL"
fi

# b. att conversion of a HEIC from a consenting sender.
if peer_ready; then
    tell "Ask $IMSG_TEST_PEER to send you one HEIC photo from an iPhone now. The test waits up to 5 minutes."
    im wait --from "$IMSG_TEST_PEER" --timeout 300 --json
    INCOMING="$(wait_message_id)"
    ATT_ID=""
    if [[ -n "$INCOMING" ]]; then
        show_json "$INCOMING"
        if [[ "$(msg_get att.0.uti)" == public.heic ]] \
            || [[ "$(msg_get att.0.name | tr '[:upper:]' '[:lower:]')" == *.heic ]]; then
            ATT_ID="$(msg_get att.0.id)"
        fi
    fi
    if [[ -z "$ATT_ID" ]]; then
        cap skip attachment-conversion 8 "no HEIC photo from $IMSG_TEST_PEER arrived"
    else
        wait_transfer "$INCOMING" 120 || true
        act_att() {
            im att "$ATT_ID" --json
            ATT_PATH="$(jget "$IM_JSON" path)"
            ATT_CONVERTED="$(jget "$IM_JSON" converted)"
            local format="" w=0 h=0
            if [[ -n "$ATT_PATH" && -f "$ATT_PATH" ]]; then
                format="$(sips -g format "$ATT_PATH" 2>/dev/null | awk '/format:/ { print $2 }')"
                w="$(sips -g pixelWidth "$ATT_PATH" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
                h="$(sips -g pixelHeight "$ATT_PATH" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
            fi
            if [[ "$ATT_CONVERTED" == true && "$format" == jpeg ]] && ((${w:-0} > 0 && ${w:-0} <= 1600 && ${h:-0} <= 1600)); then
                ACTION_OK=1
            fi
            ACTION_DETAIL="att $ATT_ID: converted ${ATT_CONVERTED:-unknown}, ${format:-no file} ${w:-0}x${h:-0}$( [[ -z "$ATT_PATH" ]] && echo ", $(result_line "$IM_JSON" result)")"
        }
        run_sampled t8-att hidden setup_hidden act_att
        ATT_STATUS="$(sampled_status)"
        ATT_DETAIL="$(sampled_detail)"
        if [[ "$ATT_STATUS" == pass ]] \
            && ! yes_no "The sample has ended. In Finder, choose Go, Go to Folder, paste $ATT_PATH and double-click the file. Does it open in Preview?"; then
            ATT_STATUS=fail
            ATT_DETAIL="$ATT_DETAIL; didn't open in Preview"
        fi
        cap "$ATT_STATUS" attachment-conversion 8 "$ATT_DETAIL"
    fi
else
    cap skip attachment-conversion 8 "IMSG_TEST_PEER and IMSG_TEST_CONSENT=1 aren't set"
fi

# c. Group text and file sends.
if group_ready; then
    act_group_text() {
        send "$IMSG_TEST_GROUP" "$(test_text t8 group text)"
        if send_ok; then ACTION_OK=1; fi
        ACTION_DETAIL="group text: $SEND_LINE"
    }
    act_group_file() {
        send "$IMSG_TEST_GROUP" --file "$NOTE_FILE"
        if send_ok; then ACTION_OK=1; fi
        ACTION_DETAIL="group file: $SEND_LINE"
    }
    run_sampled t8-group-text hidden setup_hidden act_group_text
    G_TEXT_GATE="$(sample_gate_status)"
    G_TEXT="$(sampled_status)"
    G_TEXT_DETAIL="$(sampled_detail)"
    run_sampled t8-group-file hidden setup_hidden act_group_file
    G_FILE_GATE="$(sample_gate_status)"
    G_FILE="$(sampled_status)"
    G_FILE_DETAIL="$(sampled_detail)"
    DETAIL="text: $G_TEXT_DETAIL; file: $G_FILE_DETAIL"
    if [[ "$G_TEXT_GATE" == fail || "$G_FILE_GATE" == fail ]]; then
        gate fail group-send 8 "$DETAIL"
    elif [[ "$G_TEXT_GATE" == pass && "$G_FILE_GATE" == pass ]]; then
        gate pass group-send 8 "text and file"
    else
        gate rerun group-send 8 "$DETAIL"
    fi
    if [[ "$G_TEXT" == fail || "$G_FILE" == fail ]]; then
        cap fail group-send 8 "$DETAIL"
    elif [[ "$G_TEXT" == pass && "$G_FILE" == pass ]]; then
        cap pass group-send 8 "text and file"
    else
        cap rerun group-send 8 "$DETAIL"
    fi
else
    cap skip group-send 8 "IMSG_TEST_GROUP and IMSG_TEST_CONSENT=1 aren't set"
    gate skip group-send 8 "IMSG_TEST_GROUP and IMSG_TEST_CONSENT=1 aren't set"
fi

msg "== release test 8 done"
