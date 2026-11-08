# Real-time incoming messages, agent wake-up and safety

Written 2026-11-05 on macOS 26.2 (Darwin 25.2.0), Apple silicon.

## Method and labels

Every claim has one of three labels.

- verified: I read the code or document myself, or ran the measurement myself.
- reported: a secondhand source, such as a README claim, issue comment, blog post, news story or forum answer.
- inferred: my own reasoning from verified or reported facts.

Downloaded sources are under `/tmp/gbim-research/realtime/`. I only read them and never executed them. My own scripts are in `/tmp/gbim-research/realtime-scripts/`. I did not open anything under `~/Library/Messages`. I used the schema dump at `research/chatdb-schema.sql` instead. I did not run `grok`, because a run reads `~/.grok/auth.json` and writes session files under `~/.grok`. I ran `log stream` only with a predicate that matches no process, so it could not print Messages metadata.

| Source | Local copy | Revision |
|---|---|---|
| openclaw/imsg (MIT) | /tmp/gbim-research/realtime/imsg | 1bc0679, v0.21.0 |
| openclaw/openclaw, sparse checkout | /tmp/gbim-research/realtime/openclaw | a56ce37 |
| BlueBubblesApp/bluebubbles-server | /tmp/gbim-research/realtime/bluebubbles-server | 76d2b2e |
| photon-hq/imessage-kit | /tmp/gbim-research/realtime/imessage-kit | 20a1536 |
| anthropics/claude-plugins-official, external_plugins/imessage | /tmp/gbim-research/realtime/claude-imessage | b6041c7 |
| steve228uk/grok-bot-imessage | /tmp/gbim-research/realtime/grok-bot-imessage | 8fe13b8 |
| jeffhuber/grokbot-imessage-skill | /tmp/gbim-research/realtime/grokbot-imessage-skill | ccd12b9 |
| Grok Bot app bundle, extracted by a sibling task | /tmp/gbim-research/grokbot/app/dist | app 0.78.5 |
| grok CLI docs | ~/.grok/README.md, ~/.grok/docs/user-guide/ | installed copy |
| launchd.plist(5) extract | /tmp/gbim-research/realtime/launchd.plist.man.txt | this Mac |

## Summary

1. The best local detector is a kqueue watch on `chat.db`, `chat.db-wal`, `chat.db-shm` and their directory, backed by a `PRAGMA data_version` poll every 1 to 2 seconds. In my synthetic benchmark the watch found rows 55 ms after commit at p50 with a 50 ms debounce. imsg uses the same design. Its issue #126 shows that a watch with no poll can go silent after WAL rotation, so the poll is required.
2. A ROWID cursor is not enough on its own. Edits, unsends, delivery and read state change existing rows in place. The watcher also needs per-row change stamps.
3. Messages.app does not have to be open. imagent and IMDPersistenceAgent run as per-user agents and keep chat.db current while the app is closed.
4. Grok Bot 0.78.5 has no incoming-message trigger. Its iMessage worker answers pull queries and copies the whole database folder to a temp directory for each query. In my benchmark that copy cost about 290 times the CPU of a ROWID poll.
5. The free, local way to wake Grok is a long-lived `grok agent stdio` process driven over ACP, with one session per conversation and a short tool list. `grok -p --resume <id> --output-format json` is the fallback. Grok Bot routines accept a webhook trigger, but routines run in the cloud.
6. Put the safety rules in the process that holds Full Disk Access and sends messages, not in the model prompt. TCC follows the parent chain, so the agent should not run as a child of the process that holds Full Disk Access.

## 1. Incoming-message detection

### 1.1 What changes in chat.db

- `message.ROWID` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so new rows get increasing ids. (verified, chatdb-schema.sql)
- Edits set `date_edited`. Unsends set `date_retracted`. Both also change `message_summary_info`, and imsg reads its `otr` and `rp` keys to stamp edits and retractions. (verified, chatdb-schema.sql and /tmp/gbim-research/realtime/imsg/Sources/IMsgCore/MessageStore+Mutations.swift)
- Delivery and read state are columns on the same row (`is_delivered`, `is_read`, `date_read`, `date_delivered`). A ROWID cursor never sees those updates. (verified, chatdb-schema.sql)
- A row has an `is_finished` column, and partial indexes filter on `is_finished = 1`. A row can exist before it is complete, so a reader should be ready to revisit it. (verified for the column and indexes, chatdb-schema.sql; inferred for the reading rule)
- Schema triggers call functions such as `verify_chat` and `delete_attachment_path`. Only Apple's persistence code registers those functions, so a third-party writer would break the triggers. The integration must stay read-only. (verified for the trigger text, chatdb-schema.sql; inferred for the consequence)
- The database uses WAL journal mode with user_version 0. (reported; chatdb-schema.sql records neither)

### 1.2 Methods compared

| Method | Latency | CPU | Reliability | Used by | Label and source |
|---|---|---|---|---|---|
| Poll `MAX(ROWID)` on a timer | Half the interval on average. 1 s interval gave p50 510 ms, p95 933 ms | Lowest. 0.0034 s over 38.5 s at 1 s | Never goes silent. Misses edits, unsends and read state. A cursor kept only in memory loses messages on restart | Claude iMessage plugin (1 s), imessage-kit after a watch event | verified, my benchmark and claude-imessage/server.ts:127, :772 |
| Poll `PRAGMA data_version` on a persistent read-only connection | Same as above. 250 ms interval gave p50 139 ms, p95 230 ms | 0.009 s over 38.5 s at 250 ms | Changes on any commit by another connection, so it also catches in-place updates. It is local to one connection | imsg change version | verified, https://sqlite.org/pragma.html#pragma_data_version, imsg MessageStore+Mutations.swift:46 |
| kqueue vnode watch (`DispatchSource`, `O_EVTONLY`) on db, wal, shm and directory | p50 55 ms with 50 ms debounce. imsg default debounce is 250 ms | 0.0196 s over 38.5 s, 242 events for 120 rows | Events can be dropped or coalesced after sleep, under heavy I/O, or when sidecars rotate. Needs re-arming on inode change and a fallback poll | imsg | verified, my benchmark and imsg/Sources/IMsgCore/MessageWatcher.swift:20-23 |
| Node `fs.watch` on db and wal (FSEvents or kqueue under libuv) | Debounce plus query. BlueBubbles debounces 500 ms | Low | imessage-kit switches to a directory watch when the wal rotates and has no fallback poll. BlueBubbles adds a time-window poller | BlueBubbles, imessage-kit | verified, bluebubbles-server .../lib/MultiFileWatcher.ts:40, .../IMessageListener.ts:84, imessage-kit src/infra/db/watcher.ts |
| Copy db and sidecars to a temp folder per query | Same as the poll interval | Highest. 25 ms per copy and 0.994 s CPU over 39 polls on a 150 MB db | Safe, but it rereads the full database each time | Grok Bot 0.78.5 messages worker | verified, my benchmark and /tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs (`mkdtempSync(... "messages-mac-")`, `cpSync`) |
| `log stream` on imagent | Possibly sub-second | Negligible in my test. The `log` process used 0.01 s CPU in 20 s and logd's extra cost was too small to separate from its baseline | Depends on private log strings that change between releases, and message fields are redacted as private. Message content still has to come from chat.db | None of the projects I read | verified for CPU, /tmp/gbim-research/realtime-scripts/logstream_cost.sh; inferred for fragility |
| Distributed or Darwin notifications | Unknown | Unknown | I found no public notification name for incoming messages. IMCore exports `IMChatMessageReceivedNotification`, but it is an in-process notification for IMCore clients, and those clients need private imagent entitlements | None | verified for the export, /tmp/gbim-research/macos/imcore.exports; verified that Messages.app holds `com.apple.imagent.chat` and `com.apple.private.imcore.imdpersistence.database-access` (codesign on this Mac); inferred that third parties cannot use it |
| IMCore bridge injected into Messages.app | Event-driven, includes typing | Low | Needs SIP disabled. imsg ships it only as an advanced option | imsg `--bb-events` | verified, imsg/docs/advanced-imcore.md |

### 1.3 Benchmark details

The script is `/tmp/gbim-research/realtime-scripts/bench.py`, and results are in `/tmp/gbim-research/realtime/bench/result-*.json`. It builds a 150 MB WAL database, then a writer inserts 120 rows at random 50 to 600 ms gaps over 38.5 s. Every 25 rows it runs `wal_checkpoint(TRUNCATE)`, and every 40 rows it reconnects. Each reader mode measures the delay from commit to detection. The test used system Python 3.9.6 with SQLite 3.51.0. (verified)

| Mode | p50 | p95 | Max | CPU for the run |
|---|---|---|---|---|
| kqueue, 50 ms debounce, 5 s fallback | 55 ms | 55 ms | 56 ms | 0.0196 s |
| data_version every 250 ms | 139 ms | 230 ms | 255 ms | 0.009 s |
| data_version every 1 s | 496 ms | 948 ms | 1002 ms | 0.0034 s |
| MAX(ROWID) every 1 s | 510 ms | 933 ms | 995 ms | 0.0034 s |
| Copy snapshot every 1 s | 511 ms | 981 ms | 1008 ms | 0.994 s |

Limits of this test. It is synthetic, with a single writer and no iCloud sync. Real chat.db traffic includes bursts of hundreds of rows during sync and periods where Apple's own writer holds locks. (inferred)

### 1.4 Reliability cases

WAL checkpoints and sidecar rotation. A `TRUNCATE` checkpoint shrinks the wal in place, and a reopen can replace the file with a new inode. imsg compares the (device, inode) pair of each watched path and re-arms when it changes. Its fallback poll also re-arms the watches. (verified, imsg MessageWatcher.swift `refreshFileSources`) imsg's watch doc says macOS "sometimes drops or coalesces filesystem events, especially under heavy I/O, after sleep/wake, or when Messages rotates the WAL sidecars". (verified, imsg/docs/watch.md:148) Issue #126 reports a silent watch on a busy iCloud-synced chat.db. The reporter's workaround was a 15 s poll plus `touch chat.db`, which cut detection delay from about 3 minutes to 20 to 30 s. imsg 0.6.0 (2026-05-05) added "a lightweight polling fallback when macOS misses filesystem events". (reported, https://github.com/openclaw/imsg/issues/126; verified, imsg/CHANGELOG.md:543-546)

Long read transactions. SQLite says "a long-running read transaction can prevent a checkpointer from making progress", and if readers never let go "the WAL file will grow without bound". A reader of chat.db should run each query in its own short transaction and never hold one open while it waits. (verified, https://sqlite.org/wal.html; inferred for the rule)

Read-only access. A read-only WAL reader works when the -shm and -wal files already exist and are readable, or when it can create them. (verified, https://sqlite.org/wal.html) imsg opens with `readonly: true` and a 5 s busy timeout. It does not use `immutable=1`, because "immutable handles can miss WAL-backed updates". (verified, imsg/Sources/IMsgCore/MessageStore.swift:27-28 and imsg/docs/permissions.md:23) In my test the -wal and -shm files stayed on disk after the last connection closed, although SQLite deletes them "usually". That suggests Apple's SQLite keeps WAL files by default. Either way, imagent keeps chat.db open, so the sidecars exist in practice. (verified for my test and the SQLite text; inferred for Apple's default)

Sleep and wake. Timers and kqueue do not fire during sleep. After wake, Messages may write a large backlog at once. (inferred) OpenClaw calls this the "backlog bomb" that Apple can flush after a Push recovery. It suppresses any live row whose send date is more than about 15 minutes older than its arrival. (verified, openclaw/docs/channels/imessage/messaging.md:28-32) launchd's `StartInterval` skips intervals missed during sleep, so it is the wrong tool for a watcher. (verified, launchd.plist.man.txt:348-353)

Messages.app not running. On this Mac `ps` showed imagent, IMDPersistenceAgent, identityservicesd and apsd running while Messages.app was closed. imagent's launchd plist has `KeepAlive {SuccessfulExit false}` and Mach services including `com.apple.aps.imagent` and `com.apple.madrid-idswake`, which receive push traffic. (verified, `plutil -p /System/Library/LaunchAgents/com.apple.imagent.plist`) Incoming messages therefore land in chat.db with the app closed. Sending through AppleScript does need Messages.app, which launches on demand. (verified for the agents; inferred for the send path)

Restart and downtime. OpenClaw keeps a persisted rowid cursor, passes it to imsg as `since_rowid`, and journals each raw row by Apple GUID before it moves the cursor. A completed GUID leaves a tombstone for about 4 hours, capped at 10,000 entries. If the saved cursor cannot be read, startup fails instead of silently skipping messages. (verified, openclaw/docs/channels/imessage/messaging.md:30-36) BlueBubbles instead re-polls from the last check time minus 30 s, capped at 24 hours. (verified, bluebubbles-server .../IMessageListener.ts:89-104) The Claude plugin and imessage-kit keep their cursor in memory only and start at MAX(ROWID), so anything that arrives while they are down is lost. (verified, claude-imessage/server.ts; imessage-kit src/infra/db/watcher.ts)

Rows with no chat yet. imsg retries a row whose chat id has not resolved up to 20 times, then drops it. On buffer overflow it reports a `resumeAfterRowID` so the caller can catch up. (verified, imsg MessageWatcher.swift:39-42, :88, :400-402)

### 1.5 Detection recommendation

- Watch the four paths with kqueue, debounce 250 ms, and re-arm on inode change. (inferred from 1.2 to 1.4)
- Keep one long-lived read-only connection and poll `PRAGMA data_version` every 1 s while idle. When it changes, run the row query even if no kqueue event arrived. (inferred)
- Run two queries per wake. One reads new rows with `ROWID > cursor`. The other reads recently changed rows by `date_edited`, `date_retracted`, `date_read` and `date_delivered` inside a short lookback window, as BlueBubbles does with its 30 s lookback. (inferred; BlueBubbles pattern verified)
- Persist the cursor and a GUID journal in a local SQLite file, and apply a 15 minute age fence to live rows after wake. (inferred, OpenClaw pattern verified)
- Use imsg's `IMsgCore` (MIT) instead of writing a new reader. It already handles typedstream `attributedBody` decoding, edits, unsends, attachments, the re-arm logic and the fallback poll. (verified for features, imsg/docs/watch.md and LICENSE; inferred for the choice)

## 2. Running as a LaunchAgent

### 2.1 Plist keys that matter

| Key | Behavior | Label and source |
|---|---|---|
| `KeepAlive` | `true` restarts the job whenever it exits. A dictionary with `SuccessfulExit false` restarts only after a nonzero exit, and `Crashed true` restarts only after a crash signal. `SuccessfulExit` implies `RunAtLoad` | verified, launchd.plist.man.txt:199-246 |
| `ThrottleInterval` | Default is 10 s between spawns. launchd wants jobs to "linger around" rather than respawn | verified, launchd.plist.man.txt:316-322 |
| `RunAtLoad` | Starts the job when it loads, at login for a per-user agent | verified, launchd.plist.man.txt |
| `ProcessType` | `Background` throttles CPU and I/O. `Standard` equals no value, which still applies "light resource limits". `Adaptive` follows XPC activity. `Interactive` should be reserved for app responsiveness | verified, launchd.plist.man.txt:474-501 |
| `WatchPaths` | "highly discouraged" and "highly race-prone", and modifications can be missed | verified, launchd.plist.man.txt:330-338 |
| `StartInterval` | Misses intervals that fall during sleep | verified, launchd.plist.man.txt:348-353 |
| `AssociatedBundleIdentifiers` | Ties a legacy plist to an app in the Login Items UI | verified, launchd.plist.man.txt:677-681 |
| Privacy note | "Specifying privacy sensitive files and folders in a launchd plist may not have the desired effect, and may prevent the job from running." | verified, launchd.plist.man.txt:684-687 |
| `AbandonProcessGroup` | By default launchd kills the job's process group when it dies | verified, launchd.plist.man.txt |

What the existing projects use:

- The jeffhuber skill's agent uses `WatchPaths` on a bridge request folder, `ThrottleInterval 1`, `ProcessType Background`, `KeepAlive false` and `RunAtLoad false`. It is an on-demand helper, not a watcher. (verified, /tmp/gbim-research/realtime/grokbot-imessage-skill/com.jeffhuber.grokbot-imessage.plist.template)
- imsg's bridge agent `org.openclaw.imsg.bridge.plist` checks the bridge every 300 s. Its docs note that LaunchAgents start only after login, so a headless Mac needs auto-login. (verified, imsg/docs/advanced-imcore.md)

Consequences for this project:

- Install the binary and any scripts outside `~/Documents`, `~/Desktop` and `~/Downloads`. Those folders are TCC-protected, and the man page warns that such paths can stop the job. `~/Library/Application Support/<name>/` works. (inferred from the man page)
- Run the watcher with `KeepAlive true`, `RunAtLoad true`, `ThrottleInterval 10` and `ProcessType Standard` (or no value). `Background` throttling could delay reactions. (inferred; not measured)
- Do not use `WatchPaths` or `StartInterval` for detection. (verified reasons above)

### 2.2 How TCC applies to a LaunchAgent

- TCC grants access based on the "responsible code" for a process. Apple DTS lists the cases. A tool run from Terminal or over SSH is attributed to the terminal app or sshd. A helper an app spawns is attributed to the app. For a launchd agent installed through `SMAppService`, the app is responsible. Otherwise the plist should include `AssociatedBundleIdentifiers`. DTS also says that for a launchd job, launchd is not the responsible code. (reported, https://developer.apple.com/forums/thread/756510, https://developer.apple.com/forums/thread/727396, https://developer.apple.com/forums/thread/732291)
- A bare binary run by a per-user LaunchAgent therefore needs its own Full Disk Access entry, and it cannot borrow the grant from Terminal. (inferred from the DTS answers; imsg says the same thing about parents, verified in imsg/docs/permissions.md:19)
- macOS "will follow the chain from child process to parent process" to decide responsibility, though the chain can break. Children of a process with Full Disk Access usually get that access too. (reported, https://developer.apple.com/forums/thread/805245; inferred for the consequence) This is the main reason the agent should not be a child of the process that holds Full Disk Access. If it were, the agent's shell tool could read all of `~/Library`.
- An ad-hoc signature pins the grant to the binary's cdhash, which changes on every rebuild, so each rebuild loses the grant. A stable signing identity (Developer ID, or a self-made code-signing certificate) keeps the designated requirement stable. (reported, https://github.com/amaldevice/kanso-dictate/issues/28) imsg says it ships "as a signed, notarized universal macOS binary". It also says grants can go stale after Homebrew or macOS updates, and the fix is to toggle the entry off and on. (reported, imsg/docs/install.md:6 and imsg/docs/permissions.md:100-104)
- macOS re-reads Full Disk Access only at launch, so the process must restart after a grant. (reported, imsg/docs/permissions.md:21)
- Sending through AppleScript needs a separate Automation grant for Messages, attributed to the same responsible process. (reported, imsg/docs/permissions.md:45)
- On October 2, 2026, Apple said Full Disk Access "largely sidesteps these controls". It said granting it will need "very explicit user action" and named AI agents as the reason. It gave no version, date or mechanism. (verified, https://developer.apple.com/news/?id=p6zjojqw) A self-installing repo cannot click the toggle for the user. The setup script should open the right System Settings pane, wait, and verify. (inferred)

### 2.3 Example watcher plist

```xml
<plist version="1.0"><dict>
  <key>Label</key><string>local.gbim.watchd</string>
  <key>ProgramArguments</key><array>
    <string>/Users/USER/Library/Application Support/gbim/bin/gbim-watchd</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Standard</string>
  <key>StandardErrorPath</key><string>/Users/USER/Library/Logs/gbim/watchd.err</string>
</dict></plist>
```

This is a sketch. Paths must be absolute, and the plist must not name chat.db or any protected folder. (inferred from launchd.plist.man.txt:684-687)

## 3. Waking Grok

### 3.1 grok CLI headless mode

All of the following comes from `~/.grok/docs/user-guide/14-headless-mode.md` unless noted. I read the docs but did not run the binary. (verified as documented)

- `grok -p "<prompt>"` runs one turn without the TUI. `--output-format` takes `plain`, `json`, `streaming-json` or `streaming-messages-json` (line 31).
- `-r/--resume <ID_OR_TITLE>` resumes a session and `-c/--continue` resumes the latest one in the current directory (lines 27-28). `-s/--session-id` now only creates a new session with a fresh UUID. The README still describes an older upsert behavior, but line 393 says "Older hidden `-s` upsert/resume behavior is gone".
- `--tools` is an allowlist and `--disallowed-tools` is a denylist (lines 36, 52). `--allow` and `--deny` rules "are always enforced" and include `MCPTool(server__*)` patterns. (verified, 22-permissions-and-safety.md:230-239)
- `--max-turns <N>` caps agent turns and only works headless (line 37).
- JSON output includes `sessionId`, `stopReason`, `usage` with `cache_read_input_tokens`, and `total_cost_usd` when known (lines 190-241).
- Without always-approve, a tool call that needs approval is refused and stderr prints "permission required: ... as a headless run cannot ask for approval" (line 589). Exit codes are 0, 1, 130 for SIGINT and 143 for SIGTERM (lines 661-668).
- A headless run waits up to 10 minutes for its own background work before it exits (line 632).
- "each headless run starts its own daemon" (line 643). A cold process and daemon start on every message is the cost of this route. I could not measure it. (verified for the statement; open question for the cost)
- Sessions live in `~/.grok/sessions/<encoded-cwd>/<session-id>/`, so the working directory decides where sessions are stored. (verified, 17-sessions.md:18-27)
- Config can turn off telemetry with `telemetry = false` or `GROK_TELEMETRY_ENABLED`, and memory is off by default (`memory.enabled` default false). (verified, ~/.grok/README.md:1382 and 26-config-reference.md:437-438)

### 3.2 ACP agent mode

- `grok agent stdio` speaks the Agent Client Protocol over stdin and stdout. The flow is `initialize`, then `session/new` with a working directory, then `session/prompt`, and the agent streams `session/update` notifications. "agent may request tool execution approval" unless the permission mode allows or denies the call. (verified, 15-agent-mode.md:101-104)
- `session/new` accepts `mcpServers` plus `_meta` fields `rules`, `systemPromptOverride`, `agentProfile`, `yoloMode` and `autoMode`. (verified, 15-agent-mode.md:207-222)
- "The agent persists all session updates automatically. Clients can reconnect and load previous sessions by ID" through `session/load`. (verified, 17-sessions.md:242-257)
- `grok agent serve --bind 127.0.0.1:2419 --secret <token>` offers the same protocol over WebSocket. (verified, 15-agent-mode.md:16, :80)
- ACP is an open protocol with SDKs for TypeScript, Rust, Python, Kotlin and Go. (reported, https://agentclientprotocol.com and https://www.npmjs.com/package/@agentclientprotocol/sdk)

One long-lived ACP process avoids a cold start per message and keeps each chat's history in its session, so a new message adds only its own tokens to the prompt. (inferred)

### 3.3 Hooks, monitor and scheduler

- Hooks include `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop`. `PreToolUse` can deny a tool call, and `UserPromptSubmit` can block a prompt. (verified, 10-hooks.md:92-112)
- Hooks fail open. A hook that cannot start or times out lets the call proceed, "even for a deny hook". (verified, 10-hooks.md:80, :116)
- `UserPromptSubmit` can block only prompts a person typed. "auto-wake turns (task and subagent completions, scheduler fires) and subagent sessions run the hook observe-only". (verified, 10-hooks.md:116) A hook is therefore not a reliable send gate for messages that arrive through auto-wake.
- The `monitor` tool turns each output line of a script into a notification in the conversation. It stops itself when a script emits too many events. (verified, 20-background-tasks.md:90-140) On the daemon route, `monitor` and the `scheduler_*` tools "have no daemon equivalent". (verified, 14-headless-mode.md:74-76) `/loop` and the scheduler have a 60 s minimum interval. (verified, 20-background-tasks.md:68)
- `features.auto_wake` controls whether background events wake the agent and defaults to true. (verified, 26-config-reference.md:260)

A monitor running `imsg watch --json` inside a grok session would work as a quick demo. It is a poor base for a service, because it lives and dies with one interactive session, it is unavailable on the daemon route, and hooks cannot block the turns it creates. (inferred)

### 3.4 What the Grok Bot app offers

- The 0.78.5 bundle has local iMessage tools. The `activity` call takes `since` and `until` and runs a query. I found no `fs.watch` and no chat.db-wal watch in the messages worker. (verified, /tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs)
- The worker checks each send by looking for a new from-me row with the same text after the send time. (verified, messages-worker.cjs function that calls `snapshotMessagesDb` and matches `fromMe` and `date`)
- Automations are stored server-side as `record_json` with a time zone. Enums include `GrokBotAutomationAction` and `GrokBotClientPresenceTrigger` (TYPING). (verified, /tmp/gbim-research/grokbot/app/dist/node-agent-coordinator/main.cjs protobuf names)
- The public docs list routine triggers for schedules, Slack, GitHub, Linear, Sentry, PagerDuty, email to the Bot's address and webhooks. A webhook is an HTTP POST with a Bearer key, and a `200` response means a run started. Routines run in the cloud, so they keep working while "your laptop is closed". iMessage is not mentioned. (verified, https://docs.x.ai/grok-bot/skills-routines-and-automations)
- Email that a routine or incoming message produces "waits as a draft until you press Send". Approval cards from background work expire after 30 minutes. "Text from somewhere else, such as an email or a web page, doesn't count as your request." In group chats "only the person whose message the Bot is answering can approve". (verified, https://docs.x.ai/grok-bot/approvals-security-and-privacy)
- After the October 23 mobile update, the official Grok Bot account replied that "iMessage is not part of this update". (reported, https://www.iphoneincanada.ca/2026/10/23/grok-bot-phone-apps-ios-android/)
- TestingCatalog reports a Grok Bot 1.0.0 build with a Texting tab in Settings and Messages read and send permissions. The tab held only a label. (reported, https://www.testingcatalog.com/spacexsi-prepares-texting-and-tasks-hub-support-for-grok-bot/)
- Community skills keep a person in the loop. steve228uk's skill calls imsg through ExternalShell and requires a tap on a confirm widget before every send. Its "quiet triage" runs on a coarse schedule, not a live watch. (verified, /tmp/gbim-research/realtime/grok-bot-imessage) jeffhuber's skill requires `send_preview`, then a one-time nonce bound to the recipient and body, then a native dialog with Cancel as the default button. It is text only. (verified, /tmp/gbim-research/realtime/grokbot-imessage-skill; reported, https://grokbot.dev/plugins/imessage/)

Today the only way to make Grok Bot react to an incoming iMessage on its own is a routine webhook. That sends the message text to a cloud run. (inferred from the sources above)

### 3.5 Patterns from OpenClaw and BlueBubbles

- The OpenClaw gateway spawns `imsg rpc` and speaks JSON-RPC over stdio. OpenClaw removed BlueBubbles support. (verified, openclaw/docs/channels/imessage.md) `imsg rpc` has "No TCP port. No launch agent." (verified, imsg/docs/rpc.md:74)
- OpenClaw can bind an iMessage chat to an ACP agent session (`/acp spawn codex --bind here`), so the ACP-per-chat design has a working precedent. (verified, openclaw/docs/channels/imessage/access-control.md)
- OpenClaw can merge consecutive messages from one sender into one turn, capped at 4,000 characters, 20 attachments and 10 entries. It is off by default. (verified, openclaw/extensions/imessage/src/monitor/coalesce.ts:6-8)
- BlueBubbles webhooks POST `{type, data}` with a 15 s timeout, no retry and no signature. Options include `blockPrivateAddresses`, `requireHttps` and `followRedirects`. (verified, bluebubbles-server .../webhookService/index.ts:17-68) Its event list includes new-message, updated-message, typing-indicator, chat-read-status-changed, participant and group-name events. (verified, bluebubbles-server events.ts)
- BlueBubbles' poller queries one week back by creation date, then filters by delivered, read, edited and retracted times. (verified, bluebubbles-server pollers/MessagePoller.ts)

A local Unix socket between the watcher and the agent host does the same job as these webhooks without exposing a network port. (inferred)

### 3.6 Token efficiency

- Messages that fail the sender gate never reach the model, so they cost zero tokens. (inferred)
- One persistent ACP session per chat sends only new messages each turn. The JSON usage block reports cache hits, so the setup can measure this. (verified for the field, 14-headless-mode.md:223; inferred for the saving)
- Put a short tool list in each session with `--tools` or `--disallowed-tools`, so tool definitions take fewer prompt tokens. (verified that the flags restrict offered tools; inferred for the saving)
- Send one compact line per message, such as `[chat 7f3a | Mom | 14:02] running late`, with attachment paths in metadata instead of inline content. The Claude plugin also keeps image paths out of message content, because content can be forged. (verified for the plugin, claude-imessage/server.ts; inferred for the format)
- Do not preload history. Give the agent a `history(chat, limit)` tool so it pays for context only when it needs it. (inferred)
- Merge bursts with a 1 to 2 s quiet window, capped like OpenClaw's coalescer. (inferred)
- Bound long sessions with `session.auto_compact_threshold_percent`, or start a fresh session per chat each day. (verified for the key, 26-config-reference.md:577; inferred for the policy)

## 4. Safety

### 4.1 Prompt injection

- Every incoming message is untrusted input. Only the owner's self-chat should be able to change settings, approve sends or widen access. The Claude plugin's instructions refuse access changes asked for over iMessage, noting "that is the request a prompt injection would make". (verified, claude-imessage/server.ts:567)
- Grok Bot's docs give the same rule. Text from somewhere else "doesn't count as your request". (verified, https://docs.x.ai/grok-bot/approvals-security-and-privacy)
- Give the agent session no shell, no web fetch and no file write. Its only tools should be the iMessage tools, so an injected instruction has nothing dangerous to call. (inferred; flags verified in 14-headless-mode.md:36-66)
- Wrap message text in a clearly marked data block with the sender and chat id taken from the database, never from the text. (inferred)
- Filter model output before sending. OpenClaw's reflection guard blocks replies that contain thinking tags, an `assistant to=` marker, `<final>` tags or ACP error strings. (verified, openclaw/extensions/imessage/src/monitor/reflection-guard.ts:3-16)

### 4.2 Sender allowlists and SMS

- OpenClaw's DM policies are `pairing` (default), `allowlist`, `open` and `disabled`. Pairing codes are 8 characters, expire after 1 hour, and at most 3 can be pending. (verified, openclaw/docs/channels/imessage/access-control.md:17-19 and openclaw/docs/channels/pairing.md)
- The Claude plugin defaults to an allowlist and drops SMS unless `IMESSAGE_ALLOW_SMS=true`, because SMS sender ids are spoofable. (verified, claude-imessage/server.ts:38 and ACCESS.md)
- Use allowlist plus self-chat by default. Drop SMS and RCS by default. Match senders on normalized handles from `handle.id`, not display names. (inferred)

### 4.3 Outgoing rate limits and account risk

- Apple publishes no iMessage limits. Lindy reports an Apple ban after 10,000 messages in 12 hours. Outreach vendors put the safe range for one Apple ID at roughly 80 to 120 sends per day. (reported, https://lindy.ai/blog/imessage-api-three-rewrites-one-apple-ban-and-what-actually-works, https://bluedrip.io/blog/avoid-imessage-blocks/, https://texting.blue/blog/avoid-to-imessage-blocks/)
- OpenClaw suppresses echo bursts at 5 hits per 60 s per conversation. (verified, openclaw/extensions/imessage/src/monitor/loop-rate-limiter.ts:6-7)
- Suggested defaults are at most 1 auto-reply per chat per 20 s, 30 per chat per day and 100 per Apple ID per day. Never start a conversation with a handle that has not messaged first unless the owner approves. Over the limit, the reply becomes a draft. (inferred)

### 4.4 Confirm before send

- Offer three modes. `draft` only writes suggestions. `confirm` asks the owner first. `auto` sends to allowlisted chats within limits. Default to `confirm`. (inferred)
- The Claude plugin approves with a self-chat reply that matches `^\s*(y|yes|n|no)\s+([a-km-z]{5})\s*$`. The code skips the letter l so it is not read as 1. (verified, claude-imessage/server.ts:60) This works from an iPhone. jeffhuber's native dialog only works at the Mac. (inferred)
- Bind each approval code to the exact recipient and body, as jeffhuber's nonce does, and let codes expire, as Grok Bot's 30 minute cards do. (verified, sources in 3.4; inferred for the combination)
- Enforce the gate in the watcher that performs the send. Do not rely on a grok hook, because hooks fail open and cannot block auto-wake turns. (verified for hook behavior, 10-hooks.md:80, :116; inferred for the placement)

### 4.5 Auto-reply loops

- Self-chat is the hardest case. The Claude plugin's comment says that in self-chat the `is_from_me=1` rows are empty sent receipts and the content arrives on an `is_from_me=0` copy, so it filters its own echoes by recent text within a 15 s window. (verified, claude-imessage/server.ts:432-456, :796-804) OpenClaw classifies self-chat with `chat_identifier` and `destination_caller_id`, drops from-me rows except in self-chat, and drops agent echoes in self-chat. (verified, openclaw/extensions/imessage/src/monitor/inbound-processing.ts) The two projects describe different row shapes, so this must be tested on macOS 26.2. (inferred)
- OpenClaw remembers its sent text for 12 hours, up to 256 entries, and keeps a 10 s self-chat cache of 512 entries. (verified, persisted-echo-cache.ts and self-chat-cache.ts:17-19)
- OpenClaw's bot-pair limit of 20 events per 60 s with a 60 s cooldown does not cover iMessage, because iMessage exposes no bot identity. (verified, openclaw/docs/channels/bot-loop-protection.md:23-25, :119)
- Record the GUID of every message the watcher sends and never feed those rows back to the model. Add a per-chat limit on consecutive bot turns with no human reply, such as 3, to stop two bots answering each other. (inferred)
- The Claude plugin appends "\nSent by Claude" to replies. A visible tag like this helps people and other bots recognize automated text, and the echo filter strips it before matching. (verified, claude-imessage/server.ts:39, :437) Make it optional here. (inferred)

### 4.6 Group chats

- OpenClaw's group allowlist runs two gates, `groupAllowFrom` for senders and then the `groups` registry. `requireMention` defaults to true, and each group can have its own `systemPrompt`. (verified, openclaw/docs/channels/imessage/access-control.md:31-115)
- The Claude plugin disables groups by default and opts each one in by chat GUID. (verified, claude-imessage/ACCESS.md:57-59)
- Default to ignoring groups. When a group is enabled, answer only when mentioned, answer only the sender who mentioned the bot, and never send to a group in `auto` mode without a per-group opt-in. (inferred)

### 4.7 Audit log and local content

- Append one JSON line per decision to `~/Library/Application Support/gbim/audit.jsonl` with mode 0600. Record the time, chat id, GUIDs, gate result, model session id, the proposed reply, the approval state and the send result. Log hashes, not text, unless the owner turns on full logging. (inferred)
- Keep the journal, cursor and logs on the Mac. Use no third-party relay, no open port and no webhook by default. The model itself runs on xAI's servers, so the text of any message passed to Grok leaves the Mac. Only messages that pass the gate should be sent. (inferred) Turn off grok telemetry in the project config. (verified for the setting, ~/.grok/README.md:1382)
- A Grok Bot webhook routine would send message text to a cloud run under Cursor's terms. Make it opt-in. (verified that routines run in the cloud and retention follows Cursor's terms, docs.x.ai pages in 3.4; inferred for the policy)

## 5. Proposed architecture

### 5.1 Components

1. `gbim-watchd`. A small Swift binary that links imsg's `IMsgCore`, is signed with a stable identity, and lives in `~/Library/Application Support/gbim/bin/`. It is the only process with Full Disk Access and Automation for Messages. It runs as a LaunchAgent with `KeepAlive`. It detects messages, normalizes them, applies policy, journals them, sends replies and verifies sends. It serves a Unix socket at `~/Library/Application Support/gbim/run/watchd.sock` with mode 0600 and makes no network connections. (inferred)
2. `gbim-host`. A second LaunchAgent with no Full Disk Access. It reads events from the socket and runs one `grok agent stdio` child. It maps each allowed chat to an ACP session id stored in its own state file, and uses `session/load` after restarts. Its working directory is `~/Library/Application Support/gbim/agent/`, which holds the rules file and grok config. (inferred)
3. `gbim-mcp`. A stdio MCP server that `gbim-host` passes in `session/new`. It exposes `history`, `search`, `chat_info`, `draft_reply` and `send_reply`, and proxies each call to the watcher socket. `send_reply` returns `sent`, `queued_for_approval`, `rate_limited` or `blocked`. The model never sees a raw send path. (inferred)
4. Policy file. `policy.toml` holds the allowlist, the mode per chat, rate limits, group settings, the signature setting and quiet hours. Only the owner edits it, and only in a file or from self-chat with an approval code. (inferred)
5. Optional `grokbot-skill`. A Grok Bot skill that calls the same socket through a short CLI, so the Grok Bot app gets reads and confirmed sends without a second reader. (inferred; skill pattern verified in 3.4)

Why two processes. If grok were a child of the process holding Full Disk Access, TCC would likely treat it as covered by that grant, and so would every shell command it runs. Splitting the processes leaves grok with normal user permissions. (inferred from https://developer.apple.com/forums/thread/805245)

### 5.2 Data flow

1. imagent commits a row to chat.db. A kqueue event or the 1 s `data_version` check wakes `gbim-watchd`.
2. The watcher waits 250 ms for writes to settle, reads rows after the cursor and recently changed rows, and resolves chat, handle, service, attachments and thread fields.
3. It drops from-me rows, its own echoes by GUID and text, rows older than the age fence, SMS by default, senders outside the allowlist, and group messages without a mention.
4. It writes each surviving row to the journal by GUID, advances the cursor in the same transaction, and pushes a compact event on the socket.
5. `gbim-host` merges bursts per chat, then sends `session/prompt` to the chat's ACP session with only the new lines.
6. Grok calls `send_reply` through `gbim-mcp`. The watcher checks the mode, rate limits and loop counters.
7. In `auto` mode the watcher sends through AppleScript or `imsg send`, then confirms the outgoing row by GUID. In `confirm` mode it texts the owner's self-chat with a code, waits up to 30 minutes, and sends after a matching `yes CODE` reply.
8. The watcher writes an audit line for each step.

### 5.3 Latency budget

| Step | Estimate | Label and source |
|---|---|---|
| Push arrival to chat.db commit | Not measured, controlled by Apple | inferred |
| Commit to watcher read | 0.06 to 0.3 s with a 50 to 250 ms debounce. Up to 1 s when only the poll catches it | verified for the benchmark, inferred for chat.db |
| Policy check and journal write | Under 10 ms | inferred |
| Burst window | 0 to 2 s, configurable | inferred |
| Grok turn on a warm ACP session | Not measured. Expect a few seconds for a short reply | inferred |
| Cold `grok -p` start | Not measured. Each run starts its own daemon | verified for the statement, 14-headless-mode.md:643 |
| AppleScript send and row check | imsg waits up to 8 s for the outgoing row. Typical time not measured | verified, imsg/docs/send.md:104-108 |

A warm path should reply in about 3 to 10 s from arrival, mostly model time. (inferred)

### 5.4 Failure handling

| Failure | Detection | Response | Label |
|---|---|---|---|
| Watch goes silent after wal rotation or sleep | `data_version` changed with no kqueue event | Run the query and re-arm all watches | inferred, imsg pattern verified |
| Backlog flush after wake | Row send date more than 15 minutes before arrival | Journal it but do not wake the agent. Add it to a digest for the owner | inferred, OpenClaw pattern verified |
| Watcher crash | launchd exit status | `KeepAlive` restart after `ThrottleInterval`. Resume from the persisted cursor, and the GUID journal drops repeats | inferred |
| Cursor or journal unreadable | SQLite error at start | Refuse to start auto-replies and alert the owner once. Do not reset to MAX(ROWID) | inferred, OpenClaw rule verified |
| Full Disk Access missing or stale | Opening chat.db fails with an authorization error | Stay alive, report status on the socket, retry every 60 s, and tell the user to toggle the entry off and on | inferred, imsg advice reported |
| Automation denied | AppleScript error -1743 | Switch to draft mode and notify the owner | inferred |
| grok process exits or auth expires | Child exit or ACP error | Restart with backoff from 1 s up to 5 minutes. Keep events queued in the journal. After 3 failures, send one self-chat notice | inferred |
| Send result unknown | No outgoing row within 8 s | Mark it `may_have_completed` and never retry automatically, because a retry can send twice | verified for imsg's behavior, imsg/docs/send.md:104-108; inferred for the rule |
| macOS 26 ghost row | Empty unjoined outgoing SMS row | Report the failure, do not retry, and notify the owner | verified for imsg's check, imsg/docs/send.md:115-120 |
| Loop or rate limit hit | Counters in the watcher | Mute the chat for a cooldown and keep replies as drafts | inferred |
| Mac asleep or logged out | No events | Nothing is lost. LaunchAgents start only after login, so a headless Mac needs auto-login | verified for the login note, imsg/docs/advanced-imcore.md |

### 5.5 Feature coverage beyond existing repos

| Feature | How | Label |
|---|---|---|
| New messages, edits and unsends as separate events | Cursor plus change stamps, as imsg does | verified for imsg, inferred for this design |
| Delivered and read events for the bot's own sends | Lookback query on `date_delivered` and `date_read` | inferred |
| Replies in threads | `thread_originator_guid` is indexed | verified, chatdb-schema.sql:43 |
| Tapbacks | Read from `associated_message_type`. Sending uses imsg `react` UI automation, which has limits | verified, chatdb-schema.sql and imsg/docs/send.md:130-140 |
| Attachments | Paths in metadata, and the agent asks for the file only when needed | inferred |
| Typing indicators | Only with the IMCore bridge, which needs SIP disabled. Leave it off | verified, imsg/docs/advanced-imcore.md |
| Restart without losing messages | Persisted cursor and GUID journal | inferred, OpenClaw pattern verified |

## 6. Open questions

- How long a cold `grok -p --resume` and a warm ACP `session/prompt` take, and how many prompt tokens a resumed session sends. I did not run grok.
- Whether TCC on macOS 26.2 credits Full Disk Access to a plain LaunchAgent binary on its own, without `SMAppService` or `AssociatedBundleIdentifiers`.
- Whether children of the watcher really inherit its Full Disk Access on macOS 26.2. The two-process design assumes they do.
- What Apple's announced Full Disk Access change will require from self-installed agents, and when it ships.
- What self-chat rows look like on macOS 26.2, given that the Claude plugin and OpenClaw describe them differently.
- Whether Grok Bot 1.0.0 ships native texting or an incoming-message trigger. That would change the wake-up design.
- Whether `grok agent stdio` uses the shell route or the daemon route, which decides whether `monitor` and the scheduler exist in those sessions.
- How chat.db behaves under a large iCloud sync burst on this Mac. The benchmark was synthetic.
