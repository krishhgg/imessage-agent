#!/bin/zsh
# Builds a large synthetic copy of the fixture chat.db for ChangesScaleTests: the fixture's messages copied
# <copies> times (720 gives about 1.1 million rows), with dates spread over 2,200 days.
# Usage: make-large-chatdb.zsh [out path] [copies]
# Then: IMSTORE_LARGE_CHATDB=<out path> swift test --filter ChangesScaleTests
# It reads only Tests/Fixtures/chat.db and writes only the out path.
set -euo pipefail
src=${0:A:h}/../../Tests/Fixtures/chat.db
out=${1:-/tmp/imsg-synth/chat.db}
copies=${2:-720}
mkdir -p "${out:h}"
rm -f "$out" "$out-wal" "$out-shm"
cp "$src" "$out"
triggers=$(sqlite3 "$out" "select name from sqlite_master where type='trigger'")
for t in ${(f)triggers}; do sqlite3 "$out" "DROP TRIGGER \"$t\""; done
cols=$(sqlite3 "$out" "select group_concat(name, ', ') from pragma_table_info('message') where name not in ('ROWID','guid','date','date_read','date_delivered','date_edited','date_retracted')")
mind=$(sqlite3 "$out" "select min(date) from message")
maxd=$(sqlite3 "$out" "select max(date) from message")
span=$((maxd - mind))
# 2,200 days split into one slot per copy. Copy k sits in slot k, and the newest copy ends at the fixture's newest date.
slot=$(( 2200 * 86400 * 1000000000 / copies ))
sqlite3 "$out" "CREATE TABLE src_message AS SELECT * FROM message; CREATE TABLE src_join AS SELECT * FROM chat_message_join; DELETE FROM chat_message_join; DELETE FROM message;"
sql="BEGIN;"
for (( k = 0; k < copies; k++ )); do
  base=$(( maxd - (copies - k) * slot ))
  tf() { echo "CASE WHEN ifnull($1, 0) > 0 THEN $base + CAST(($1 - $mind) * 1.0 * $slot / $span AS INTEGER) ELSE $1 END"; }
  sql+="INSERT INTO message (ROWID, guid, date, date_read, date_delivered, date_edited, date_retracted, $cols) SELECT ROWID - 40000 + $k * 2000, guid || '-$k', $(tf date), $(tf date_read), $(tf date_delivered), $(tf date_edited), $(tf date_retracted), $cols FROM src_message;"
  sql+="INSERT INTO chat_message_join (chat_id, message_id, message_date) SELECT chat_id, message_id - 40000 + $k * 2000, $base + CAST((message_date - $mind) * 1.0 * $slot / $span AS INTEGER) FROM src_join;"
done
sql+="COMMIT; DROP TABLE src_message; DROP TABLE src_join;"
print -r -- "$sql" | sqlite3 "$out"
sqlite3 "$out" "VACUUM; select count(*), max(ROWID), min(date), max(date) from message; select count(*) from chat_message_join;"
