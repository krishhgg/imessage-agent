#!/bin/bash
# S3 confirmation from the bridge: waits for its Accessibility grant, sends one test message
# to your own Apple ID (IMSG_TEST_HANDLE), then adds and removes a heart through the bridge's own AX access.
# Reads only rows after the snapshot that contain the test token or point at that message.
HERE="$(cd "$(dirname "$0")" && pwd)"
DB="file:$HOME/Library/Messages/chat.db?mode=ro"
ME="${IMSG_TEST_HANDLE:?set IMSG_TEST_HANDLE to your own Apple ID}"; TOK="s3-b1"
ts() { date +%H:%M:%S; }
q() { sqlite3 -readonly "$DB" "$1"; }
for i in $(seq 1 3300); do
  case "$("$HERE/spike" ax)" in *true*) echo "$(ts) ax_trusted=true"; break;; esac
  sleep 2
done
case "$("$HERE/spike" ax)" in *true*) ;; *) echo "$(ts) timed out waiting for Accessibility"; exit 1;; esac
SNAP=$(q "select max(ROWID) from message")
echo "$(ts) front before: $(lsappinfo info -only name "$(lsappinfo front)" | cut -d= -f2)"
echo "$(ts) send: $("$HERE/spike" "$(printf 'send\t%s\tS3 bridge test %s' "$ME" "$TOK")")"
sleep 3
GUID=$(q "select guid from message where ROWID>$SNAP and is_from_me=1 and instr(attributedBody, CAST('$TOK' AS BLOB))>0 limit 1")
echo "$(ts) sent row: $(q "select ROWID, is_sent, error from message where guid='$GUID'")"
for step in add remove; do
  echo "$(ts) react $step: $("$HERE/spike" "$(printf 'react\t%s\tHeart' "$TOK")")"
  sleep 2
done
echo "$(ts) tapback rows (type, sent, error):"
q "select ROWID, associated_message_type, is_sent, error from message where ROWID>$SNAP and associated_message_guid like '%$GUID'"
echo "$(ts) front after: $(lsappinfo info -only name "$(lsappinfo front)" | cut -d= -f2)"
