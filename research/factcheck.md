# Fact check of the research reports

Checked on 2026-11-05 against macOS 26.2 (25C56) on this Mac. I read all six reports in research/ (repos.md, grokbot.md, grokcli.md, macos.md, tokens.md, realtime.md). I picked the claims that decide the design and tried to refute each one from a primary source. Primary sources here mean output I produced myself from Apple binaries, the installed Grok Bot bundle, the installed grok CLI, cloned source code, SQLite experiments on synthetic databases, and Apple's own documentation.

## Method and rules followed

- I did not send any message. I did not open or read anything under ~/Library/Messages. I did not read ~/.grok/auth.json, keychains or token files. I did not modify /Applications or ~/.grok. A `find ~/.grok -newer <my first script>` after testing returned nothing.
- All scratch work is in /tmp/gbim-research/factcheck/. My scripts are in /tmp/gbim-research/factcheck/scripts/.
- I extracted Grok Bot files straight from `/Applications/Grok Bot.app/Contents/Resources/app.asar` with my own reader (/tmp/gbim-research/factcheck/scripts/asar_get.py, run with `python3 -I`). The extracted main.cjs, messages-worker.cjs and main-app.cjs are byte-identical (`cmp`) to the copies grokbot.md used under /tmp/gbim-research/grokbot/app/dist/.
- I ran no code from cloned repos or from pip. That includes the tiktoken install under /tmp/gbim-research/tokens/venv, so I did not re-tokenize anything (see claim 13).
- AppleScript snippets from two repos were compiled with `osacompile`, which only parses and never runs them. Nothing was sent.
- SQLite tests used Apple's /usr/bin/python3 with `-I` against databases I created in /tmp/gbim-research/factcheck/sqlite/.

Labels: verified means I checked it myself in the cited source. Reported means a secondhand source. Inferred means my reasoning from verified facts.

## Version note

The installed Grok Bot is 0.79.2, not 0.78.5 [verified: `defaults read "/Applications/Grok Bot.app/Contents/Info.plist" CFBundleShortVersionString` prints 0.79.2]. grokbot.md and grokcli.md already say 0.79.2. realtime.md says 0.78.5, but the worker it read is byte-identical to the 0.79.2 copy, so its conclusions still apply [verified: `cmp`].

## Verdicts

### 1. The Messages dictionary has only send, login and logout. Confirmed.

Claim (repos.md, macos.md): the macOS 26.2 Messages scripting dictionary defines only send, login and logout. The service type enum is SMS, iMessage and RCS. Chat, participant and account elements are read-only.

- I regenerated the dictionary with `sdef /System/Applications/Messages.app`. It is byte-identical to research/messages.sdef [verified: `diff` printed nothing; my copy is /tmp/gbim-research/factcheck/messages.sdef].
- The only `<command>` entries are send (ichtsend), login and logout. The enum has exactly SMS, iMessage and RCS, with no "any". The participant, account, file transfer and chat elements are all `access="r"` [verified: same file, lines 7-11, 40-70].
- One small correction to the wording. The only writable property is account `enabled`, which has no access attribute. macos.md notes this and repos.md does not [verified: line 109].
- The dictionary pulls in the Cocoa standard suite through xi:include, so generic verbs like make, delete and set parse. The read-only elements mean they do not create chats [verified: line 4; inferred for runtime behavior].

Design impact: without SIP changes, AppleScript can send text and files and nothing else.

### 2. Two repos call AppleScript verbs that do not exist. Confirmed, and worse than reported.

Claim (repos.md, inferred): tszaks `react_to_message` uses `add reaction` and adelaidasofia `mark_chat_read` sets `unread count`, so both likely fail.

- Both scripts fail at compile time, before any Apple Event is sent. The tszaks snippet gives `Expected end of line but found property. (-2741)`. The adelaidasofia snippet gives `A command name can't go after this identifier. (-2740)` [verified: `osacompile` on the exact statements from /tmp/gbim-research/repos/tszaks_imessage-mcp/index.js lines 3038-3042 and /tmp/gbim-research/repos/adelaidasofia_imessage-mcp/applescript_send.py lines 182-184].
- Line reference fix: the adelaidasofia statement is at line 184. Line 173 is the function header.

So these two features never work on any macOS version with this dictionary. The verdict moves from inferred to verified.

### 3. Without the private API, tapbacks go only through UI scripting, and only to the last or selected message. Confirmed, with one stale detail refuted.

Claim (repos.md): without the bridge, imsg sends only the six classic tapbacks to the last or selected message by scripting System Events, and that keystroke sequence stopped working on macOS 27. Claim (macos.md): Apple documents Command-T then 1 to 6 for a tapback, Command-R to reply, Command-E to edit and Shift-Command-U for read or unread. Unsend has a 2 minute limit, edit allows 5 edits in 15 minutes, and both need iMessage.

- imsg's no-bridge tapback is an osascript script that drives System Events. It focuses search, opens `sms://open?groupid=<chat_identifier>`, presses Command-T, finds the `TapbackPickerCollectionView` element, and clicks the button for heart, thumbsUp, thumbsDown, ha, exclamation or questionMark. A custom emoji throws `unsupportedReaction` [verified: /tmp/gbim-research/repos/openclaw_imsg/Sources/imsg/Commands/ReactCommand.swift lines 150-252, commit 1bc0679 of 2026-11-05]. The command's own help text says it uses "Messages' last-or-selected-message shortcut" (line 10).
- The macOS 27 part is out of date. Issue #311 reported that the old keystroke sequence did nothing on macOS 27. The maintainer closed it on 2026-09-24 as "Fixed in #317, commit 0a9811bb". The fix replaced typing a number with clicking the picker button, which is the code above [verified: `gh api repos/openclaw/imsg/issues/311` and its comments and timeline]. So the old sequence broke on macOS 27, but current imsg says it works again. I did not test macOS 27.
- Apple's shortcuts page says "Command-T, then press 1 through 6" for a Tapback on the last or selected message. It lists Command-R to reply to the last incoming or selected message, Command-E to "Edit a sent message", and Shift-Command-U to mark a conversation read or unread. It lists no unsend shortcut [verified: https://support.apple.com/guide/messages/keyboard-shortcuts-ichtc78b3bff/mac].
- Apple's edit page says unsend works up to 2 minutes after sending and edit works up to five times within 15 minutes. Both need iMessage on macOS 13 or later, and SMS, MMS and RCS messages cannot be edited or unsent [verified: https://support.apple.com/guide/messages/unsend-or-edit-messages-ichtd68328c6/mac].
- Shift-Command-U works on a whole conversation, not on one message [verified: same page].

Design impact: a no-SIP tapback, reply or edit works only on a message the UI has focused, usually the last one. It needs Accessibility permission and puts Messages in front. It cannot target an arbitrary older message by GUID without UI navigation [inferred].

### 4. Private API on Tahoe: is "SIP off plus the library-validation plist" enough, or are AMFI boot-args needed from 26.4? Uncertain. The reports contradict each other.

Claim (repos.md): on macOS 26 up to 26.5.x, SIP off plus DisableLibraryValidation is enough, with no boot-args. Claim (macos.md summary): using the private API needs AMFI boot-args on 26.4 and later.

- The OpenClaw doc says, word for word, "macOS 26 (Tahoe), verified on 26.5.1: SIP off plus the DisableLibraryValidation command above is sufficient ... across 26.0 through 26.5.x. No boot-args are required." [verified that the doc says this: /tmp/gbim-research/repos/openclaw_openclaw/docs/channels/imessage/private-api.md lines 53-58]. This is the project's own test report. I cannot repeat it because SIP is on here.
- BlueBubbles issue #776 does not show that boot-args are required. One commenter suggested `amfi_get_out_of_my_way=1` and a user replied "tried that and no luck". Another user turned on several settings at once and wrote that they were "not clear if every single one of these was required". A later comment root-caused the 26.5 failure to the helper dylib's flat-namespace symbol binding, "a helper-source fix, not an OS/injection wall". An earlier fix was a patched dylib for a missing `-index` selector [verified: `gh api repos/BlueBubblesApp/bluebubbles-server/issues/776` and its comments, read 2026-11-05].
- So the BlueBubbles crashes look like bugs in the helper, not an OS change that needs boot-args [inferred]. macos.md's "needs AMFI boot-args on 26.4 and later" is not supported by its own source, and OpenClaw contradicts it. Neither claim has been reproduced here.

Design impact: both readings agree that every bridge feature needs SIP turned off in Recovery. An agent cannot do that, so the free default must work without the bridge either way.

### 5. Grok Bot runs custom MCP servers in the cloud, never on the Mac. Confirmed.

Claim (grokbot.md): AddMcpServer writes to the account on the server, and stdio servers are pushed to the cloud box, so a local iMessage MCP cannot be reached.

- main-app.cjs has this error text: "HTTP/SSE servers execute on the backend and stdio servers run on Grok Bot's computer; this server is neither reachable nor supported in this context." A second string says "MCP tools run on Grok Bot's computer, not the desktop app". A third says "MCP resources are read on Grok Bot's computer, not the desktop app" [verified: `grep` on /tmp/gbim-research/factcheck/asar/dist/electron-main/main-app.cjs].
- `addServer` calls `writeAccountServer`, which calls `addServersToAccount`. `getStdioServerConfigs` builds configs through `stdioConfigForBox`, and the push is logged as `api:"box_load_servers"` [verified: same file near byte 2114890 and 2148027].
- The proto has `ExecuteSandMcpToolRequest` with server_identifier, tool_name and args, and `GrokBotAgentCustomMcpStdio` with command and args. This is a server-side execution path [verified: /tmp/gbim-research/factcheck/asar/dist/electron-main/proto.cjs and dist/node-agent-coordinator/main.cjs].
- The string `StdioClientTransport` does not appear in main-app.cjs, main-core.cjs or the local-exec daemon [verified: `grep -c`]. The code is minified, so this absence is weak evidence on its own. The error strings above are the strong evidence.

Design impact: an MCP server cannot be the Grok Bot path. A CLI that Grok Bot's Shell calls on the Mac can be.

### 6. Grok Bot skills: stored on the server, or loaded from local folders like ~/.agents/skills? The server side is confirmed. The local side is uncertain, and the two reports conflict.

Claim (grokbot.md, inferred): skills are stored per bot on the server ({name, description, body}) and written with UpdateSkill. Local folders have no Grok Bot loader. Claim (grokcli.md, verified): Grok Bot scans skills in .cursor, .claude, .codex, .grok and .agents at project and user level.

- The server-side model is real. The proto has `GrokBotAgentSkill|1 id|2 name|3 description|4 body|5 source`, plus `AddGrokBotAgentSkillRequest|1 agent_id|2 name|3 description|4 content` and `UpdateGrokBotAgentSkillRequest`. The tool names `Skill` and `UpdateSkill` are in the renderer and main-core [verified: proto.cjs; /tmp/gbim-research/grokbot/app/dist/renderer/assets/index.eager-app-BtHDDJog.js].
- The local scan list exists too. `Dw=[{configDir:".cursor"...},{".claude", thirdParty:true},{".codex", thirdParty:true},{".grok", thirdParty:true},{".agents", thirdParty:false}]`. The functions `LN` and `BN` build project and user paths from it, and `v5r` and `uft` use them to sort skills by tier [verified: /tmp/gbim-research/factcheck/asar/dist/local-exec-daemon/main.cjs].
- I found nothing that ties this scanner to Grok Bot bot sessions. It looks like Cursor agent library code bundled in the daemon. Grok Bot's skills reach the model from the server [inferred]. grokcli.md calls the scan "verified", but it only proves the array exists, not that Grok Bot uses it.
- Cheap runtime test (not run): put a uniquely named skill in ~/.agents/skills and ask Grok Bot to list its skills.

Design impact: plan to install the skill into Grok Bot with UpdateSkill or AddGrokBotAgentSkill, and treat a local ~/.agents/skills copy as a bonus that may do nothing.

### 7. Grok Bot plugins install by marketplace plugin_id only. Confirmed for the client.

Claim (grokbot.md): plugins install only by marketplace plugin_id. No client call installs from a raw GitHub URL.

- `InstallUserPluginRequest|1 plugin_id 3|4 pinned_git_ref 9?|5 variables|6 allow_missing_secrets` is the only install request. `UpdateUserPluginInstallRequest` also takes plugin_id. No non-internal request takes a repo or git URL. Only internal (admin) requests create marketplace listings [verified: `grep` over proto.cjs for Install, Create, Add, Import, Register and Publish requests that mention Plugin or Marketplace].

Design impact: a user cannot point Grok Bot at the repo URL and have it install a plugin. The repo must set itself up through Shell plus UpdateSkill [inferred].

### 8. Grok Bot.app lacks NSAppleEventsUsageDescription, and osascript can always prompt. Confirmed.

Claim (macos.md, grokbot.md): Grok Bot.app (com.anysphere.sand) has the apple-events entitlement but no NSAppleEventsUsageDescription. /usr/bin/osascript has `com.apple.private.tcc.allow-prompting` set to kTCCServiceAll.

- Grok Bot.app's entitlements are automation.apple-events, cs.allow-jit, device.audio-input and device.camera. Its Info.plist has usage descriptions for audio capture, Bluetooth, camera and microphone only. There is no NSAppleEventsUsageDescription and no NSContactsUsageDescription [verified: `codesign -d --entitlements :-` and `plutil -p` on /Applications/Grok Bot.app].
- The helper co.anysphere.grok-bot-computer-use (team DCNK4UB866, hardened runtime) has NSAppleEventsUsageDescription, NSContactsUsageDescription, NSAccessibilityUsageDescription and NSScreenCaptureUsageDescription [verified: the helper's Info.plist and `codesign -dv`].
- osascript has `com.apple.private.tcc.allow-prompting => [kTCCServiceAll]` [verified: `codesign -d --entitlements :- /usr/bin/osascript`].
- tccd on 26.2 contains the strings `NSAppleEventsUsageDescription`, `Missing Usage String` and `com.apple.private.tcc.allow-prompting` [verified: `strings` on /System/Library/PrivateFrameworks/TCC.framework/Support/tccd]. The exact log line "Refusing TCCAccessRequestIndirect ... without NSAppleEventsUsageDescription key" quoted in vscode issue #342365 is not a literal string in this tccd, so it is probably assembled from a format string [inferred].

### 9. TCC charges Shell commands to Grok Bot.app, so AppleScript from a CLI may fail with -1743 unless it goes through osascript. Uncertain. The code path supports it, but I did not observe it at runtime.

Claim (grokbot.md and macos.md, inferred or reported): TCC treats Grok Bot.app as the responsible app for Shell commands. Without the usage string, indirect Apple Events are refused with -1743 and no prompt, and osascript is the exception.

- The local-exec daemon is a child of the Grok Bot binary. main-core.cjs checks that the daemon's command line equals `${process.execPath} ${path to local-exec-daemon/main.cjs}` [verified: /tmp/gbim-research/factcheck/asar/dist/electron-main/main-core.cjs, function `Roe`].
- The daemon's shell sandbox policy falls back to `insecure_none` [verified: local-exec-daemon/main.cjs, function `LE` and `vi`].
- No JS file mentions responsibility disclaiming. The Electron Framework binary does contain `responsibility_spawnattrs_setdisclaim`, so Chromium could disclaim for some child processes. I could not tell from strings whether it does so for this daemon [verified: `grep -a` over the bundle]. If the daemon disclaimed, it would still be the Grok Bot binary, so the responsible app would still be Grok Bot.app [inferred].
- The -1743 behavior is reported only, in vscode issue #342365. That issue includes a tccd log line and a repro with VS Code 1.138 on macOS 26.5.1 [reported: https://github.com/microsoft/vscode/issues/342365].
- New finding: Shell on the Mac is opt-in. The renderer has a `local-execution` setting labeled "Allow Grok Bot to run tasks on this computer, not only on its own computer", and a message "Grok Bot can no longer run tasks on this computer" [verified: index.eager-app-BtHDDJog.js strings Hd1KB+, kvhz1P, QaXzzu]. There are also `messages-send`, `messages-send-without-asking` and `messages-allowed-recipients` settings for the built-in tools (same file).

Design impact: send Apple Events by running /usr/bin/osascript, or run the sender as a separate LaunchAgent with its own grants. Setup must check that "local execution" is on. The cheap runtime test is to call `AEDeterminePermissionToAutomateTarget` with askUserIfNeeded false from Grok Bot's Shell against Finder [inferred].

### 10. Grok Bot's built-in send is text only, and a chatId that starts with "any;" goes over SMS. Text-only is confirmed. The SMS part is refuted.

Claim (grokbot.md): built-in send handles text only, by `to` or `chatId` (`^[A-Za-z0-9._@;+-]+$`). A chatId starting with SMS; or any; goes over SMS.

- The worker validates the chatId with `/^[A-Za-z0-9._@;+-]+$/`, writes the text to `messages-mac-send-*/body.txt` with mode 0600, and sends `{kind:"chat", id, textFile}` or a participant send. There is no attachment field [verified: /tmp/gbim-research/factcheck/asar/dist/local-exec-daemon/messages-worker.cjs near byte 109615 to 111099].
- `Es()` returns the label "SMS" when the chatId starts with "SMS;" or "any;" [verified: same place]. But the helper has only one chat-send template, `send targetText to chat id "<id>"`, with no service. The service template, `set targetService to 1st service whose service type is ...` then `send targetText to participant "..." of targetService`, is used only for participant sends [verified: `strings` on CUGrokBotService, /tmp/gbim-research/factcheck/cu-strings.txt lines 19172-19179]. In `vs()` and `bs()`, the service value filters chats only for `to` sends. A chatId send reads `items(chatId)` directly.
- So for a chatId send, Messages picks the service for that chat. "any;" chats are not forced onto SMS. The "SMS" label only appears in the returned result [inferred from the verified code]. That means Grok Bot can report service "SMS" for an iMessage group.
- Verification: the worker takes a new helper snapshot and looks for a fromMe message newer than the send time whose text matches, ignoring U+FFFC [verified: `vs()`]. An empty ghost row would therefore fail verification and not show as a false success [inferred].

### 11. Reading chat.db: immutable=1 hides WAL rows, and a ROWID cursor misses edits that PRAGMA data_version catches. Confirmed by experiment.

Claims (repos.md): opening chat.db with immutable=1 ignores the WAL, so recent messages stay hidden until a checkpoint. (realtime.md): edits, unsends and read state change existing rows, so a ROWID cursor misses them. imsg uses PRAGMA data_version plus total_changes().

- WAL test, SQLite 3.51.0, Apple python. I created a WAL database with one checkpointed row and five uncheckpointed rows (20,632-byte WAL). `mode=ro` counted 6 rows. `immutable=1` and `mode=ro&immutable=1` each counted 1 [verified: /tmp/gbim-research/factcheck/scripts/immut.py].
- data_version test. A read-only connection saw PRAGMA data_version go from 2 to 3 after another connection ran an in-place UPDATE, while MAX(ROWID) stayed at 1 [verified: /tmp/gbim-research/factcheck/scripts/dv.py].
- The saved 26.2 schema has date_edited, date_retracted, message_summary_info, date_delivered, date_read, is_read, associated_message_emoji, reply_to_guid and thread_originator_guid. It also has schedule_type and schedule_state, which are relevant to Send Later [verified: `grep` on research/chatdb-schema.sql].
- imsg reads `PRAGMA data_version` and `SELECT total_changes()` as its change version, and watches path, -wal and -shm with `open(path, O_EVTONLY)` and `DispatchSource.makeFileSystemObjectSource`. Its defaults are a 0.25 s debounce and a 5 s fallback poll [verified: /tmp/gbim-research/repos/openclaw_imsg/Sources/IMsgCore/MessageStore+Mutations.swift lines 46-47; MessageWatcher.swift lines 19-23, 174, 229-231].
- Grok Bot's messages worker has no watch call (`watch(`, `watchFile(`, FSEvents and kqueue each appear 0 times). It copies the folder with `cpSync` into `messages-mac-*` per query [verified: messages-worker.cjs].

### 12. Grok Bot loads MCP tools lazily through slim descriptors. Uncertain, and partly undercut.

Claim (tokens.md): Grok Bot's MCP filesystem mode writes each tool definition to mcps/<server>/tools/<tool>.json and sends only toolName and definitionPath. The flag mcp_meta_tool_slim_descriptors defaults to true, so always-on definition cost is mostly avoided.

- The definitionPath code is real. It builds `{toolName, definitionPath: join(folderPath, <tools dir>, <tool>.json)}` [verified: local-exec-daemon/main.cjs].
- The flag table in main-app.cjs has `mcp_meta_tool_slim_descriptors:{client:!0,default:!0}`, which is true. The same table has `meta_mcp_tool:{client:!0,default:!1}`, which is false, and `mcp_input_schema_json` set to true [verified: main-app.cjs]. These are client defaults that the server can override [inferred from the `client` key].
- With the meta-tool flag off by default, I cannot confirm that lazy loading is what bots get. Claim 5 also showed that custom MCP runs on Grok Bot's cloud computer, so this local file layout may only cover some tools [inferred]. For the chosen design, a Shell CLI plus a skill, the question does not matter.

### 13. Token counts for chat output formats. Uncertain. The byte sizes are confirmed, but I did not re-tokenize.

Claim (tokens.md): a synthetic 50-message group chat costs 17,773 o200k tokens as raw pretty JSON, 14,910 in wyattjoh style, 6,858 as compact JSON and 1,163 in the proposed line format.

- Byte sizes match the report exactly: A_raw_rows_pretty_json.txt is 52,798 bytes, W_wyattjoh_emulated.txt is 43,088, C_structured_compact_json.txt is 17,464, and F_final_recommended.txt is 3,273 [verified: `wc -c` in /tmp/gbim-research/tokens/out/formats/].
- I did not re-count tokens. That needs the pip-installed tiktoken, which counts as downloaded code under the rules. The implied ratios are 2.97 bytes per token for pretty JSON and 2.81 for the line format. The line format has multibyte emoji and arrows, so these are plausible, but plausibility is not confirmation [inferred].
- Caveat: the cheaper formats carry less information. They drop GUIDs, ISO dates and paths and use ROWIDs and local times instead [verified: head of F_final_recommended.txt]. The 74% saving from pruning values is real only if ROWIDs are enough to target replies and tapbacks later. For the CLI design they are, because the CLI can map a ROWID to a GUID itself [inferred].
- Byte sizes alone confirm that the two big formats exceed grok CLI's documented 20,000-byte MCP cap and the line format fits (see the additional checks below).

### 14. grok hooks fail open and cannot block sends in auto-wake turns. Partly refuted.

Claim (realtime.md): grok hooks fail open, and UserPromptSubmit runs observe-only for auto-wake turns, so hooks cannot reliably gate sends that monitor events trigger.

- Fail-open is confirmed. The docs say "All hook failures (timeouts, crashes, malformed output) are fail-open" and "A handler that times out, crashes, or emits malformed output is recorded in the scrollback but never blocks the action" [verified: ~/.grok/docs/user-guide/10-hooks.md lines 187 and 299].
- Observe-only applies only to UserPromptSubmit: "auto-wake turns (task and subagent completions, scheduler fires) and subagent sessions run the hook observe-only" (line 116). The docs list SessionStart, Notification and PreCompact as observe-only events (line 528). PreToolUse is not on that list. "PreToolUse can block a tool call" (line 112), and "a deny decision or continue: false in stdout JSON is honored regardless of exit code" (line 475) [verified].
- So a PreToolUse hook on the send command can still deny a send in an auto-wake turn, as long as the hook does not crash or time out. The 5 s default timeout applies (line 567). The design point still stands, because a check that fails open is weaker than a check inside the sending process itself [inferred].

### 15. grok CLI skill discovery follows symlinks and prefers .agents/skills over .claude/skills. Confirmed by my own test.

Claim (grokcli.md): grok reads ~/.agents/skills, ~/.grok/skills and ~/.claude/skills without folder trust. It follows symlinked skill folders, removes duplicates by name, and .agents/skills wins over .claude/skills.

- I built a new home at /tmp/gbim-research/factcheck/grokhome/home. It has two skills with the same name, `imsgtest`, symlinked from ~/.agents/skills and ~/.claude/skills to different source folders. I ran `env -i HOME=... GROK_HOME=... GROK_DISABLE_AUTOUPDATER=1 ~/.grok/bin/grok inspect --json` from an empty cwd. The output had one skill, `imsgtest`, with description "from agents copy" and source path .agents/skills/imsgtest/SKILL.md [verified: /tmp/gbim-research/factcheck/grokhome/inspect.json].
- That proves the symlink was followed, duplicates were merged by name, and .agents won. User-level loading worked with no trust step [verified: same run]. I did not test ~/.grok/skills.

## Additional checks (not in the top 15)

- grok CLI exposes MCP only through `search_tool` and `use_tool`, and truncates MCP results at 20,000 bytes by default (`GROK_MAX_MCP_OUTPUT_BYTES` or `[mcp] max_output_bytes` override it). Confirmed in the docs and in text embedded in the 1.0.70 binary [verified: ~/.grok/docs/user-guide/07-mcp-servers.md lines 45-58 and 235-240; `strings` on ~/.grok/downloads/grok-1.0.70-macos-aarch64]. I did not test this at runtime.
- The bash output cap conflict is real. 05-configuration.md line 210 says `output_byte_limit = 20000` and README.md line 1396 says `65536` [verified].
- IMCore 26.2 references these selectors: `editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:`, `retractMessagePart:`, `setLocalUserIsTyping:`, `markAllMessagesAsRead`, `_setDisplayName:`, `sendGroupPhotoUpdate:`, `chatForIMHandles:` and a `scheduledDate:` selector. The older edit selector without newPartTranslation is absent. Confirmed [verified: `dyld_info -section __TEXT __objc_methname` on IMCore, saved at /tmp/gbim-research/factcheck/imcore-methname.txt]. __objc_methname lists every selector the image uses, including ones it only calls, so presence does not prove IMCore implements each one.
- Messages 26.0 (1450.300.41.1.4) is sandboxed with library-validation and hardened-process entitlements. It can read and write ~/Library/Messages/, ~/Downloads, user-selected files and /private/var/tmp/com.apple.messages/ [verified: `codesign` on /System/Applications/Messages.app]. There is no ~/Pictures entitlement, so the report that attachments from ~/Pictures work must rely on another mechanism, such as Photos access or a sandbox extension that AppleScript passes. That stays reported.
- Grok Bot routine triggers are slack, github, origin, microsoftTeams, linear, sentry, pagerduty, email, webhook and cron. None is iMessage. The webhook URL is `new URL('/automations/webhook/<id>', backendUrl)` with a key from `createAutomationWebhookApiKey` [verified: main-app.cjs near byte 1416600 and the webhook code]. The default API base is `CURSOR_API_BASE_URL ?? "https://api2.cursor.sh"`. api3.cursor.sh also appears, but only as a Statsig telemetry proxy, so grokbot.md's "only api2 host string" is slightly wrong and its conclusion still holds [verified].
- imsg's verified send waits up to eight seconds for the outgoing row, returns `may_have_completed` with no-retry guidance, and detects the Tahoe ghost row. Only `not_started` is safe to retry [verified: /tmp/gbim-research/repos/openclaw_imsg/docs/send.md lines 100-120; docs/troubleshooting.md lines 65-74].
- jeffhuber/grokbot-imessage-skill refuses group sends and offers no attachments, tapbacks, edits or effects [verified: SKILL.md lines 204, 313 and 436-444, commit ccd12b9].
- The "any;" chat GUID migration on Tahoe stays uncertain. BlueBubbles code says so in a comment (chatGuid.ts lines 1-9 at 76d2b2e), and Grok Bot's worker treats "any;" as a known prefix. Confirming it would mean reading chat.db rows, which this task forbids.

## What this changes for the design

- Without SIP changes, the confirmed features are: reading everything, sending text and files with AppleScript, the six classic tapbacks, reply and edit on the focused or last message through Accessibility UI scripting, and mark read or unread per conversation. Custom-emoji tapbacks, unsend by GUID, typing indicators, group creation and renaming all need the private API, which needs SIP off.
- Grok Bot cannot run a local MCP server or install a plugin from a URL. The path that works is a Shell-called CLI on the Mac, with "local execution" enabled, plus a skill installed through UpdateSkill. Whether local ~/.agents/skills folders reach Grok Bot is still open.
- Apple Events from that CLI should go through /usr/bin/osascript or a separate LaunchAgent, because Grok Bot.app has no Automation usage string. The -1743 failure itself is reported, not reproduced.
- The reader must not use immutable=1 and should watch with PRAGMA data_version, not only MAX(ROWID). Both are now shown by experiment.

## Open risks

- The no-boot-args claim for the bridge on 26.4 and later is untested here, and the sources disagree.
- The TCC responsible-process chain for Grok Bot's Shell has not been observed at runtime.
- The token counts were not re-tokenized.
- The macOS 27 status of UI tapbacks rests on the imsg maintainer's report.
