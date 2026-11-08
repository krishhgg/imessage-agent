#!/bin/bash
# Builds the synthetic chat.db fixture, verifies it and checks that a second run gives the same bytes.
# Usage: Tests/Fixtures/build.sh [--seed N]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$here/make-fixture"
seed_args=("$@")

swift build -c release --package-path "$pkg"
bin="$(swift build -c release --package-path "$pkg" --show-bin-path)"

"$bin/make-fixture" --out "$here" ${seed_args[@]+"${seed_args[@]}"}
"$bin/verify-fixture" --fixture "$here"

echo "sqlite3 sanity queries:"
q() { /usr/bin/sqlite3 -readonly "$here/chat.db" "$1"; }
echo "  integrity: $(q 'PRAGMA integrity_check')"
echo "  tables, indexes, triggers: $(q "SELECT group_concat(n, ', ') FROM (SELECT type || ' ' || COUNT(*) AS n FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' GROUP BY type ORDER BY type)")"
echo "  messages, text NULL with attributedBody: $(q 'SELECT COUNT(*) || ", " || SUM(text IS NULL AND attributedBody IS NOT NULL) FROM message')"
echo "  typedstream headers: $(q "SELECT COUNT(*) FROM message WHERE attributedBody IS NOT NULL AND substr(attributedBody, 3, 11) != CAST('streamtyped' AS BLOB)") rows without one"
echo "  messages per chat: $(q "SELECT group_concat(chat_id || '=' || n, ' ') FROM (SELECT chat_id, COUNT(*) AS n FROM chat_message_join GROUP BY chat_id)")"
echo "  date range: $(q "SELECT datetime(MIN(date) / 1000000000 + 978307200, 'unixepoch') || ' to ' || datetime(MAX(date) / 1000000000 + 978307200, 'unixepoch') || ' UTC' FROM message")"
echo "  tapback types: $(q 'SELECT group_concat(t, " ") FROM (SELECT DISTINCT associated_message_type AS t FROM message WHERE associated_message_type != 0 ORDER BY t)')"
echo "  unread incoming: $(q 'SELECT COUNT(*) FROM message WHERE is_read = 0 AND is_from_me = 0 AND item_type = 0')"
echo "  orphan joins: $(q 'SELECT COUNT(*) FROM chat_message_join j LEFT JOIN message m ON m.ROWID = j.message_id WHERE m.ROWID IS NULL') chat, $(q 'SELECT COUNT(*) FROM message_attachment_join j LEFT JOIN attachment a ON a.ROWID = j.attachment_id WHERE a.ROWID IS NULL') attachment"

# Determinism: a second run into a scratch folder must match byte for byte.
check="$pkg/.build/determinism"
rm -rf "$check"
mkdir -p "$check"
"$bin/make-fixture" --out "$check" ${seed_args[@]+"${seed_args[@]}"} > /dev/null
for f in chat.db manifest.json contacts.json README.md; do
  cmp -s "$here/$f" "$check/$f" || { echo "determinism: $f differs between runs" >&2; exit 1; }
done
diff -r "$here/Attachments" "$check/Attachments" > /dev/null || { echo "determinism: Attachments differ between runs" >&2; exit 1; }
echo "determinism: second run matches byte for byte"
