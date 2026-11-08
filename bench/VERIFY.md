# S5 verification

Date: 2026-11-06. This is an independent check of the fixture in `Tests/Fixtures/` and the benchmark in `bench/`. I changed no repo file except this one. I ran `run.py` with `--no-write`, so `results.md` and `bench/out/` are untouched. My helper scripts live in `/tmp/s5-verify-scripts/` and the fresh competitor clones in `/tmp/s5-verify/`. I read the clones and never executed them.

## Verdict

The fixture passes. It matches the real 26.2 schema statement for statement, and its bodies are attributedBody-only in 93% of rows and decode with NSUnarchiver. The benchmark reproduces exactly.

The comparison is not yet fair. Three of the eight tools look worse than they are, because the scripted agent asks them for far more messages than it asks ours, imsg or jimmyliu03 for the same task:

- Grok Bot built-in is reported 16.2x heavier than ours on T1 to T3. With the same limits as the other tools it is 1.4x to 2.5x.
- steve228uk is reported 17.7x heavier. With the same limits as imsg it is 4.1x.
- jeffhuber drops from 6.0x to 5.7x.

After these corrections no tool is 10x heavier than ours on T1 to T3. The real range is about 1.1x to 5.7x. Our own rows also need relabeling, and T4 needs one more call.

| Check | Result |
| --- | --- |
| 1a. Fixture schema equals research/chatdb-schema.sql | Pass |
| 1b. Most bodies are attributedBody-only | Pass |
| 1c. Blobs decode with NSUnarchiver | Pass |
| 2. run.py numbers reproduce | Pass |
| 3. Renderers match competitor source | Pass for the renderers themselves. Fail for three call scripts that use larger limits than the other tools get |
| 4. Call sequences are realistic, and ours is honest | Fail. Ours has one missing call in T4, two tasks labeled "yes" that DESIGN marks unverified, and an asymmetric chaining assumption |

## 1. Fixture

### 1a. Schema: pass

I split `research/chatdb-schema.sql` with `sqlite3.complete_statement` and compared each statement's text to every non-null `sql` in the fixture's `sqlite_master`. The script is `/tmp/s5-verify-scripts/schema_diff.py`.

- Reference: 92 statements, 24 tables, 46 indexes and 22 triggers.
- Fixture: 92 rows with SQL, 24 tables, 46 indexes and 22 triggers.
- Statements only in the reference: 0. Statements only in the fixture: 0.
- That count includes `sqlite_sequence` and `sqlite_stat1`. SQLite created both itself, and their stored SQL text is the same as the reference.
- `pragma integrity_check` is ok and `foreign_key_check` is empty. The chat.db SHA-256 matches the README (`a7457708...c14f`).

Some differences sit outside the schema text. None of them changes what the renderers read.

- `journal_mode` is `delete`. A live chat.db runs in WAL mode.
- `_SqliteDatabaseProperties` is empty. A real database has keys in it.
- `user_version` is 0.

### 1b. attributedBody-only bodies: pass

| Shape | Rows |
| --- | ---: |
| `text` NULL, `attributedBody` set | 1424 |
| Both set | 102 |
| Only `text` | 0 |
| Neither (5 group events and 3 unsends) | 8 |
| Total | 1534 |

That is 1424 of 1526 bodies (93%) with no `text`, which matches the rate reported in imsg #223.

### 1c. NSUnarchiver decode: pass

I wrote my own Swift program (`/tmp/s5-verify-scripts/decode.swift`) that runs `NSUnarchiver.unarchiveObject(with:)` on every blob.

- 1526 of 1526 blobs decode to an NSAttributedString, with 0 failures and 0 empty strings.
- Runtime classes: 1313 `NSConcreteMutableAttributedString` and 213 `NSConcreteAttributedString`. The archive headers agree.
- All 102 rows that have both fields carry `text` equal to the decoded string.
- The attribute keys are the real IM ones: `__kIMMessagePartAttributeName` on all 1534 runs, `__kIMFileTransferGUIDAttributeName` on 26, plus link, mention, bold, inline-media size and audio transcription.
- The bench's own Python decoder (`bench/typedstream.py`, read through `reader.py`) returns the same string as NSUnarchiver for all 1525 rows it loads. The one row it skips is 41502, the Recently Deleted message, which has no `chat_message_join` row. Every competitor joins through that table, so they skip it too.

## 2. Reproduction: pass

I ran `TZ=America/Los_Angeles bench/.venv/bin/python bench/run.py --no-write` twice, then once more with `TZ=UTC`. The three outputs are byte-identical. Every line of the output appears unchanged in `bench/results.md`, which covers all 40 task rows, the per-tool table and the fixed-context table.

The fresh clones in `/tmp/s5-verify/` are at the same commits as the `/tmp/s5-*/src` copies the bench used:

| Repo | Commit |
| --- | --- |
| openclaw/imsg | 1bc0679 |
| steve228uk/grok-bot-imessage | 8fe13b8 |
| jeffhuber/grokbot-imessage-skill | ccd12b9 |
| RyanNewsom/grokbot-imessage-reader | 2f0e8e1 |
| jimmyliu03/grok-bot-imessage | 0223cfc |
| cmer/imessage-bridge | f03ae36 |

All five skill files hash to the sha256 values in `overhead_data/counts.json`. Every tool's T1 output contains all 8 unread messages, and every tool's T3 output contains the answer (41381, "2219 Juniper Hollow Rd").

## 3. Renderer audit against the source

Each renderer below matches the code I read. Where a competitor comes out heavier than it should, the cause is the call script in `tasks.py`, not the renderer.

### imsg: renderer pass, one option worth a sensitivity row

- `MessagePayload` fields and the history extras match `Sources/imsg/OutputModels.swift` and `RPCPayloads.swift`. History in JSON mode always includes attachments and reactions.
- Search really does decode attributedBody (`MessageStore+Search.swift`), so matching against decoded text is correct.
- Names come from the nickname first (`ContactCatalog.swift:320`, `AddressBookContacts.swift:93`), so `contact_name` "Mom" is correct.
- `--query` is required (`BridgeIntroCommands.swift`), so the failing positional search in steve228uk's T3 is real.
- `| jq -s` matches the skill's own examples, but the skill presents it as optional. It also inflates output, because jq pretty-prints with a 2-space indent.
- Without `--json`, `imsg history` prints one line per message (`<ISO> [recv] <name>: <text>`, HistoryCommand.swift lines 95 to 116). That is close to our format.

| imsg variant, T1 to T3 | Tokens | vs ours |
| --- | ---: | ---: |
| As benchmarked, with `jq -s` | 15,591 | 4.9x |
| Compact NDJSON, no jq | 13,323 | 4.2x |
| Plain-text history, my approximation | about 8,276 | 2.6x |

### steve228uk: renderer pass, call script fail

The skill tells the agent to use `--json` without jq, and the renderer gets that right. The problem is that the script reads `--limit 50` in every T1, T2 and T4 history call, while the imsg script picks `--limit unread+4`, 10 and 3. Both skills show the same `--limit 50` example, so the same agent would choose the same limits for both. Most of steve228uk's 44,073 T1 tokens come from that one difference.

| steve228uk | As benchmarked | Same limits as imsg |
| --- | ---: | ---: |
| T1 | 44,073 | 6,973 |
| T2 | 9,982 | 4,004 |
| T4 | 18,784 | 3,708 |
| T1 to T3 | 55,895 (17.7x) | 12,817 (4.1x) |

### Grok Bot built-in: renderer pass, call script fail

The paging rules match `messages-worker.cjs`: the `items` default of 50 with a cap of 200, search 25 with a cap of 100, the 64,000-character page budget and the message item mapper. The worker has no read state, so "partial" for T1 is correct.

The script, though, calls `ChatItems` with the default 50 items:

- In T1 it does this for each of 7 chats, even though `IMessageActivity` has already returned the message count for each chat (1, 1, 2, 4, 1, 1 and 2).
- In T2 it reads 50 items, while every other tool reads about 10.

The `items` op takes a `limit` parameter. That the model-facing schema exposes it is inferred, because the tool schemas are server-side.

| Built-in | As benchmarked | Corrected |
| --- | ---: | ---: |
| T1 | 44,192 | 2,258 with limit = count, or 5,728 with limit = count + 4 |
| T2 | 6,483 | 1,634 with limit 10 |
| T1 to T3 | 51,146 (16.2x) | 4,363 to 7,833 (1.4x to 2.5x) |

### jeffhuber: renderer pass, minor script fix

- The helper decodes attributedBody (`helper.py` 1326 to 1380).
- Contacts read only ZFIRSTNAME, ZLASTNAME and ZORGANIZATION (`helper.py` 580), so "Mom matched nothing" is correct.
- Rows are ordered by chat_identifier and then date, the output is `indent=2`, and asking for the bridge folder followed by `ls` and `status` is what SKILL.md lines 58 to 79 require.
- The one fix is in T2. The second `chat_history` uses `limit 100` where the other tools read 10. With limit 10 it costs 737 tokens, not 1,879. jeffhuber's T1 to T3 total becomes 17,914 (5.7x).

### RyanNewsom: pass

- The 5 messages per thread, the 40-thread cap, the sorted keys, the nickname match (ZNICKNAME at `main.swift` 216) and the search scan window all match the source.
- T2 reads 7 days with the default limit of 200. With `--limit 10` it saves 155 tokens, which is immaterial.

### jimmyliu03: pass, minor note

- `IMsgChat` has no `contact_name` (`Models.swift` 3 to 21), so "numbers only" and the clarifying question are real.
- History keeps id, sender (from sender_name), is_from_me, text and created_at, which matches `BridgeToolbox.swift`.
- T3 reads 50 messages. The answer is the 13th newest in chat 9, so the default of 20 would find it, at 3,555 tokens for T3 instead of 4,872. The T1 to T3 total becomes 10,425 (3.3x).
- "yes" on T3 depends on how much traffic chat 9 has in the fixture.

### cmer: pass

- Contacts read no nickname (`Contacts.swift` 134), and the body is decoded (`MessagesDB.swift` 90).
- The output uses prettyPrinted, sortedKeys and withoutEscapingSlashes (`Router.swift` 398), which the renderer reproduces.
- `get_conversation` already returns fewer than 10 messages for Mom, so no correction is needed.

### Bias the other way

Some assumptions make competitors look better. They don't affect the verdict, but the README should not hide them.

- The built-in tool definitions count as 0 tokens.
- Every competitor's attributedBody decoder is assumed to work perfectly. RyanNewsom's, for example, is a byte heuristic.
- The built-in `FindContacts` is assumed to match nicknames.
- Built-in T2 sends with `chatId=any;-;+14155550101`. grokbot.md says the worker sends any chatId that starts with `any;` over SMS, so a "yes" there probably means an SMS was sent. The script should pass `to` instead, or the note should say so.

## 4. Realism of the call sequences

### Ours

1. **T4 is missing a call.** The `chats -n 5` output puts chat 23 first, with the preview "Yesterday You: did you get home ok?" and no time or ROWID. From that line alone, the agent can't rule out an incoming message from Jordan in chat 23 that is newer than 21:00. imsg's script reads both chats for exactly this reason. An honest ours script adds `imessage read 23 -n 3` (82 tokens), which takes T4 to 5 calls, 10 steps and 960 tokens. Alternatively, `chats` could show the time of each chat's newest incoming message, and then the extra call goes away.
2. **T4 and T5 are labeled "yes", but DESIGN gates both.** Tapbacks ship only after S3 passes (section 4), and group sends "stay marked unverified until S2" (section 3.8). The rows should read "unverified (S3 pending)" and "unverified (S2 pending)". The sends in T2 and T5 also depend on S1, which tests whether the Automation grant is tied to the bridge. Once relabeled, ours has 3 yes and 2 unverified. imsg has 2 yes and 3 unverified, and it attempts all five tasks, so "the only tool that does all five tasks" has to go.
3. **Every ours row comes from a renderer for a CLI that doesn't exist yet.** The 650-token skill is a placeholder, and across T1 to T3 it accounts for 1,950 of our 3,151 tokens (62%). If the real skill ends up the size of imsg's (1,906 tokens), our total doubles to about 6,900 and every ratio halves. results.md should say both things next to the tables.
4. **T1 chaining is asymmetric.** Ours runs its five `read` calls in one shell call, because our skill says to combine steps. imsg and steve228uk get five separate calls and five approval cards, though nothing stops an agent from chaining them. With chaining, imsg's T1 drops from 13 steps to 5 and its T1 to T3 steps from 23 to 15 (1.1x ours). steve228uk's drop from 26 to 18 (1.3x). Most of our step lead is one line in our skill. Either chain for every shell tool or add a sensitivity row.
5. **The Accessibility grant is counted on one side only.** imsg and steve228uk get a "grant" step in T4. Ours needs an Accessibility grant to the bridge as well, but it happens in `doctor`, so the script doesn't count it. Count it for every tool or for none.
6. **T5 syntax.** `imessage send Family --file P` leaves out the positional `<text>` that the DESIGN section 5 signature `send <who> <text> [--file P]` requires. Fix the script or the spec.
7. **Checked and fine.** T2 resolves "Mom" through the contact nickname and T3 filters with `--in Dad`, with no hidden lookups. The native approval dialogs for Mom, Family and chat 19 are counted.

### Competitors

1. **Uniform limits.** The agent should choose the same message counts for every tool that has a limit parameter. That means unread + 4 in T1, 10 in T2 and 3 in T4. This fixes steve228uk, the built-in and jeffhuber, as shown above.
2. **The nickname-only contacts favor some tools.** contacts.json stores "Mom" and "Dad" only as nicknames, with Meera and Sunil as first names. Tools that read nicknames (ours, imsg, RyanNewsom, and the built-in by assumption) resolve "Mom" directly. jeffhuber and cmer each pay a failed call plus a clarifying question. Many real address books store the contact's first name as "Mom". Add a second contacts.json variant with `first: "Mom"` and report both results.
3. **Scripts that look right.** These match each tool's documentation: jeffhuber's folder question, `status` call and `send_preview` nonce; steve228uk's question widget and its `--help` calls for undocumented verbs; jimmyliu03's in-app approval and retry; cmer's tool listing call in T2 and T3; RyanNewsom's raw osascript after a yes. The "no" rows for T4 and T5 also match the source: no tapback tool exists in the built-in, jeffhuber, RyanNewsom, jimmyliu03 or cmer, and none of those has a group file send.

## Corrected T1 to T3 totals

| Tool | Tokens as benchmarked | Corrected tokens | Corrected vs ours | What changed |
| --- | ---: | ---: | ---: | --- |
| ours | 3,151 | 3,151 | 1.0x | Nothing in T1 to T3. T4 rises to 960 |
| imsg | 15,591 | 15,591 | 4.9x | Nothing. 4.2x without jq, about 2.6x with plain text |
| grokbot-builtin | 51,146 | 4,363 to 7,833 | 1.4x to 2.5x | ChatItems limit set from the activity count, 10 in T2 |
| steve228uk | 55,895 | 12,817 | 4.1x | Same history limits as imsg |
| jeffhuber | 19,056 | 17,914 | 5.7x | `chat_history` limit 10 in T2 |
| RyanNewsom | 4,322 | 4,167 | 1.3x | `--limit 10` in T2 |
| jimmyliu03 | 11,742 | 10,425 | 3.3x | Default limit of 20 in T3 |
| cmer | 3,444 | 3,444 | 1.1x | Nothing |

## Corrections to make, in priority order

1. In `tasks.py`, give every tool the same history limits: unread + 4 in T1, 10 in T2 and 3 in T4. Pass `limit` to the built-in `ChatItems` using the counts from `IMessageActivity` in T1, and 10 in T2. Give steve228uk imsg's limits. Use 10 for jeffhuber's T2 `chat_history`.
2. Add `imessage read 23 -n 3` to our T4 script, or change `chats` so it shows the time of the newest incoming message.
3. Relabel our T4 as "unverified (S3)" and our T5 as "unverified (S2)". Drop "the only tool that does all five tasks" from the summary.
4. Next to the tables, state that ours is a renderer for an unbuilt CLI, and that 62% of our T1 to T3 tokens are the 650-token placeholder skill.
5. Count the Accessibility grant step for every tool or for none.
6. Add sensitivity rows: imsg without jq and with plain-text history, chained shell calls for imsg and steve228uk, and a contacts.json variant where Mom's first name is "Mom".
7. Fix our T5 command to include a text argument, or change DESIGN section 5 to make `<text>` optional when `--file` is given.
8. In built-in T2, send with `to=+14155550101` rather than the `any;` chat GUID, or note that the scripted call would probably go out as SMS.
9. Replace the summary's "1.1x to 17.7x lighter" with the corrected range, about 1.1x to 5.7x, and say plainly that no tool comes out 10x heavier on T1 to T3.

## Changes after VERIFY.md

These changes came after the check above. DESIGN.md section 5 also changed in between: `chats` now shows each chat's newest message with its time and sender, a new `unread [-c 2]` verb returns every unread message in one call, `send` takes `--file` without text, and the skill body budget is 400 tokens.

1. Every tool with a history limit now reads the unread count plus 4 in T1, 10 in T2 and 3 per chat in T4. The built-in `ChatItems` gets the `IMessageActivity` count plus 4 in T1 and 10 in T2. steve228uk uses imsg's limits, jeffhuber's T2 `chat_history` and RyanNewsom's T2 `thread` use 10, cmer's T2 `get_conversation` passes 10 (its output does not change), and jimmyliu03's T3 uses its default of 20.
2. `renderers/ours.py` follows the new section 5. `chats` prints the newest message's time, sender and first 60 characters, and the new `unread` verb groups unread messages by chat with `-c` lines of context. Ours T1 is now the skill load plus one `imessage unread -c 2` call.
3. The new `chats` preview still does not settle T4. Chat 23's newest message is the user's own at 22:58, so an incoming message from Jordan between 21:00 and 22:58 would not show. Ours T4 keeps `imessage read 23 -n 3`, next to `read 19 -n 3`.
4. Ours T4 reads "unverified (S3)" and ours T5 "unverified (S2)". The T2 and T5 notes say the send depends on S1. "The only tool that does all five tasks" is gone. The summary now lists every tool that attempts all five, with its yes and unverified counts.
5. The ours skill placeholder is 400 tokens, still labeled a placeholder. results.md says next to both tables that ours is a renderer for an unbuilt CLI, and that the skill is 1,200 of ours' 2,048 T1 to T3 tokens (59%).
6. Ours T4 counts an Accessibility grant step, like imsg and steve228uk. No other tool has a T4 path.
7. `imessage send Family --file P` is valid under the new signature, so ours T5 is unchanged.
8. Built-in T2 sends with `to=+14155550101` and `service=auto` instead of the `any;` chat GUID.
9. results.md has a sensitivity section. It covers imsg without jq, imsg with plain-text history (a new `imsg.history_plain` renderer built from HistoryCommand.swift lines 95 to 116), chained reads for imsg, steve228uk and ours, ours with `-c 4` and with a 1,906-token skill, and T1 to T3 for every tool with `Tests/Fixtures/contacts-firstname.json`, a new file where Mom and Dad are first names.
10. The main tables chain no tool's reads. With `unread`, ours no longer needs chaining in T1, so the asymmetry in section 4 item 4 is gone. Chaining appears only in the sensitivity rows.
11. The summary in results.md is generated from the numbers. On T1 to T3 the other tools use 1.7x (cmer) to 8.7x (jeffhuber) the tokens ours does. The highest ratio is 8.7x, and no tool is 10x heavier.

Two numbers differ from the estimates above:

- The corrected range is 1.7x to 8.7x, not about 1.1x to 5.7x. The estimate divided by the old ours total of 3,151 tokens. The DESIGN changes cut ours to 2,048 (the 400-token skill and the one-call `unread`), so every ratio went up. With a 1,906-token ours skill the range is 0.5x to 2.7x, and cmer and RyanNewsom would use fewer tokens than ours.
- imsg without jq is 14,206 tokens, not 13,323, and imsg with plain-text history is 9,159, not about 8,276. Without jq the agent cannot filter the chat list in T2 and T5, so these rows read the whole list with `imsg chats --limit 200 --json`.

Not changed: `research/spikes/S5.md` still quotes the 650-token skill, the 62% share and the 1.1x to 5.7x estimate. That file is outside `bench/`, so it was left alone.

### Second review

An independent reviewer checked the changes above and found seven problems. All seven were fixed. One number differs from the reviewer's proposal, explained under item 2.

1. Ours T1 now runs `imessage unread -c 4`, so it reads the same 4 earlier messages as every other tool with a limit. `Options.unread_context` defaults to `UNREAD_EXTRA`. The ours variants table has a row for `-c 2`, the DESIGN default. The summary sentence and the known-biases bullet about 2 lines of context are gone.
2. The ours skill placeholder now covers the whole SKILL.md, as every competitor count does. It is 450 tokens: the DESIGN.md section 6 caps of 400 body tokens and 40 description tokens, plus 10 tokens for the `---`, `name: imessage` and `description:` lines (`overhead.OURS_FRONTMATTER`, counted with o200k_base). The reviewer proposed 440, which leaves those lines out. A new ours variant uses the 628-token draft SKILL.md from research/tokens.md section 4, and the summary reports its range.
3. A new `imsg.chats_plain` renders plain `imsg chats` from ChatsCommand.swift lines 69 to 81. The plain-text rows use it in T2, T4 and T5. Only T1 keeps `imsg chats --unread-only --json`, for the unread count. The option is renamed from `plain_history` to `plain`. The plain chat list is 251 tokens on this fixture, and the row drops from 9,159 to 8,351 tokens.
4. The summary now says every tool that takes a history limit gets the same one, ours included. It no longer says every tool reads the same number of messages.
5. Ours T2 reads "unverified (S1)" and ours T5 "unverified (S1, S2)". Spike S1 checks that the Automation prompt names the bridge, which is the same -1743 risk behind the other tools' unverified osascript sends. Ours is now 2 yes and 3 unverified, the same as imsg and steve228uk.
6. The agent's own commands are now measured. `Session.command_tokens` counts the call labels: 1,735 tokens on T1 to T3 for jeffhuber, 150 to 201 for imsg, steve228uk, cmer and the built-in tool, and 40 for ours. The tasks.py docstring no longer calls them close for every tool. results.md has a known-biases bullet and an "Agent commands counted" table, and the summary gives the range with commands counted.
7. Minor fixes. The ours `chats` footer is now `more: imessage chats -n <n+20>` and the `unread` footer is `more: imessage read <chat>`, because section 5 gives neither verb an `--after` flag. Neither footer appears in the benchmark. `history_plain` prints the attachment count for unsent rows too, as HistoryCommand.swift does. No benchmarked window has such a row. The ours `search` code now cites research/tokens.md section 6 for its 120-character snippet. `research/spikes/S5.md` is still stale and still outside `bench/`.

New numbers on T1 to T3. Ours is 2,357 tokens and 12 steps. The other tools use 1.5x (cmer) to 7.6x (jeffhuber) the tokens ours does. Steps range from 1.0x (RyanNewsom) to 2.8x (jeffhuber).

| Ours setup | Ours tokens | Range |
|---|---:|---|
| Main: `unread -c 4`, 450-token skill | 2,357 | 1.5x (cmer) to 7.6x (jeffhuber) |
| Main, with every tool's commands counted | 2,397 | 1.5x (cmer) to 8.2x (jeffhuber) |
| `unread -c 2`, the DESIGN default | 2,198 | 1.6x (cmer) to 8.2x (jeffhuber) |
| 628-token draft skill | 2,891 | 1.2x (cmer) to 6.2x (jeffhuber) |
| 1,906-token skill, the size of imsg's | 6,725 | 0.5x (cmer) to 2.7x (jeffhuber), with cmer and RyanNewsom below ours |

No variant puts any tool 10x heavier than ours. The two runs under `TZ=America/Los_Angeles` and one under `TZ=UTC` print the same bytes.

### Round 2 review follow-ups

The second independent review passed checks A, B and E, and C for the main tables. It left four minor problems, and none of them moves the headline. All four are fixed:
1. The plain-text imsg rows now use plain `imsg search` too, via the new `renderers/imsg.py` `search_plain` (BridgeIntroCommands.swift lines 71 to 77). That row is 3.4x.
2. Ratios round half-up, so imsg's chained steps (15/12) print as 1.3x everywhere.
3. A known-biases bullet gives T1 to T3 steps with no shell approval cards, computed in `run.py` `_no_card_steps` rather than typed in.
4. The 628-token variant row is relabeled as a skill-size change only.

`run.py` output is byte-identical across two Los Angeles runs and one UTC run (sha1 829c12a5).
