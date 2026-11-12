# Token efficiency and cost of exposing iMessage to an agent

Date: 2026-11-05. Machine: macOS 26.2, Apple silicon. No messages were sent and nothing under `~/Library/Messages` was opened. All message data below is synthetic.

## Summary

- Output format matters far more than tool count. The same synthetic 50-message group chat costs 17,773 tokens as raw chat.db-style pretty JSON and 1,163 tokens in the proposed line format, a 15x difference. An emulation of a real server's output (wyattjoh/imessage-mcp) costs 14,910 tokens.
- Tool definitions for five real iMessage MCP servers cost 120 to 4,638 tokens each. Both target hosts already avoid most of that: grok CLI hides MCP tools behind `search_tool` and `use_tool`, and Grok Bot has a mode that sends only tool names and file paths. The output size is paid either way.
- A CLI plus a skill costs 77 tokens per request until the agent opens the skill. The proposed SKILL.md is 628 tokens and covers 16 verbs. The skills shipped by existing CLIs are 1,404 to 3,076 tokens.
- Grok Bot is metered against a weekly usage pool that counts "agent steps and tokens". Grok Bot picks the model and may route to third-party models. So the reasons to be efficient are pool drain, context window, and agent steps, not a per-call bill. grok CLI is subscription-metered when signed in and billed per token with `XAI_API_KEY`.
- Prompt caching makes stable definitions cheap after the first request (cached input is $0.50/M against $2.00/M on grok-4.6). Tool results enter at full price, then ride along at the cached rate on every later request. Cached tokens still count toward context and toward the xAI tokens-per-minute limit. Each extra agent step re-reads the whole prefix. At 50k tokens of context that costs about $0.025, which is more than the line-format chat read itself.

## Method and tokenizer

- Tokenizer: tiktoken 0.14.0, encoding `o200k_base`, in a throwaway venv at `/tmp/gbim-research/tokens/venv`. Grok's own tokenizer was not available offline, so all counts are a proxy (inferred). The ratios between formats should hold better than the absolute counts. Grok Bot can route to third-party models (see pricing), and those models use other tokenizers.
- No downloaded code was executed. Tool schemas were rebuilt by reading the source:
  - Python FastMCP (carterlasalle): parsed with `ast`, then turned into the pydantic-style JSON Schema FastMCP emits. Script: `/tmp/gbim-research/tokens/scripts/fastmcp_extract.py`.
  - Literal JS objects (tszaks): parsed with `json5`. Script: `/tmp/gbim-research/tokens/scripts/tszaks_extract.py`.
  - Zod schemas (anipotts, wyattjoh) and literal TS (marissamarym): transcribed by hand into JSON Schema. Script: `/tmp/gbim-research/tokens/scripts/build_ts_servers.py`.
- Each server was counted as the minified OpenAI-style function list (`{"type":"function","function":{name, description, parameters}}`), which is the shape xAI's chat API takes. How a host renders tools into the prompt is not public, so these counts are a proxy (inferred).
- Formats and the synthetic chat: `/tmp/gbim-research/tokens/scripts/synth_chat.py` and `/tmp/gbim-research/tokens/scripts/fmt_measure.py`. Every rendered format is saved under `/tmp/gbim-research/tokens/out/formats/`.

## 1. Pricing and metering

### xAI API prices (per 1M tokens, prompts under 200k tokens)

| Model | Input | Cached input | Output | Context |
|---|---|---|---|---|
| grok-4.7 | $2.00 | $0.50 | $6.00 | 500k |
| grok-4.6 | $2.00 | $0.50 | $6.00 | 500k |
| grok-4.5 | $2.00 | $0.30 | $6.00 | 500k |
| grok-4.3 | $1.25 | $0.20 | $2.50 | 1M |
| grok-build-0.1 | $1.00 | $0.20 | $2.00 | 256k |

Rates double for prompts of 200k tokens or more. Status: verified, https://docs.x.ai/docs/models (fetched 2026-11-05). The fetched page summary also said the higher rate covers the whole request, so a 210k prompt is billed entirely at the higher rate (reported, same URL, read through a fetch summarizer). Third-party pages agree on the grok-4.6 numbers (reported, https://www.eesel.ai/blog/grok-4-6-pricing, https://kingy.ai/blog/grok-4-6-price-benchmarks-api-cursor-context-window/).

### Which models the two hosts use

- grok CLI docs use `grok-build` and `grok-4.6` as model ids. The README config example sets `default = "grok-4.6"`, and another doc example uses `grok-4.5`. Verified: `~/.grok/README.md` lines 1374 and 401 to 423, `~/.grok/docs/user-guide/05-configuration.md` line 54. The default your account actually gets was not checked, because that needs a signed-in run.
- The Grok Bot bundle has a constant `uf="grok-4.5"` and model-picker experiments listing `grok-4.5` and `grok-4.6`. Verified: `/tmp/gbim-research/grokbot/app/dist` (main-app and renderer bundles, string search).
- The xAI Grok Bot FAQ says "Grok Bot picks the model for each task, and there is no model picker". It says the model can be first-party or third-party, and that "Routing a task to Opus 5.5 doesn't change what it costs you per token". Reported, https://docs.x.ai/grok-bot/faq.

### How Grok Bot is metered

- Grok Bot is subscription-metered with a weekly pool and optional on-demand overage. These app strings are verified in `/tmp/gbim-research/grokbot/app/dist/renderer/assets/index.eager-app-BtHDDJog.js`:
  - "Included usage with your subscription. Resets weekly."
  - "You've used this week's included usage. Further usage draws from additional usage below."
  - "Get $1,000 of Grok Bot usage each week with Ultra"
  - "Monthly on-demand spend limit"
  - "Group chats spend more of your included usage because multiple Bots process each message"
  - "Your spend limit applies to your combined Grok Bot and Cursor spend"
  - "Link SuperGrok Plus or SuperGrok Heavy for Grok Bot access with a separate usage pool"
- The "$1,000 of usage each week" string means the pool is denominated in dollars of usage. That suggests tokens are priced against the pool at some per-token rate (inferred). The rate is not published.
- The FAQ says trial credit is "measured by agent steps and tokens rather than the number of messages you send". Reported, https://docs.x.ai/grok-bot/faq.
- Cursor's help page says Grok Bot usage on the X Subscription "draws from the same weekly pool as Cursor and the Grok apps". It gives no pool sizes. Reported, https://cursor.com/help/grok-bot/plans.
- What this means: for Grok Bot, every token and step drains the weekly pool. The pool is shared with Cursor and the Grok apps on newer plans. Context-window pressure and step count matter as much as dollars (inferred).

### How grok CLI is metered

- `grok login` stores a session token, and that takes precedence. `XAI_API_KEY` is used only when no session is active, and then you pay API rates. Verified, `~/.grok/docs/user-guide/02-authentication.md`.
- Headless JSON output reports `total_cost_usd` and the cache buckets `input_tokens` (uncached only), `cache_read_input_tokens`, and `cache_creation_input_tokens`. Verified, `~/.grok/docs/user-guide/14-headless-mode.md` lines 196 to 241.
- The binary contains the error classes `usage_pool_exhausted`, `usage_limit_reached`, `global_rate_limit`, and `concurrency_limit`. Verified with `strings` on `~/.grok/downloads/grok-1.0.70-macos-aarch64`. That subscription sessions hit pool limits rather than a dollar bill is inferred.

### Rate limits

xAI limits each model by requests per second and tokens per minute. Cached prompt tokens "still count toward TPM, though they are billed at a reduced rate". The grok-4.6 and grok-4.7 limit at tier 0 is 150 RPS and 50M TPM. Verified, https://docs.x.ai/developers/rate-limits. So caching saves money but does not free up rate limit or context window.

## 2. Prompt caching effects

What xAI documents. All verified at https://docs.x.ai/developers/advanced-api-usage/prompt-caching and its subpages `/how-it-works` and `/multi-turn`.

- Caching is automatic and matches the longest exact prefix of the messages array. The `x-grok-conv-id` header, or `prompt_cache_key` on the Responses API, routes a conversation to the same server so the prefix is more likely to still be cached.
- "The cacheable prefix includes all messages up to and including tool call results."
- "Any change to earlier messages breaks the cache." Caching "is not 100% guaranteed". No TTL or minimum length is published.
- The docs do not say whether tool definitions are part of the cached prefix. They almost certainly are, because tools are rendered before the conversation (inferred).

What this means for an iMessage interface (inferred unless marked):

1. Tool definitions and the skill listing sit in the stable prefix. After the first request they cost the cached rate, $0.50/M on grok-4.6, which is 25% of list. They still take context window and TPM on every request. They are also paid in every session, including sessions that never touch Messages.
2. A tool result is new text. It costs full input price on the request where it first appears. After that it is part of the prefix and is re-read at the cached rate on every later request until compaction. A big result is paid many times.
3. Each extra agent step re-sends the whole context at the cached rate, plus the output tokens the model writes. Reducing steps (resolve names inside one call, verify a send inside one call) saves more than shaving 10% off an output.
4. Anything that changes the prefix mid-session breaks the cache for everything after it. Examples are an MCP server reconnecting with a different tool list, or a timestamp injected into the system text. A static SKILL.md and a CLI never change the prefix.

### Cost model (grok-4.6 prices, one 20-request agent session)

The assumptions are a cold cache on request 1 and cache hits after. One chat read happens at request 3 and is carried for 17 more requests. Formula for always-on text: `T x ($2 + 19 x $0.50) / 1M`. Formula for a result: `O x ($2 + 17 x $0.50) / 1M`. Computed by me, so the numbers are inferred from verified prices.

| Item | Tokens | Cost per session |
|---|---|---|
| carterlasalle tool defs, always on | 4,638 | $0.0533 |
| anipotts tool defs, always on | 2,736 | $0.0315 |
| wyattjoh tool defs, always on | 1,382 | $0.0159 |
| Minimal 5-tool MCP (section 6) | 437 | $0.0050 |
| Skill listing only (CLI design, unused session) | 77 | $0.0009 |
| Skill listing plus SKILL.md loaded at request 2 | 77 + 628 | $0.0078 |
| One 50-msg read, raw rows pretty JSON | 17,773 | $0.1866 |
| One 50-msg read, wyattjoh-style output | 14,910 | $0.1566 |
| One 50-msg read, compact JSON | 6,858 | $0.0720 |
| One 50-msg read, proposed line format | 1,163 | $0.0122 |
| One extra agent step at 20k / 50k / 100k context | 60 output tokens | $0.0104 / $0.0254 / $0.0504 |

On grok-4.5 (cached $0.30) the same rows are about 30% to 35% lower. On grok-build-0.1 they are about 60% lower. The ranking does not change.

## 3. Tool-definition overhead of existing iMessage MCP servers (measurement a)

Repos were cloned shallow into `/tmp/gbim-research/tokens/repos/` and read only.

| Server (commit) | Tools | Minified JSON tokens | Pretty JSON tokens | Description text only | Largest tool |
|---|---|---|---|---|---|
| carterlasalle/mac_messages_mcp (8b0cef1), Python FastMCP, 343 stars | 18 | 4,638 | 6,438 | 1,869 | tool_get_recent_messages, 579 |
| anipottsbuilds/imessage-mcp (3cf55e2), TS zod v4 | 8 | 2,736 | 3,898 | 623 | get_conversation, 656 |
| tszaks/imessage-mcp (981cae7), JS, default flags | 14 | 1,881 | 2,896 | 388 | send_message_batch, 257 |
| tszaks/imessage-mcp, all release flags on | 18 | 2,244 | 3,491 | 489 | send_message_batch, 257 |
| wyattjoh/imessage-mcp (df30659), TS zod v4 | 6 | 1,382 | 1,864 | 492 | search_messages, 329 |
| marissamarym/imessage-mcp-server (4ed3876), TS | 2 | 120 | 224 | 16 | send_imessage, 70 |

All rows are verified (I read the source). The token counts are computed by me with o200k_base. Star counts come from `gh search repos`, run 2026-11-05.

Notes:

- carterlasalle's descriptions are 1,869 of its 4,638 tokens. The rest is names, types, defaults, and JSON structure. Pydantic adds 72 `title` fields and 21 `anyOf: [{type}, {type: null}]` unions for optional fields. Removing only those two drops the total to 4,057 tokens, a saving of 581 (measured). The tool definitions run from `mac_messages_mcp/server.py` line 81 to the last `@mcp.tool()` at line 1032. The server also ships `instructions` (161 tokens) and a 3,076-token Claude skill. The skill is loaded in addition to the MCP tools, not instead of them (`.claude/skills/mac-messages/SKILL.md`). Verified.
- anipotts also registers an `outputSchema` for every tool. The zod source for those schemas alone is 3,163 tokens (`src/server.ts` lines 50 to 418). The JSON expansion is larger, because `resultSchema()` unions every output with the error envelope. Verified for the code, inferred for the size. Whether a host forwards `outputSchema` to the model is host-specific and unknown. Its server `instructions` are 121 tokens. Its cursors can be up to 16,384 characters (`src/references.ts` line 8), which is a token risk if a cursor is ever echoed back. Verified.
- wyattjoh's descriptions say "you MUST paginate through ALL results ... until hasMore=false". That tells the model to dump whole conversations. It also returns `JSON.stringify(result, null, 2)`. Verified, `packages/imessage-mcp/src/index.ts` lines 152 to 360.
- marissamarym is cheap because it does almost nothing: send plus contact search.

### How the two target hosts load MCP tools

- grok CLI does not put MCP tool definitions in the prompt. The model sees two meta-tools, `search_tool` and `use_tool`. Its prompt text says "Call `search_tool` to get a tool's input schema before you call `use_tool`". `tool_definitions.json` omits MCP `server__tool` entries for this reason. MCP results are capped at 20,000 bytes inline, and the rest spills to a file. Verified: `~/.grok/docs/user-guide/07-mcp-servers.md` lines 45 to 58 and 236 to 241, `17-sessions.md` line 42, and the binary strings.
- Consequence for grok CLI: an MCP server costs about 0 always-on tokens. The first use of each tool costs one extra agent step plus the returned schema. A 50-message read in raw pretty JSON (52,798 bytes) or wyattjoh-style output (43,088 bytes) would be truncated by the 20 KB cap. The line format (3,255 bytes) fits about 300 messages under the cap. The byte counts are measured, and the truncation is inferred from the documented cap.
- Grok Bot has an MCP "filesystem" mode, `McpFileSystemWriter`. It writes each tool's full definition to `<project>/mcps/<server>/tools/<tool>.json` and sends upstream only `{toolName, definitionPath, annotations}` per tool. The feature flag `mcp_meta_tool_slim_descriptors` defaults to true. Verified: `/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/main.cjs` (`McpToolDescriptor|1 tool_name|2 definition_path|3 description?|4 input_schema?`, `fireOnDidWrite`, constants `km="mcps"`, `Om="tools"`) and `electron-main/main-app.cjs` (flag defaults). Whether the server turns this on for a given user, and how it renders the descriptors, is decided server-side (inferred).
- This is Cursor's "dynamic context discovery". Cursor reported that it cut total agent tokens by 46.9% in runs that called an MCP tool. Reported, https://cursor.com/blog/dynamic-context-discovery.
- Grok Bot already has built-in iMessage tools: SearchIMessages, FindIMessageChats, SendIMessage, FetchIMessageAttachment, IMessageActivity, and CheckIMessagePermissions. It also has Shell, Read, and Skill tools. Verified, tool-name enum in `local-exec-daemon/main.cjs`. The built-in tools' prompt cost is server-side and unknown.

What this means: in these two hosts, tool count barely changes the per-request bill. Output format and step count decide it. Tool count still matters for any other host the repo might be shared with, such as Claude Desktop or clients without lazy loading.

## 4. CLI plus skill design (measurement b)

How skills reach the model:

- grok CLI renders skills into an `<available_skills>` block with `<name>`, `<description>`, and `<location>` per skill. Its skill tool loads the body on demand into a `<skill_content name="...">` block. Verified, template strings in the grok binary (`xai_grok_tools::implementations::opencode::skill`). grok CLI inlines at most 25,000 tokens of a skill body. Verified, `~/.grok/docs/user-guide/08-skills.md` "Best Practices" item 7. It also scans `.agents/skills/` and `~/.claude/skills/`. Verified, same file.
- Grok Bot sends `SkillDescriptor {name, description, folder_path}` and `AgentSkill {full_path, content, description, ...}` to its backend. It also has a `Skill` tool. Verified, proto field lists in `local-exec-daemon/main.cjs`. That the prompt shows only name and description until the skill is opened is inferred from the Cursor-style design.

Measured sizes (o200k_base):

| File | Chars | Tokens |
|---|---|---|
| Proposed listing entry (name, description, location) | 296 | 77 |
| Proposed SKILL.md, full file, 16 verbs | 2,247 | 628 |
| openclaw/imsg `.agents/skills/imsg/SKILL.md` | 7,557 | 1,906 |
| camolechowski/imsg `skills/imsg/SKILL.md` | 5,508 | 1,404 |
| camolechowski/imsg `references/commands.md` | 9,734 | 2,889 |
| carterlasalle `.claude/skills/mac-messages/SKILL.md` | 12,824 | 3,076 |

Description lengths: proposed 38 tokens, openclaw 18, camolechowski 68, carterlasalle 86. Verified, `/tmp/gbim-research/tokens/scripts/count_skill.py`.

Call-side cost (the tokens the model writes) is about equal for CLI and MCP. `imessage read 12 -n 30` is 9 tokens, or 13 inside the bash tool's JSON. The MCP arguments `{"chat":"12","limit":30}` are 9 tokens. Measured.

Proposed SKILL.md (saved at `/tmp/gbim-research/tokens/out/skill/imessage/SKILL.md`):

```markdown
---
name: imessage
description: Read, search, and send iMessage and SMS on this Mac with the imessage CLI. Use for any request about texts, Messages, group chats, reactions, replies, or attachments.
---

# iMessage

Run `imessage <verb>` in the shell. Output is plain text written for you. Add `--json` only when a script needs it.

## Read

- `imessage chats [-n 20] [--unread] [--q NAME]` lists chats, newest first.
- `imessage read CHAT [-n 30] [--before ID | --after ID | --around ID] [--since 2d]` prints one thread, oldest first. CHAT is a chat id, contact name, phone number, or email.
- `imessage search TEXT [--in CHAT] [--from NAME] [--since 30d] [-n 20]` prints matching lines with their chat.
- `imessage who NAME` resolves a contact to handles and chat ids.
- `imessage att ID` converts attachment ID to a file you can open (HEIC to JPEG, voice to M4A plus transcript) and prints its path.

Each message is one line:
`ID HH:MM Sender: ↩REPLYID text [photo aID 2.1MB] (edited) [❤️Mom,Dad 😂Priya]`
"You" is the user. `-- Today` and `-- Yesterday` start each day. `*` marks a group event. A last line `more: imessage read ...` means older messages exist. Read more only when the task needs it.

## Write (only when the user asked)

- `imessage send TO TEXT [--reply ID] [--file PATH]` TO is a chat id, name, phone, or email. Use the chat id for groups.
- `imessage react ID love|like|dislike|laugh|emphasize|question|EMOJI [--remove]`
- `imessage edit ID TEXT` and `imessage unsend ID` work on your own recent messages.
- `imessage mark-read CHAT`, `imessage typing CHAT`
- `imessage group CHAT --rename NAME | --add HANDLE | --remove HANDLE`

Before a send, react, edit, or unsend, check that the recipient and text match what the user asked for. Report the printed result line.

## Wait for replies

- `imessage wait CHAT [--timeout 10m]` blocks until a new message arrives, then prints it. Exit code 3 means timeout.
- `imessage new [--since CURSOR]` prints messages since the cursor and a new cursor.

## Errors

Errors are one line: `error: <what failed>. fix: <command or setting>`. Run `imessage doctor` for permission problems. Run `imessage help VERB` for rare flags; see `references/verbs.md` for effects, polls, and stickers.
```

The skill lists verbs whose feasibility the other research reports are checking (edit, unsend, typing, group management). If a verb turns out to need a private-API bridge, the skill should say so in one line. openclaw/imsg puts these behind an injected bridge that needs SIP disabled (verified, `openclaw_imsg/.agents/skills/imsg/SKILL.md` "Ground rules").

## 5. Output formats for a 50-message group chat (measurement c)

### The synthetic chat

The test chat is "Desai Fam", a group of 4 contacts plus you, spanning yesterday and today. It has 50 messages and 31 tapback rows on 19 of those messages: 12 laugh, 8 love, 6 like, 2 emphasize, 2 dislike, and 1 custom emoji 🎉. It also has 24 inline replies, 6 attachments on 5 messages (3 photos, 1 video, 1 voice message with transcript, 1 PDF), 1 link preview, 3 edits, 1 unsend, and 1 group rename. The message bodies alone are 400 tokens, which is the floor for any format. All names, numbers, and text are invented. The measured files gave the family a different surname, so counts for this text can differ by a few tokens.

### Results

| Format | Chars | Tokens | Tokens per msg | vs raw rows |
|---|---|---|---|---|
| A. Raw chat.db-style rows, pretty JSON, nulls kept, tapbacks as 31 extra rows | 52,668 | 17,773 | 355 | 1.00 |
| W. wyattjoh/imessage-mcp output emulated (81 rows, no names, pretty) | 42,948 | 14,910 | 298 | 0.84 |
| G. NDJSON in openclaw/imsg's documented shape (chat fields repeated per line) | 29,173 | 11,095 | 222 | 0.62 |
| B. Pretty JSON, tapbacks folded into parent, nulls dropped, GUIDs, ISO dates, handles | 24,447 | 8,985 | 180 | 0.51 |
| C2. B minified with Python's default `ensure_ascii=True` (emoji as `\u` escapes) | 17,700 | 7,072 | 141 | 0.40 |
| C. B minified | 17,358 | 6,858 | 137 | 0.39 |
| D1. C with 1 to 2 letter keys, same values | 14,140 | 6,585 | 132 | 0.37 |
| D2. Short keys plus pruned values (first names, HH:MM, day groups, no GUIDs, paths, handles) | 4,470 | 1,704 | 34 | 0.10 |
| E. TSV with header, same pruned values as D2 | 3,522 | 1,307 | 26 | 0.07 |
| F. Proposed line format (with header and `more:` footer) | 3,132 | 1,163 | 23 | 0.07 |

All rows are measured; the files are in `/tmp/gbim-research/tokens/out/formats/`. G follows the field table in `openclaw_imsg/docs/json.md` (verified). W follows the SELECT in `wyattjoh_imessage-mcp/packages/imessage/src/messages.ts` lines 163 to 184 (verified).

What the table shows:

- Short keys alone save 4% (C to D1). The real savings come from dropping values the model does not need: GUIDs at 35 tokens each, ISO timestamps at 16, phone handles at 5, attachment paths, and repeated chat fields. Moving from D1 to D2 saves 74%.
- Once values are pruned, the syntax matters less. Line format beats TSV by 11% and short-key JSON by 32%. TSV pays for a day column on every row and for empty columns.
- Folding tapbacks into the parent saves about half (A to B), because chat.db stores each tapback as its own row with text like `Laughed at "..."`.
- Python's default `ensure_ascii=True` adds 3% on emoji-heavy chats.

### Line-format variants (same data)

| Variant | Tokens |
|---|---|
| Proposed: rowids, 24h time, `↩ID` replies, `[❤️Mom,Dad 😂Priya]` | 1,156 |
| No message ids | 1,006 (13% less, but the agent can no longer react or reply) |
| No attachment ids | 1,138 |
| Reply as `>48201` | 1,132 |
| Reply as `re 48201:` | 1,180 |
| Reply as `(reply to 48201)` | 1,228 |
| Reactions as `[❤️ by Mom, Dad]` | 1,194 |
| Reactions as words `[love Mom,Dad]` | 1,151 |
| 12-hour times `6:02p` | 1,206 |
| No header line | 1,121 |

The variants use an earlier header, `Desai Fam · group chat 12 · Mom, Dad, Priya, Arjun, You · 50 msgs · PST · older: --before 48201`, and no footer. That is why the base variant reads 1,156 here (`F_line_format.txt`) while the final file, with the shorter header and a separate `more:` line, reads 1,163 (`F_final_recommended.txt`). Variant texts are in `/tmp/gbim-research/tokens/out/formats/F_variants.json`.

Unit costs in o200k_base: `❤️`, `👍`, `😂`, `love` are 1 token each. `‼️`, `❓`, `🎉`, `↩` are 2. A 5-digit rowid is 2. `18:02` is 3. A message GUID is 35. An ISO timestamp with offset is 16. Measured.

### Proposed format, exact field order

```
chat <chat_id> <chat name> (group: <member names>, You) · <shown> of <total> · times <TZ>
-- <Today | Yesterday | Mon | Oct 28 | Oct 28 2025> [<weekday month day>]
<msg_rowid> <HH:MM> <Sender>: [↩<reply_rowid>] [<text>] [<attachments>] [(edited) | (unsent)] [<reactions>]
<msg_rowid> <HH:MM> * <Actor> <group event>
more: imessage read <chat_id> --before <oldest_rowid>
```

Field rules:

1. `msg_rowid` is the chat.db ROWID. It is the handle for react, reply, edit, unsend, and paging, and it costs 2 tokens. Do not use GUIDs in the default output.
2. Use local time, 24-hour `HH:MM`, and state the time zone once in the header. Days are relative: Today, Yesterday, a weekday name within 6 days, `Oct 28` within the year, and `Oct 28 2025` before that.
3. `Sender` is the Contacts nickname or first name, and "You" for the user. If two members share a first name, add the last initial (`Sam L`). Fall back to a formatted phone or email only when there is no contact.
4. `↩<id>` marks an inline reply (`thread_originator_guid` or `reply_to_guid` mapped to a rowid). If the parent is not on screen, add a 30-character quote: `↩48100 (Mom: Who is coming Sunday…)`.
5. Unsent messages print `(unsent)` with no text. Edited messages print the current text plus `(edited)`. Edit history only appears with `--edits`.
6. Reactions are described in "Folding tapbacks" below.
7. Messages are oldest first, so the newest is last and closest to the model's next turn. Order is stable and deterministic.

Excerpt of the measured output (`F_final_recommended.txt`):

```
chat 12 Desai Fam (group: Mom, Dad, Priya, Arjun, You) · 50 of 412 · times PST
-- Yesterday Wed Nov 4
48201 18:02 Mom: Who is coming Sunday for Diwali dinner?
48202 18:05 Dad: Me obviously [❤️Mom 😂Priya]
48203 18:06 Priya: ↩48201 I can come after 2, have a shift in the morning
48207 18:21 Mom: ↩48206 Get kaju katli and 2 boxes of jalebi (edited)
48208 18:24 Priya: [photo a9901 2.2MB]
48209 18:24 Priya: Rangoli practice from last year lol [😂Arjun ❤️Mom ‼️Dad]
48218 19:40 * Dad renamed the group to "Desai Fam"
48219 20:15 Priya: Here is the recipe Nani used for the dal [file a9902 Nani_dal_recipe.pdf 348KB]
48221 21:03 Arjun: [link nytimes.com: A Guide to Diwali Sweets, From Barfi to Jalebi]
-- Today Thu Nov 5
48228 09:02 Arjun: [voice a9903 0:07 "hey can someone send me Dads address for the GPS"]
48229 09:04 Dad: ↩48228 You have been there 500 times [😂Priya,You,Mom]
48238 10:41 Priya: Green it is [🎉Mom ❤️You]
48239 11:15 Dad: (unsent)
48242 11:50 Arjun: [video a9906 0:14]
48250 12:30 Arjun: Yes. And I'm bringing gulab jamun anyway [😂Priya,Dad 👎Mom]
more: imessage read 12 --before 48201
```

Other example outputs, measured (files in `/tmp/gbim-research/tokens/out/examples/`):

```
$ imessage chats -n 6                                       (153 tokens; 735 as equivalent compact JSON)
12 Desai Fam (group: Mom, Dad, Priya, Arjun) 3 unread · 12:30 Arjun: Yes. And I'm bringing gulab jamun anyway
7 Mom · 11:58 You: Ok will call after lunch
31 Sam Lee · 10:02 Sam: are we still on for 7? (unread)
4 Priya · Yesterday You: [photo]
56 +1 (650) 555-0142 · Yesterday: Your verification code is 482019 (SMS)
19 Climbing crew (group: Sam, Jo, Ana, 2 more) · Mon Jo: [link strava.com: Morning climb]
more: imessage chats -n 20 --after 19

$ imessage search jalebi                                    (95 tokens)
search "jalebi" · 3 hits, newest first
12 Desai Fam · Yesterday 19:06 · 48217 Mom: Already getting jalebi, no gulab jamun
12 Desai Fam · Yesterday 18:21 · 48207 Mom: Get kaju katli and 2 boxes of jalebi (edited)
7 Mom · Oct 28 · 47011 Mom: …the place on Mission has better jalebi than Bombay Sweets…

$ imessage who Mom                                          (31 tokens)
Mom = Meera Desai · +1 415-555-0101 (iMessage) · chats: 7 (direct), 12 Desai Fam

$ imessage att a9904                                        (36 tokens)
a9904 photo IMG_4420.HEIC 1.9MB 4032x3024 -> /tmp/imessage/a9904.jpg (1600px)

$ imessage send 12 "Green it is!" --reply 48233             (23 tokens)
sent 48251 to Desai Fam ↩48233 "Green it is!" · delivered 12:41
```

`--json` should stay available for scripts. It should emit NDJSON with short but readable keys and no repeated chat fields. It should not be the default for the agent.

## 6. Recommendations

### Interface shape

- Ship one skill named `imessage` and one CLI named `imessage`. The skill listing costs 77 tokens per request until the skill is opened, and the opened skill costs 628 tokens. The name is 2 tokens, the same as `imsg`, and it avoids clashing with openclaw/imsg's `imsg` binary (1,403 stars, verified via `gh search repos`). Inferred recommendation.
- Use 16 verbs in four groups:
  - read: `chats`, `read`, `search`, `who`, `att`
  - write: `send`, `react`, `edit`, `unsend`, `mark-read`, `typing`, `group`
  - wait: `wait`, `new`
  - support: `doctor`, `help`
- Rare features go in `references/verbs.md`, which the skill points to and the agent loads only when needed.
- If a host needs MCP, expose at most 5 tools: `imessage_read`, `imessage_send`, `imessage_act` (react, unreact, edit, unsend), `imessage_attachment`, and `imessage_wait`. That set measured 437 tokens. The definitions are at `/tmp/gbim-research/tokens/out/minimal_mcp.json`. Leave out `title` and nullable `anyOf` boilerplate. With FastMCP, pydantic adds both by default.

### Description lengths

- Keep the skill description at or under 40 tokens. Name the triggers in it: texts, Messages, group chats, reactions, replies, attachments.
- Keep MCP tool descriptions at or under 35 tokens. Describe a parameter only when its name is not self-explanatory.
- Never write "MUST paginate through ALL results", as wyattjoh does. Say the opposite: "Read more only when the task needs it."

### Default limits and paging

| Verb | Default | Approximate output |
|---|---|---|
| `chats` | 20 | about 25 tokens per chat, about 500 total |
| `read` | 30 messages | about 23 tokens per message, about 700 total |
| `search` | 20 hits | about 30 tokens per hit, about 600 total |

- Hard cap: 200 per call.
- Add a byte budget. The default should be 12,000 bytes, about 3,500 tokens, which keeps every result under grok CLI's 20,000-byte MCP cap. Stop at whichever limit hits first.
- Page with plain rowids: `--before ID`, `--after ID`, `--around ID`. Do not use opaque base64 cursors.
- End every truncated result with one `more:` line that holds the exact next command.

### Avoiding whole-conversation dumps

- Offer no `--all` flag by default.
- To summarize, read the window that matters: `read CHAT --unread`, `read CHAT --since 2d`, or `new --since CURSOR` for "what's new".
- For facts ("what's Dad's address"), use `search` to find the message, then `read --around ID` for context. The search hit line already includes the chat and rowid, so this takes one extra step at most.
- In `read`, cut message bodies at 400 characters: `…(+1,234 chars: imessage read 12 --around 48213 --full)`. In `search`, show about 120 characters around the match.
- For a 2,000-message thread, a full dump would be about 46k tokens in the line format and about 600k at wyattjoh-style density. The second figure is larger than the 500k grok-4.6 context window. Inferred from the per-message rates above.

### Folding tapbacks into the parent line

- Never print a tapback as its own row in `read`. Do not count tapback rows toward `-n` or toward paging.
- Compute the net state per (reactor, parent). Treat associated_message_type 2000 to 2006 as add and 3000 to 3006 as remove. For custom emoji, use `associated_message_emoji`. Show stickers as `[sticker by Priya]`.
- Group reactions by emoji in order of first reaction, and list reactor names after each emoji: `[😂Priya,You,Mom ❤️Dad]`. This is the cheapest readable variant measured. `[❤️ by Mom, Dad]` costs 3% more.
- In live output from `wait` and `new`, a new tapback on an older message becomes one event line: `48301 12:41 Mom ❤️ 48233 ("New kurta for Sunday, wh…")`.

### Describing attachments compactly

Use kind, attachment id, and size or duration:

- `[photo a9901 2.2MB]`
- `[video a9906 0:14]`
- `[voice a9903 0:07 "transcript"]`, with the transcript only if one is available
- `[file a9902 Name.pdf 348KB]`
- `[link site: title]`

Show the filename only for documents, because names like `IMG_4420.HEIC` add nothing. Never print `~/Library/Messages/Attachments/...` paths. `imessage att ID` returns a converted file path, such as a JPEG at 1600px or less, that the agent opens with its file or image reader. The image's tokens are then paid only when someone looks at it.

### One-line errors

- Format: `error: <what failed>. fix: <command or setting>`. Use exit code 1 for errors, 2 for usage, and 3 for a wait timeout.
- Measured examples run 31 to 42 tokens. An equivalent pretty JSON error object is 103 tokens.

```
error: no Full Disk Access for this app. fix: System Settings > Privacy & Security > Full Disk Access, add Grok Bot, then rerun
error: "Mo" matches 2 contacts: Mom (+1 415-555-0101), Mohan Rao (+1 408-555-0199). fix: pass a chat id or phone
error: send not confirmed after 10s (msg 48251 still pending). fix: imessage read 12 --after 48250 to check before resending
```

### Cutting agent steps

- Every verb should accept a name, phone, email, or chat id and resolve it internally. "What did Mom say about Sunday" then takes one call instead of `who`, `chats`, and `read`. At 50k context, each step saved is worth about $0.025 at grok-4.6 cached rates, more than a whole 50-message read in the line format.
- `send` should wait for the delivery state itself and print one result line, so the agent does not need a follow-up read. Grok Bot's own messages worker separates sent, timed-out, and unconfirmed sends: it maps `sidecar_timeout` to `messages_send_timed_out`, and `sidecar_closed`, `ECONNRESET`, and `EPIPE` to `messages_send_unconfirmed`. Verified, `/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs`. An unconfirmed send should print an error line that warns against resending blindly, as in the third error example above.

### Keeping the cache warm

- Keep SKILL.md static: no dates, counts, or machine-specific paths in the body.
- Return deterministic output ordering.
- Do not add or remove MCP tools mid-session.

## Open questions

- Absolute token counts under Grok's own tokenizer, and under the third-party models Grok Bot may route to, were not measured. Running these files through an xAI token-count path with a key would settle it.
- Whether Grok Bot's backend turns on MCP filesystem or meta-tool mode for local stdio servers, and how it renders skill listings, cannot be seen from the client bundle.
- The per-token rate at which Grok Bot draws from its dollar-denominated weekly pool is not published.
- Whether Grok Bot's Shell tool truncates long stdout, and at what size, was not found in the bundle.
- Whether macOS 26 stores voice-message transcripts in chat.db, so `[voice ... "transcript"]` can be filled without running speech recognition, needs checking against the schema in `chatdb-schema.sql` by another key.
