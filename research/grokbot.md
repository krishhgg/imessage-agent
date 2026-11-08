# Grok Bot desktop app: iMessage tools, extensions, Shell, wake paths and limits

Date: 2026-11-05. Target: the Grok Bot desktop app installed at `/Applications/Grok Bot.app`, version 0.79.2.

## Method and citation format

I read the app without running it or changing it. I extracted `app.asar` read-only into `/tmp/gbim-research/grokbot/app` and searched the minified bundles with small Python scripts run with `-I`. I dumped strings from the Swift helper binary into `/tmp/gbim-research/grokbot/cu-strings.txt`. I did not open `~/Library/Messages`, `~/.grok/auth.json`, keychains, or any credential file, and I did not send any message.

Citation shorthand used below:

- `asar:<file>@<n>` means the file inside `/Applications/Grok Bot.app/Contents/Resources/app.asar` (extracted copy under `/tmp/gbim-research/grokbot/app/`), at character offset `n` of the minified file.
- `helper-strings:<line>` means line `<line>` of `/tmp/gbim-research/grokbot/cu-strings.txt`, which holds `strings` output of `/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app/Contents/MacOS/CUGrokBotService`.
- Status labels: **verified** means I read the code or file myself. **reported** means a secondhand source such as a README or issue. **inferred** means my conclusion from verified facts, not directly shown.

## Summary

1. The model runs on xAI and Cursor servers, not on the Mac. The Mac runs a "local-exec daemon" that long-polls the backend and executes frames such as `exec` (shell), `upload`, `download`, `messages-op` and `local-tool`. The model-facing tool descriptions and JSON schemas for `SearchIMessages`, `SendIMessage` and the rest are not in the app. Only the tool names and the wire format of the Messages operations are local.
2. The built-in iMessage tools are text-only. They can find chats, read pages of a chat, search, summarize activity, fetch one attachment, look up contacts, and send text to a phone number, an email, or a chat id (which covers group chats). They cannot send files, tapbacks, replies to a specific message, edits, unsends, typing indicators, or read receipts.
3. Full Disk Access, Automation and Contacts for the built-in tools belong to the bundled helper app `co.anysphere.grok-bot-computer-use`, not to Grok Bot itself. The helper's RPC socket checks the caller, so third-party code is likely refused.
4. A `Shell` tool runs commands on the Mac through the local-exec daemon, with no sandbox (`insecure_none`), in the user's login shell, with the home directory as root. The daemon is a child of the Grok Bot executable, so TCC treats Grok Bot.app as the responsible app for anything Shell runs. Grok Bot.app has the Apple Events entitlement but no `NSAppleEventsUsageDescription`, which other Electron apps show leads to silent `-1743` refusals.
5. Custom MCP servers are stored in the user's Cursor account. Stdio servers run in the bot's cloud Linux "box", not on the Mac. Plugins install only by marketplace `plugin_id`. Skills are stored server-side per bot and the bot can write them with `UpdateSkill`.
6. Grok Bot does not react to incoming iMessages by itself. I found no watcher on `chat.db`, and the routine trigger types have no iMessage option. The usable wake path is a routine with a `webhook` trigger: an external watcher can `POST` to `<backend>/automations/webhook/<automationId>` with a bearer key and a JSON `context` string. The `grokbot://app/v1/prompt` deep link only prefills the composer and never sends.
7. A single Messages or local-tool result over 8 MiB of JSON becomes an error. Message pages cap at 64,000 JSON characters, and attachments travel as inline base64, so the effective attachment limit is about 6 MiB, not the 100 MiB that the worker allows.

## App facts

- Bundle id `com.anysphere.sand`, version 0.79.2, URL schemes `grokbot` and `sand`, `NSAllowsLocalNetworking` set. (verified, `/Applications/Grok Bot.app/Contents/Info.plist`)
- Grok Bot.app entitlements are `com.apple.security.automation.apple-events`, `com.apple.security.cs.allow-jit`, `com.apple.security.device.audio-input` and `com.apple.security.device.camera`. It is not App Sandboxed. (verified, `codesign -d --entitlements - "/Applications/Grok Bot.app"`)
- Grok Bot.app's Info.plist has usage strings for audio capture, Bluetooth, camera and microphone only. It has no `NSAppleEventsUsageDescription`. (verified, `/Applications/Grok Bot.app/Contents/Info.plist`)
- The helper app `Grok Bot Computer Use.app` (bundle id `co.anysphere.grok-bot-computer-use`) ships in `Contents/Helpers`, is copied to `~/.grokbot/computer-use/`, and is launched with `open -g`. Its Info.plist carries the Accessibility, Apple Events, Calendars, Contacts, Location, Reminders and Screen Capture usage strings, and `LSMinimumSystemVersion` is 14.0. (verified, `/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app/Contents/Info.plist`, `asar:dist/local-exec-daemon/messages-worker.cjs@2347` and `@5702`)
- The local data root for the production app is `~/.grokbot`. Dev and lab builds use `~/.cursor/sand*`. Overrides are `SAND_DATA_ROOT` and `SAND_USER_DATA_DIR`. (verified, `asar:dist/electron-main/main-core.cjs@359321`)
- File names (not contents) in `~/.grokbot`: `.grokbot-data-root-v1`, `attachment-staging`, `computer-use/`, `local-computer-use-gate.json`, `local-exec-backend-return.json`, `local-exec-daemon-connection.json`, `local-exec-daemon-credential.json`, `local-exec-daemon.json`, `local-exec-daemon.log`, `local-exec-supervisor.json`, `mac-device-tools-gate.json`, `settings.json`. (verified, directory listing)
- File names in `~/Library/Application Support/Grok Bot` are the usual Chromium directories plus `box-secrets-push-state.v1.json`, `desktop-status.json`, `plugin-logo-cache`, `sand-client-persistence`, `sand-secrets.json`, `sand-statsig-bootstrap.json`, `sentry`, `window-state.json`, and a `SingletonSocket` symlink. `~/Library/Application Support/grok-bot-computer-use` holds `lifecycle-debug.log`, `overlay-debug.log` and `service.lock`. (verified, directory listing)
- A `~/terminals` directory with 7 entries exists, which matches the executor's `terminalsFolder = <root>/terminals` with root set to the home directory. I did not read it. (verified, `ls -ld ~/terminals` and `asar:dist/local-exec-daemon/main.cjs@3075986`)

## (a) Built-in iMessage tools

### How a call flows

- The server sends a `GrokBotUserComputerMessagesOp` frame with `op_json`, an optional `approval_id`, an optional `send_key`, an optional `draft_card` flag and `authorized_by_approval`. Results come back as `result_json` plus `daemon_ms`, `helper_ms` and `sqlite_ms` timings. (verified, `asar:dist/electron-main/proto.cjs@1267816`)
- The daemon validates the op, runs it in `messages-worker.cjs`, and the worker talks to the helper over a unix socket. The socket path is in `~/Library/Application Support/grok-bot-computer-use/service.json`. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@2347`)
- Every read op first asks the helper to copy `chat.db` to a temp directory (`snapshot-messages-db`). The worker then opens the copy read-only with `node:sqlite`. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs` near the `cpSync(... "chat.db")` call, and `helper-strings:12746`)
- The helper rejects callers it does not admit, with error `peer_not_permitted`. The binary contains the Anysphere team id, so code signed by someone else is likely refused. (verified string, `helper-strings:9907`; refusal of third parties is inferred)

### Tool names and the op each one likely uses

The app lists these iMessage-related tool names: `CheckIMessagePermissions`, `FindIMessageChats`, `SearchIMessages`, `IMessageActivity`, `FetchIMessageAttachment`, `FindContacts`, `SendIMessage`, `ChatItems` and `DraftExternalMessage`. (verified, `asar:dist/local-exec-daemon/main.cjs@1962516`)

The op kinds on the wire are `check-permissions`, `find-contacts`, `find-chats`, `items`, `search`, `activity`, `fetch-attachment` and `send`. Reads need Full Disk Access and `send` needs Automation. (verified, `asar:dist/local-exec-daemon/main.cjs@1993002`)

The mapping from tool name to op kind is inferred from the names. `ChatItems` most likely maps to `items`. `DraftExternalMessage` most likely produces the `GrokBotIMessageDraft` card, which has `to`, `chat_id`, `recipient_name`, `body`, `machine_id`, `approval_id` and `server_approved`. (inferred; draft proto verified at `asar:dist/electron-main/proto.cjs@1234838`)

The tool descriptions and schemas the model sees are server-defined. The renderer only maps tool names to UI labels such as "Messaging". (verified absence of local descriptions, `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@1184409`)

### Op parameters

All verified at `asar:dist/local-exec-daemon/main.cjs@2307034` unless noted.

| Op | Parameters |
| --- | --- |
| `send` | `text` (required), `service` optional, one of `iMessage`, `SMS`, `auto`, plus either `to` (phone or email) or `chatId` |
| `find-chats` | `displayName?`, `handle?`, `limit?` (integer, at least 1) |
| `items` | `chatGuid?`, `limit?`, `before?` as `{date, id}` cursor |
| `search` | `needle`, `limit?`, `before?` |
| `activity` | `since`, `until?` |
| `check-permissions` | none |
| `fetch-attachment` | `messageGuid`, `attachmentGuid` |
| `find-contacts` | `query` (trimmed, at least 1 character) |

### Op results

All verified at `asar:dist/local-exec-daemon/main.cjs@2308932` and the schema block just before it.

- `find-chats` returns `chats[]` with `id`, `guid`, `identifier`, `displayName?`, `service`, `handles[]` and `lastDate?`, plus `total?`, `truncated?` (`"limit"` or `"bytes"`) and `people?`, a map from handle to contact name.
- `items` and `search` return `items[]` and a `nextBefore` cursor. A message item has `id`, `guid`, `chatGuid`, `date`, `fromMe`, `handle?`, `service`, `body` (`text`, `runs[]` with optional mention and part info, `fallback`, `edit`), `replyToGuid?`, `threadOriginatorGuid?`, `tapbacks[]` (`type`, `emoji?`, `handle?`, `fromMe`, `date`), `attachments[]` (`id`, `guid`, `filename?`, `transferName?`, `mime?`, `uti?`, `totalBytes?`), `edited?` and `unsent?`. An event item has `itemType`, `groupActionType?`, `groupTitle?` and `handle?`.
- `activity` returns `items[]` of `{chatGuid, count, handles?, displayName?}`.
- `send` returns `text`, `service`, `via`, `verified`, and `to` or `chatId`.
- `check-permissions` returns `version`, `verbs[]`, `fullDiskAccess`, `automation` (`granted`, `notAsked` or `denied`), `contacts` and `turnedOff?`.
- `fetch-attachment` returns `filename`, `mime` and `bytesBase64`.
- `find-contacts` returns `region?`, `total`, `truncated?` and `contacts[]` with `name`, `phones[]`, `unresolvedPhones?` and `emails[]`.

### Read behavior

- `items` defaults to 50 and caps at 200. `search` defaults to 25 and caps at 100. `find-chats` defaults to 50 and caps at 500. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@9351`)
- A page stops when its JSON reaches 64,000 characters, and the result is marked `truncated: "bytes"`. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@9445`)
- `find-contacts` returns at most 25 contacts, and name resolution for `people` covers at most 200 handles. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@111788`)
- The message query reads tapbacks (`associated_message_type`), edits, unsends (`date_retracted`), thread and reply ids, and group events. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@103950` and `@106577`)
- Search lowercases and uses `instr` on `m.text`, and for ASCII needles also on `CAST(attributedBody AS TEXT)`. This is a substring scan, not full-text search. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@105702`)
- HEIC attachments are converted to JPEG with `sips` before return. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@927`)
- The helper only copies attachments that sit inside the Messages directory (`attachment_outside_messages`, `attachment_not_a_file`). (verified, `helper-strings:12781`)

### Send behavior, chat ids and group chats

- `chatId` must match `^[A-Za-z0-9._@;+-]+$`. `to` must be a phone number or an email address. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@109615`)
- A `chatId` starting with `SMS;` or `any;` is sent over SMS. Any other `chatId` is sent over iMessage. With `to` and `service: "auto"`, the worker tries iMessage and falls back to SMS when the address fails. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@111099`)
- The worker writes the text to a temp file with mode 0600 under `messages-mac-send-*/body.txt`. The helper reads it as UTF-8 in AppleScript and runs either `send targetText to chat id "<id>"` or `send targetText to participant "<handle>" of targetService`. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@110872`, `helper-strings:12771` and `helper-strings:12776`)
- Group chats work by `chatId`. When `to` is absent, the approval descriptor marks the target as a group chat. Chat ids come from `find-chats` results (`guid` or `identifier`). (verified, `asar:dist/local-exec-daemon/main.cjs@2309650`; use of `find-chats` output as `chatId` is inferred)
- After sending, the worker takes a fresh database snapshot and looks for a `fromMe` message with the same text sent after the send started. The result field `verified` reports this, and an unconfirmed send maps to `messages_send_unconfirmed`. (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@109972` and `@116028`)
- AppleScript errors map as `-1743` to `messages_automation_denied`, `-1728` and `-1700` to `messages_addressing_failed`, and `-1712` to "not responding". (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@116028`)
- Sends deduplicate on `sendKey`, so a retried frame replays the earlier result instead of sending twice. (verified, `asar:dist/local-exec-daemon/main.cjs@3077756`)
- The helper has no AppleScript for sending files, tapbacks, threaded replies, edits or unsends. The only send verbs are the two text forms above. (verified, `helper-strings:12746` to `12790`)
- Messages.app's own scripting dictionary accepts a file as the direct parameter of `send`, so attachment sending is possible outside Grok Bot. (verified, `research/messages.sdef` lines 55 to 60)

### Approvals

- Local tool actions are `run-command`, `send-input`, `read-file`, `list-directory`, `write-file`, `read-ai-tool-setup`, `read-messages`, `send-imessage`, `run-phone-tool`, `use-app` and `send-mail`. Permission levels are `always`, `ask` and `never`. (verified, `asar:dist/local-exec-daemon/main.cjs@2002678`)
- `read-messages` is scoped by a setting, `send-imessage` is scoped per subject (recipient), and `run-command` is global. A standing "always" grant for `run-command` therefore covers every shell command. (verified, `asar:dist/local-exec-daemon/main.cjs@2002678`)
- A `send` without an `approval_id` goes through `decideLocalUse`, which shows a consent card and returns `messages-accepted` and then `messages-consent-result`. (verified, `asar:dist/local-exec-daemon/main.cjs@3077756`)
- The approval card shows the recipient and the text, and offers "Later messages to {recipient} from this computer won't ask for approval". The app can list and revoke these allowed recipients. (verified, `asar:dist/renderer/assets/chunk-send-imessage-approval-CA6ZjvsV.js@5464`)
- When Messages is turned off, the daemon tells the model to send the user to Connect Apps, then Mac, then Messages. (verified, `asar:dist/local-exec-daemon/main.cjs@1993762`)

### Timeouts and rate limits

- The daemon allows 180,000 ms for `send` and 30,000 ms for other ops. The worker gives the helper 150,000 ms for `send-message`, 4,000 ms for `resolve-handles` and 10,000 ms for other verbs. (verified, `asar:dist/local-exec-daemon/main.cjs@2310655` and `@2310710`, `asar:dist/local-exec-daemon/messages-worker.cjs@116557`)
- I found no local rate limit on sends. Any limit would be server-side. (verified absence in `messages-worker.cjs` and the Messages path of `main.cjs`; server behavior unknown)

## (b) Extensions: MCP, plugins, skills, rules

### MCP servers

- The MCP config shape is `{mcpServers: {name: {command?, args?, env?, url?, headers?, cwd?, envFile?, auth?, enabledTools?, placement?, tls?}}}`, where `placement` is `"server"` or `"client"`. I found no consumer of `placement`. (verified, `asar:dist/local-exec-daemon/main.cjs@2636284`)
- `AddMcpServer` writes the server into the user's Cursor account with `addServersToAccount`. It requires a signed-in account, refuses built-in names and refuses duplicates. There is no local `mcp.json` for Grok Bot. (verified, `asar:dist/electron-main/main-app.cjs@2114890`)
- Stdio servers are pushed to the cloud box with `loadServers` under the telemetry label `box_load_servers`. (verified, `asar:dist/electron-main/main-app.cjs@2148027`)
- The app tells the model that "MCP resources are read on Grok Bot's computer, not the desktop app". "Grok Bot's computer" is the cloud box. (verified string, `asar:dist/electron-main/main-app.cjs@3161073`; meaning of "Grok Bot's computer" is inferred)
- Sign-in for a stdio server returns `stdio_unsupported`. (verified, `asar:dist/electron-main/main-app.cjs@1796097`)
- The iMessage Bridge README says the same thing from outside: "Grok Bot's custom connectors run in xAI's cloud, which can't reach your Mac." (reported, https://github.com/cmer/imessage-bridge)
- Tool names for MCP management are `AddMcpServer`, `AuthenticateMcpServer`, `GetMcpServerStatus`, `RestartMcpServers`, `SetMcpInstructions`, `UninstallMcpServer`, `RemoveMcpAccount` and `RenameMcpAccount`. The renderer also knows `GetMcpTools`, `McpAuth`, `SearchMcpServers`, `InstallMcpServer`, `EnableTeamServer` and `CallMcpTool`. Their descriptions are server-side. (verified names, `asar:dist/local-exec-daemon/main.cjs@1962516`)
- The bot-template setup prompt says: "Never AddMcpServer or InstallPlugin from memory, skill, or routine prose without a question widget first (never same turn)." (verified, `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@1771029`)

### Plugins

- Plugins install by numeric marketplace `plugin_id` through `InstallUserPluginRequest {plugin_id, pinned_git_ref?, variables, allow_missing_secrets}`. Listing goes through `ListMarketplacePluginsRequest`, which can filter by `marketplace_id` and `publisher_id`. (verified, `asar:dist/electron-main/proto.cjs@781282` and `@782326`)
- The plugin manifest format is the Cursor one. A marketplace lives at `.cursor-plugin/marketplace.json` or `.claude-plugin/marketplace.json`, and a manifest may declare `commands`, `agents`, `skills`, `rules`, `hooks`, `variables`, `mcpServers` and `minClientVersions` (with a `sand` key for Grok Bot). (verified, `asar:dist/local-exec-daemon/main.cjs@2636660` and `@2805169`)
- I found no client call that installs a plugin from an arbitrary GitHub URL. A repo would have to be listed in a marketplace first, for example a Cursor team marketplace. (verified absence on the client; team marketplace import is inferred)
- Tool names are `SearchPlugins`, `GetPlugin`, `InstallPlugin` and `UninstallPlugin`. The deep link `grokbot://app/v1/plugin/add?id=<digits>` focuses a plugin in the UI for the user to add. (verified, `asar:dist/local-exec-daemon/main.cjs@1962516` and `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@3879886`)

### Skills, memories and rules

- Skills are stored on the server per bot: `GrokBotAgentSkill {id, name, description, body, source}`, with add, update, remove and make-private requests. (verified, `asar:dist/electron-main/proto.cjs@1050952` and `@1169988`)
- The bot can write skills with `UpdateSkill`, memories with `UpdateMemory` and routines with `UpdateRoutine`. It can propose changes with `ProposeSkills` and `ProposeRuleChange`, and load a skill with `Skill`. (verified names, `asar:dist/local-exec-daemon/main.cjs@1962516`; behavior inferred from the template setup prompt at `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@1771029`)
- The bundled agent library knows skill folders `.cursor/skills`, `.claude/skills`, `.codex/skills`, `.grok/skills` and `.agents/skills`, plus `.cursor/rules`. I found no daemon path that loads them for Grok Bot. The executor only registers shell, background shell, read and write. (verified list at `asar:dist/local-exec-daemon/main.cjs@2805169` and executor at `@3007233`; that Grok Bot ignores these folders is inferred)
- The `discover-ai-tool` frame reads only Claude Code (`~/.claude.json` and its plugins, skills and commands) and Codex (`~/.codex`). It returns at most 40 items with 160-character titles, and it redacts tokens, emails and URLs. It needs the `read-ai-tool-setup` permission. (verified, `asar:dist/local-exec-daemon/main.cjs@2304500` and `@2315817`)
- I found no handling of `AGENTS.md` in the Grok Bot bundles. (verified absence by search; server-side behavior unknown)
- Bot templates bundle routines, plugins, memories and skills and share as `grokbot://app/v1/bot-template?id=<21 chars>`. Importing a template runs a setup prompt that creates routines paused and asks one question before installing plugins. (verified, `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@178293` and `@1771029`)

### Can the bot install from a GitHub repo on its own?

- Through Shell, yes, after approval. It can `git clone` onto the Mac and run an installer, because Shell runs unsandboxed on the Mac. (inferred from the Shell findings below)
- It can save usage instructions as a skill with `UpdateSkill` and create a webhook routine with `UpdateRoutine`. (inferred from tool names and the template prompt)
- It cannot install a plugin from a raw repo URL, and an MCP server it adds would run in the cloud, not on the Mac. (verified for MCP placement; plugin limit inferred)

## (c) Shell on the Mac, TCC and sandboxing

- The daemon entry is `dist/local-exec-daemon/main.cjs`. Electron main spawns it with `process.execPath` (the Grok Bot binary) and `ELECTRON_RUN_AS_NODE`, or forks it as an Electron `utilityProcess`. It is not a LaunchAgent. (verified, `asar:dist/electron-main/main-core.cjs@925932`, `@675828` and `@1118018`; no `launchctl` use for the daemon found)
- The exec root is `SAND_LOCAL_EXEC_ROOT`, else `SAND_AGENT_PROJECT_DIR`, else the home directory. (verified, `asar:dist/local-exec-daemon/main.cjs@3005826`)
- Shell runs the user's login shell (zsh or bash) with `CURSOR_AGENT=1` and `SAND_AGENT=1`, and keeps background jobs. `AwaitShell` waits on them. (verified, `asar:dist/local-exec-daemon/main.cjs@3007301` and `@3007344`)
- The default sandbox policy is `{perUser: {type: "insecure_none"}}`, and no sandbox binary ships in the bundle. (verified, `asar:dist/local-exec-daemon/main.cjs@330678`)
- The default local tool permission is `ask`, and each machine can override it. (verified, `asar:dist/electron-main/main-core.cjs@1147616` and `asar:dist/electron-main/main-app.cjs@1161273`)
- Because the daemon is a child of Grok Bot, TCC treats Grok Bot.app (`com.anysphere.sand`) as the responsible app for Shell commands. Full Disk Access for Shell would mean adding Grok Bot.app itself. (inferred from the spawn path and standard TCC attribution)
- The helper app, not Grok Bot, holds the Messages permissions for the built-in tools. Those grants do not carry over to Shell. (verified that the helper opens the FDA pane and runs the AppleScript, `helper-strings:12746` to `12790`; non-transfer inferred)
- VS Code's issue tracker shows tccd logging "Refusing TCCAccessRequestIndirect for service kTCCServiceAppleEvents ... without NSAppleEventsUsageDescription key" for an Electron app, and child tools then fail with `-1743` without a prompt. The same issue says `osascript` can still trigger the prompt. Grok Bot.app has no `NSAppleEventsUsageDescription`, so the same thing may happen for AppleScript sends from Shell. (reported, https://github.com/microsoft/vscode/issues/342365; the Grok Bot effect is inferred and untested)
- A LaunchAgent is its own responsible process, so a LaunchAgent helper can hold Full Disk Access and Automation on its own. Both existing community projects do this. (reported, https://github.com/jeffhuber/grokbot-imessage-skill and https://github.com/cmer/imessage-bridge)
- Computer use keeps a list of apps it will not drive: terminals, Script Editor, Automator, Shortcuts, Keychain Access, Passwords, Cursor, System Settings and Grok Bot. Messages is not on the list. (verified, `asar:dist/local-exec-daemon/main.cjs@2081164` and `asar:dist/electron-main/main-app.cjs@2904344`)

## (d) Wake mechanisms

| Mechanism | Finding | Status and source |
| --- | --- | --- |
| Built-in reaction to new iMessages | None. Reads are on demand, and no code watches `chat.db`. | verified absence, `messages-worker.cjs` and `main.cjs` |
| Routine triggers | `cron` (with `schedule`, `firesAt`, `window`, `timing` of `exact` or `flexible`), `slack`, `github`, `origin`, `microsoftTeams`, `linear`, `sentry`, `pagerduty`, `email`, `webhook`, and `group` of two or more. No iMessage trigger. | verified, `asar:dist/electron-main/main-app.cjs@1416852` to `@1419426` |
| Routine webhook | `POST <backendUrl>/automations/webhook/<automationId>` with `Authorization: Bearer <key>` and body `{"context": "<string>", "page"?: {...}}`. The reply carries `runUuid`. The key comes from `createAutomationWebhookApiKey` and the UI shows the URL, key and header. | verified, `asar:dist/electron-main/main-app.cjs@2859780` and `@2861893`, `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@177619` |
| Backend URL | Probably `https://api2.cursor.sh`, the only `api2` host in the bundle. | inferred, `asar:dist/electron-main/main-app.cjs` |
| Routine spec | `{name, prompt, trigger, isEnabled?}` | verified, `asar:dist/electron-main/main-app.cjs@1419426` |
| `grokbot://app/v1/prompt?text=` | Opens the bot and prefills the composer draft. It keeps an existing draft and never sends. Text is at most 1,000 characters. | verified, `asar:dist/renderer/assets/index.eager-app-BtHDDJog.js@3882220` and `@179987` |
| Other deep links | `agent`, `agent-invite`, `bot-template`, `marketplace`, `plugin/add`, `plugin/native`, `open`, `messages`, `settings`, `thread`, `task`, `vault`, `sidebar`, `referral`, `create-team-bot`, and OAuth callbacks. None of them sends a prompt. | verified, `asar:dist/local-exec-daemon/main.cjs@1992201` |
| Local HTTP API | None in the packaged app. The dev control server only starts when the app is unpackaged. Other listeners are an OAuth loopback and an update feed. | verified, `asar:dist/electron-main/main-app.cjs@2767905` and `@3400894` |
| Helper socket | Admission-checked, so not usable as a wake path. | verified string, `helper-strings:9907` |
| ACP | No Agent Client Protocol code found. | verified absence |
| `SetProactiveMessaging`, `EditProactivityPreferences`, `ViewProactivityPreferences`, `WakeParent` | Only the names exist locally. They most likely control whether the bot may message the user unprompted, and `WakeParent` likely wakes a parent agent from a subagent. Neither is an inbound trigger. | verified names, `asar:dist/local-exec-daemon/main.cjs@1962516`; meaning inferred |
| Email trigger | A routine can fire on mail to a claimed bot inbox, with an optional sender list. A watcher could email the bot, but the webhook is simpler. | verified schema, `asar:dist/electron-main/main-app.cjs@1418885` |

## (e) Truncation and limits before the model

- A `messages-result` or `local-tool-result` whose JSON is longer than 8 MiB (`K_ = 8*1024*1024`) is replaced by an error. (verified, `asar:dist/local-exec-daemon/main.cjs@3800829` and `@3831878`)
- File transfers go in 1 MiB frames (`j2 = 1024*1024`). (verified, `asar:dist/local-exec-daemon/main.cjs@2320816`)
- The executor's single-file limit is 100 MiB. Over that, the error says the file "exceeds Grok Bot's ... MiB limit for reading or transferring a single file over local-exec" and suggests reading a slice or using `grep`, `head` or `tail`. (verified, `asar:dist/local-exec-daemon/main.cjs@3075986` and `@2311578`)
- `fetch-attachment` returns base64 inside the result JSON. The schema allows up to 100 MiB of decoded bytes, but the 8 MiB result cap means attachments larger than about 6 MiB fail. (verified pieces, `asar:dist/local-exec-daemon/main.cjs@2310157` and `@3831878`; the 6 MiB figure is inferred from base64 overhead)
- Message pages stop at 64,000 JSON characters, with the item caps listed under (a). (verified, `asar:dist/local-exec-daemon/messages-worker.cjs@9351` and `@9445`)
- Shell output is streamed, not truncated, on the Mac. The limiter only batches output every 50 ms or 256 KiB. Any truncation the model sees happens on the server. (verified, `asar:dist/local-exec-daemon/main.cjs@351345`; server truncation unknown)
- The approval target for a send holds the recipient and the full text. (verified, `asar:dist/local-exec-daemon/main.cjs@2309650`)
- When a helper call fails in the main process, the error text passed to the failure reporter is clipped to 500 characters with quoted strings masked. This looks like telemetry, not model input. (verified code, `asar:dist/electron-main/main-app.cjs@3031776`; purpose inferred)

## Prior art

- `jeffhuber/grokbot-imessage-skill` ships a LaunchAgent that watches a request folder, reads `chat.db` and sends with `osascript`, with a preview, a nonce and a native confirm dialog. It holds Full Disk Access and Automation under its own wrapper name. It installs a skill to `~/.grok/skills`, which is the Grok Build CLI folder, not something Grok Bot desktop loads. (reported, https://github.com/jeffhuber/grokbot-imessage-skill; desktop non-loading inferred from the skills findings above)
- The grokbot.dev listing for that plugin says it is text only, with no attachments, tapbacks or group-chat sending. (reported, https://grokbot.dev/plugins/imessage/)
- `cmer/imessage-bridge` is a menu bar app with an MCP server on `127.0.0.1:7542`, per-agent tokens and a 30 per hour send cap. For Grok Bot it uses a CLI that Shell calls one command at a time. (reported, https://github.com/cmer/imessage-bridge)

## Implications for the repo design

These follow from the findings above and are inferred.

- Put chat.db reads and AppleScript sends in a LaunchAgent helper that holds Full Disk Access and Automation itself. Do not ask the user to give Grok Bot.app Full Disk Access, because that would expose every file to every cloud-issued Shell command.
- Expose the helper through a short CLI that Shell calls, and teach it with one `UpdateSkill` skill. Do not ship it as an MCP server for Grok Bot, because MCP runs in the cloud box.
- Use a webhook routine for incoming messages. The watcher can debounce, filter by allowed chats, and send a compact `context` such as chat id, sender and a short preview, so each wake costs few tokens.
- Use the built-in `SendIMessage` for plain text when its per-recipient approval fits, and the helper for files, tapbacks and anything else the built-in tools lack.
- Use the built-in read tools where they suffice. They already return compact JSON with tapbacks, edits and thread ids.

## Open questions

- What the server-side descriptions, parameters and output truncation of `SendIMessage`, `SearchIMessages`, `ChatItems`, `Shell` and `UpdateRoutine` are.
- Whether a webhook-triggered routine runs in the bot's main conversation or in a new task thread, and whether `context` lands in the prompt verbatim.
- Whether the webhook URL and key can be read by the bot itself or only by the user in the routine sidebar.
- Whether `osascript` run from Grok Bot's Shell gets an Automation prompt or a silent `-1743`, given the missing `NSAppleEventsUsageDescription`.
- Whether an unattended routine stalls on `ask` approvals for Shell, and whether the global "always" grant for `run-command` is acceptable to the user.
- Whether `placement: "client"` for MCP servers is planned, which would let a local MCP server run on the Mac.
- What the minimum cron interval and per-run cost of routines are.

## Sources

- `/Applications/Grok Bot.app/Contents/Info.plist`
- `/Applications/Grok Bot.app/Contents/Resources/app.asar` (extracted read-only to `/tmp/gbim-research/grokbot/app`)
- `/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app/Contents/Info.plist`
- `/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app/Contents/MacOS/CUGrokBotService` (strings in `/tmp/gbim-research/grokbot/cu-strings.txt`)
- `research/messages.sdef`
- https://github.com/microsoft/vscode/issues/342365
- https://github.com/jeffhuber/grokbot-imessage-skill
- https://github.com/cmer/imessage-bridge
- https://grokbot.dev/plugins/imessage/
