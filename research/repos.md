# iMessage for AI agents: open-source survey, November 2026

Survey date is 2026-11-05. Star counts and push dates come from the GitHub API on that date [verified, `gh api repos/<owner>/<repo>`]. The clones I read are under /tmp/gbim-research/repos/<owner>_<repo>/. I read code and docs there and executed nothing from them. I checked chat.db claims against the macOS 26.2 schema at research/chatdb-schema.sql. I checked AppleScript claims against the macOS 26.2 Messages scripting dictionary at research/messages.sdef.

Each claim carries a tag in square brackets.

- "verified" means I read the code or doc myself.
- "reported" means the claim comes from a README, issue comment, blog, or vendor page and I did not confirm it in code.
- "inferred" means I drew the conclusion from other evidence, and the tag names that evidence.

Repo paths in tags are relative to the repo root. The source index at the end maps each repo to its GitHub URL and local clone.

## Short answer

- Every serious free project uses the same two-part base. It reads chat.db with SQLite in read-only mode and sends through the AppleScript `send` command to Messages.app [verified, openclaw/imsg Sources/IMsgCore/MessageStore.swift; carterlasalle/mac_messages_mcp mac_messages_mcp/messages.py; anthropics/claude-plugins-official external_plugins/imessage/server.ts; photon-hq/imessage-kit src/infra/outgoing/applescript-transport.ts].
- On macOS 26.2 the Messages dictionary has three commands: send, login and logout. Chats, participants and accounts are read-only elements. The service type enum lists SMS, iMessage and RCS, with no `any` value [verified, research/messages.sdef].
- Without the private API, an agent can therefore send text and files to existing chats and start new 1:1 chats by handle. Every other action needs either UI scripting through System Events or code injected into Messages.app with SIP disabled [inferred, messages.sdef plus the code survey below].
- openclaw/imsg, formerly steipete/imsg, is the most complete free project. Its base mode needs no SIP changes. Its opt-in injected bridge adds targeted tapbacks, threaded replies, edit, unsend, typing, read receipts, effects, stickers, polls and group management. OpenClaw's own iMessage channel runs on it [verified, openclaw/imsg README.md and docs/; openclaw/openclaw extensions/imessage].
- The two Grok-specific repos are text-only. jeffhuber/grokbot-imessage-skill sends 1:1 text after a confirm dialog and refuses group targets. RyanNewsom/grokbot-imessage-reader cannot send at all [verified, jeffhuber/grokbot-imessage-skill SKILL.md lines 204, 313, 439-442; RyanNewsom/grokbot-imessage-reader README.md].
- No surveyed project sends a location. imsg does not convert HEIC photos, while BlueBubbles, carterlasalle, tszaks, anipottsbuilds, hannesrudolph and daya0576 do [verified, matrix below].

## Projects surveyed

| Project | Language | License | Stars | Last push | What it is |
|---|---|---|---|---|---|
| openclaw/imsg (steipete/imsg redirects here) | Swift | MIT | 1403 | 2026-11-05 | CLI and JSON-RPC server. AppleScript base plus optional injected bridge. v0.21.0 released 2026-11-05. Homebrew `steipete/tap/imsg`. |
| BlueBubblesApp/bluebubbles-server | TypeScript | Apache-2.0 | 1133 | 2026-11-06 | Mac server app with REST, socket and webhooks. v1.9.12 released 2026-10-27. |
| BlueBubblesApp/bluebubbles-helper | Objective-C | Apache-2.0 | 82 | 2026-07-11 | Private API dylib for BlueBubbles. Last official release v0.0.21 in Nov 2024. |
| photon-hq/imessage-kit | TypeScript | MIT | 1480 | 2026-06-08 | SDK. Archived. |
| photon-hq/advanced-imessage-kit | TypeScript | MIT | 185 | 2026-06-08 | Client for Photon's closed server. Deprecated. |
| photon-hq/advanced-imessage-ts | TypeScript | MIT | 14 | 2026-11-05 | Client for Photon's Spectrum cloud over HTTP or gRPC. |
| photon-hq/spectrum-ts | TypeScript | MIT | 2188 | 2026-11-05 | Multi-channel SDK. packages/imessage-local wraps imessage-kit. |
| carterlasalle/mac_messages_mcp | Python | MIT | 343 | 2026-11-05 | MCP server, CLI and skill. |
| anthropics/claude-plugins-official, external_plugins/imessage | TypeScript on Bun | Apache-2.0 | 46247 for the whole repo | 2026-11-06 | Claude Code channel plugin, v0.2.0. |
| openclaw/openclaw, extensions/imessage | TypeScript | MIT | 394012 | 2026-11-06 | Agent framework channel that spawns `imsg rpc`. |
| ReagentX/imessage-exporter | Rust | GPL-3.0 | 5726 | 2026-10-31 | Exporter and decoding reference. Does not send. |
| jeffhuber/grokbot-imessage-skill | Python | MIT | 42 | 2026-10-30 | Grok skill plus launchd helper. SKILL.md v1.4.8. |
| RyanNewsom/grokbot-imessage-reader | Swift | MIT | 0 | 2026-11-05 | Read-only Grok helper app. |
| cyberpapiii/imessage-max | Swift | MIT | 6 | 2026-11-06 | MCP server with intent-shaped tools. |
| tszaks/imessage-mcp | JavaScript | MIT | 2 | 2026-10-24 | MCP server with confirm-gated sends. |
| anipottsbuilds/imessage-mcp | TypeScript | MIT | 30 | 2026-11-02 | Read-only MCP server. |
| wyattjoh/imessage-mcp | TypeScript on Deno | MIT | 29 | 2026-08-19 | Read-only MCP server. |
| hannesrudolph/imessage-query-fastmcp-mcp-server | Python | none listed | 81 | 2026-02-03 | Read-only MCP server. |
| marissamarym/imessage-mcp-server | JavaScript | none listed | 29 | 2024-12-11 | Send and contacts MCP server. Stale. |
| adelaidasofia/imessage-mcp | Python | MIT | 3 | 2026-11-02 | MCP server with an FTS5 index and voice transcription. |
| yashodhank/macOS-iMessage-MCP-Native | TypeScript | none listed | 0 | 2026-05-07 | MCP server with TOON output. |
| thenavidm/imessage-mcp-cli | TypeScript | MIT | 0 | 2026-11-06 | CLI and MCP server with field selection. |
| zohairrk5/imessage-mcp | JavaScript | MIT | 0 | 2026-11-03 | Read-only MCP server. |
| macos-cli-tools/imessage-cli | TypeScript on Bun | MIT | 0 | 2026-03-13 | CLI with 44 commands. |
| wolfiesch/wolfies-imessage-gateway | Python | MIT | 6 | 2026-06-28 | CLI for Claude Code. |
| mattt/Madrid | Swift | MIT | 102 | 2026-10-12 | Read-only Swift library with a typedstream decoder. |
| daya0576/pi-imessage | TypeScript | MIT | 42 | 2026-11-02 | iMessage setup for the Pi coding agent, written so the agent sets itself up from the README. |
| Deibler/imcore-bridge | Objective-C | MIT | 1 | 2026-10-26 | Minimal IMCore injection bridge. |
| mautrix/imessage | Go | AGPL-3.0 | 460 | 2026-05-14 | Matrix bridge with `mac` and `mac-nosip` modes. |
| ack-ventures/herald | Go | MIT | 1 | 2026-07-18 | Includes docs/research/sending.md, a detailed AppleScript send study. |

All metadata in this table is [verified, GitHub API on 2026-11-05].

Anthropic also ships a Claude Desktop connector named "Read and Send iMessages", listed at https://claude.com/connectors. It exposes send_imessage, search_contacts, read_imessages and get_unread_imessages. I found no public source code for it [reported, https://claude.com/connectors]. The zohairrk5/imessage-mcp README says that connector garbles text, has no group support and shows raw phone numbers [reported, zohairrk5/imessage-mcp README.md].

Four projects use paid relays rather than the local Mac. raroque/boop-agent (1388 stars) uses Sendblue. Merit-Systems/OpenInstinct (485 stars) and linq-team/claude-code-imessage-channel (25 stars) use Linq. lucasgelfond/biscotti (46 stars) uses Photon Spectrum [verified, each repo's README and package dependencies]. They fall outside the free, local goal.

## Feature matrix

### Legend

- Y means the code I read supports it.
- N means not supported.
- UI means the project drives the Messages window through System Events. That needs the Accessibility permission and breaks when Apple changes the UI.
- PA means the project calls the private IMCore API from code injected into Messages.app, which needs SIP disabled.
- R means a README or issue claims it and I did not confirm it in code.
- ? means I could not determine it.

### Main projects

Column key: "imsg base" is imsg with SIP on. "imsg bridge" is imsg after `imsg launch` injects its helper (PA). "BB AS" is BlueBubbles without the helper. "BB PA" is BlueBubbles with bluebubbles-helper. "Kit" is photon-hq/imessage-kit. "CL" is carterlasalle/mac_messages_mcp. "Anth" is the Anthropic Claude Code plugin. "Grok skill" is jeffhuber/grokbot-imessage-skill. "Max" is cyberpapiii/imessage-max. "tszaks" is tszaks/imessage-mcp.

| Feature | imsg base | imsg bridge | BB AS | BB PA | Kit | CL | Anth | Grok skill | Max | tszaks |
|---|---|---|---|---|---|---|---|---|---|---|
| Send text | Y | Y | Y | Y | Y | Y | Y | Y, 1:1 only | Y | Y, needs confirm |
| Send attachment | Y, staged copy | Y, plus voice notes | Y | Y | Y, temp copy | Y, 1:1 only | Y | N | Y | ? |
| Send to existing group | Y | Y | Y | Y | Y | Y | Y | N | Y | ? |
| Create group | N | Y | uses `make new chat`, reported broken since Big Sur | Y | N | N | N | N | N | N |
| Rename group | N | Y | UI | Y | N | N | N | N | N | N |
| Add or remove members | N | Y | UI | Y | N | N | N | N | N | N |
| Tapback | UI, six classic types, last or selected message only | Y, any message, custom emoji | UI | Y | N | N | N | N | N | calls an AppleScript command the dictionary lacks |
| Threaded reply | N | Y | N | Y, stalls on Tahoe | N | N | N | N | N | N |
| Edit | N | Y | N | Y | N | N | N | N | N | UI, experimental flag |
| Unsend | N | Y | N | Y | N | N | N | N | N | UI, experimental flag |
| Send typing indicator | N | Y, flaky on macOS 26 | N | Y | N | N | N | N | N | N |
| Mark read or send read receipt | N | Y | N | Y | N | N | N | N | N | N |
| Message effects | N | Y | N | Y | N | N | N | N | N | N |
| Stickers | N, reads `is_sticker` only | Y, with placement | N | N | N | N | N | N | N | N |
| Polls | N | Y, send, vote, unvote | N | N | N | N | N | N | N | N |
| Send location | N | N | N | N | N | N | N | N | N | N |
| Contact name resolution | Y | Y | Y | Y | ? | Y | ? | Y | Y | ? |
| Search | Y | Y | Y | Y, plus PA search | Y, in-app substring | Y, fuzzy | N | Y | Y | ? |
| Read attachments | Y, paths and metadata | Y | Y | Y | Y | Y, inline image, OCR | paths only | N | Y, three image sizes | Y, inline image |
| HEIC conversion | N, converts CAF and GIF only | N | Y, sips | Y, sips | N | Y, pillow-heif | N | N | ? | Y, sips |
| Real-time incoming | Y, kqueue plus poll | Y, plus typing events | Y, fs.watch plus poll, webhooks | Y, plus PA events | Y, fs.watch plus poll | bounded poll up to 300 s | 1 s poll pushed as a channel | N | Y | ? |
| SMS | Y, explicit `sms` service | Y | Y | Y | sent SMS by accident, issue #39 | Y | inbound off by default | ? | ? | ? |
| RCS | Y, through the SMS relay account | Y | ? | ? | ? | Y, AppleScript SMS/RCS path | inbound off by default | ? | ? | ? |
| Scheduled messages | reads Send Later rows | same | Y, own scheduler | Y | N | Y, own scheduler | N | N | N | N |

Sources for each column:

- imsg base and bridge [verified, openclaw/imsg README.md, docs/send.md, docs/attachments.md, docs/groups.md, docs/bridge.md, docs/advanced-imcore.md, Sources/imsg/Commands/ReactCommand.swift line 173]. The SMS and RCS rows come from docs/send.md line 83.
- BlueBubbles AppleScript mode [verified, BlueBubblesApp/bluebubbles-server packages/server/src/server/api/apple/scripts.ts for sendMessage, startChat, sendAttachmentAccessibility, renameGroupChat, addParticipant, removeParticipant, toggleTapback and checkTypingIndicator]. HEIC conversion is in packages/server/src/server/fileSystem/index.ts around line 798. Contacts use node-mac-contacts in api/lib/ContactsLib.ts. The `make new chat` breakage is [reported, ack-ventures/herald docs/research/sending.md section 5.2].
- BlueBubbles Private API [verified, packages/server/src/server/api/privateApi/apis/PrivateApiMessage.ts, PrivateApiChat.ts, PrivateApiHandle.ts, PrivateApiAttachment.ts, PrivateApiFindMy.ts, PrivateApiFaceTime.ts]. Effects use the `effectId` parameter in PrivateApiMessage.ts line 18. I found no sticker or poll calls in the server's private API code. The Tahoe stall is [reported, https://github.com/BlueBubblesApp/bluebubbles-server/issues/814].
- imessage-kit [verified, photon-hq/imessage-kit README.md lines 170-194 and src/]. The SMS bug is [verified closed issue, https://github.com/photon-hq/imessage-kit/issues/39].
- carterlasalle [verified, mac_messages_mcp/messages.py, including the SMS/RCS send at line 2429 and the no-file-fallback note at line 1271].
- Anthropic plugin [verified, external_plugins/imessage/server.ts lines 35-39, 420-424, 620-689].
- Grok skill [verified, jeffhuber/grokbot-imessage-skill SKILL.md].
- imessage-max [verified, cyberpapiii/imessage-max README.md and swift/Sources tool names find_chat, get_messages, get_messages_since, get_unread, get_context, get_active_conversations, list_chats, get_chat_details, search, list_attachments, get_attachment, send_text_dm, send_text_group, send_file_dm, send_file_group, diagnose].
- tszaks [verified, tszaks/imessage-mcp README.md lines 120-234 and index.js line 3004].

### Smaller projects

| Project | Reads | Sends | Notable |
|---|---|---|---|
| anipottsbuilds/imessage-mcp | node:sqlite, read-only | does not send, has `draft_reply` | sips HEIC conversion, `sync_messages` cursor, strips location metadata from images [verified, repo src and README.md] |
| wyattjoh/imessage-mcp | read-only, can target a snapshot path | does not send | Deno [verified, README.md] |
| hannesrudolph/imessage-query-fastmcp-mcp-server | read-only | does not send | fastmcp, HEIC to JPEG through ImageMagick [verified, imessage-query-server.py line 23] |
| marissamarym/imessage-mcp-server | chat.db | AppleScript | contacts lookup, last push 2024-12-11 [verified, repo source] |
| adelaidasofia/imessage-mcp | chat.db plus an FTS5 index | AppleScript with draft then confirm | voice transcription. Its `mark_chat_read` sets `unread count` on a chat [verified, applescript_send.py line 173], a property the macOS 26.2 dictionary does not define, so it likely fails [inferred, research/messages.sdef chat class] |
| yashodhank/macOS-iMessage-MCP-Native | chat.db | AppleScript | TOON output format [reported, README.md] |
| thenavidm/imessage-mcp-cli | chat.db | AppleScript | `--select` and `--compact` output flags. Claims about 1,800 tokens per message with all MCP tools loaded against about 2,200 tokens once for SKILL.md [reported, README.md] |
| zohairrk5/imessage-mcp | read-only, merges services per contact | does not send | [verified, README.md] |
| macos-cli-tools/imessage-cli | chat.db | AppleScript and System Events | 44 commands including block, mute and spam scan [reported, README.md] |
| wolfiesch/wolfies-imessage-gateway | `sqlite3.connect("file:...?mode=ro", uri=True)` | AppleScript | Claims 40 ms per CLI call against about 763 ms through MCP [verified code at src/messages_interface.py line 379; speed claim reported, README.md] |
| mattt/Madrid | `SQLITE_OPEN_READONLY`, live or immutable modes | does not send | Documents that `immutable=1` ignores the WAL so recent messages stay invisible until a checkpoint [verified, Sources/iMessage/Database.swift lines 65-88] |
| daya0576/pi-imessage | chat.db read-only | osascript | sips HEIC. The README tells the user to point the Pi agent at it for self-setup [verified, README.md] |
| ReagentX/imessage-exporter | `SQLITE_OPEN_READ_ONLY` | does not send | Decodes typedstream with crabstep. Claims coverage of edits with history, unsent messages, multipart, threads, mentions and formatting, data detectors, satellite messages, and recently deleted recovery through macOS 27.2. Converts HEIC to JPEG, HEICS to GIF, and CAF, AMR and MOV to MP4 [verified open flags in code; feature list reported, README.md] |

## How each project reads

| Project | Database open | Change detection | attributedBody decoding |
|---|---|---|---|
| imsg | `Connection(location, readonly: true)` on the live chat.db [verified, Sources/IMsgCore/MessageStore.swift line 27] | DispatchSource (kqueue) on chat.db, chat.db-wal and the directory, 0.25 s debounce, 5 s poll fallback [verified, Sources/IMsgCore/MessageWatcher.swift] | Own parser [verified, Sources/IMsgCore/TypedStreamParser.swift] |
| BlueBubbles | TypeORM with better-sqlite3 on the live chat.db, no read-only flag [verified, packages/server/src/server/databases/imessage/index.ts line 43] | fs.watch on chat.db and chat.db-wal, 500 ms debounce, then a query by date from the last check minus 30 s [verified, IMessageListener and MessagePoller] | node-typedstream [verified, package dependencies] |
| imessage-kit | read-only through a better-sqlite3 or Bun adapter, with a macOS 26 query builder [verified, src/] | fs.watch on the WAL, then the directory, then polling [verified, src/] | Own body decoder [verified, src/] |
| carterlasalle | `sqlite3.connect(uri + "?mode=ro", uri=True)` [verified, messages.py] | Poll on demand, `since_rowid` paging, `wait_for_new_messages` polls every 1 s for up to 300 s [verified, messages.py] | Yes [verified, messages.py] |
| Anthropic plugin | `new Database(CHAT_DB, {readonly: true})` [verified, server.ts] | Poll every 1 s for `ROWID > watermark` [verified, server.ts] | `parseAttributedBody` [verified, server.ts] |
| jeffhuber Grok skill | SQLite online backup API snapshot that includes committed rows still in the WAL. The source is opened read-only without `immutable=1` on purpose [verified, README.md lines 359-364] | None. Request and response JSON files under control/requests/ [verified, SKILL.md] | Yes [verified, README.md, SKILL.md and tests/test_core.py] |
| RyanNewsom reader | read-only, inside an app bundle that holds Full Disk Access, launched by a LaunchAgent and `launchctl kickstart` [verified, README.md] | None | Yes [verified, source] |
| imessage-max | `SQLITE_OPEN_READONLY` [verified, swift/Sources] | kqueue [verified, swift/Sources/iMessageMax/Server/MessageWatcher.swift] | Yes [verified, swift/Sources] |
| tszaks | better-sqlite3 read-only [verified, index.js] | ? | Yes [verified, index.js] |
| imessage-exporter | `SQLITE_OPEN_READ_ONLY` [verified, source] | None, batch export | crabstep [verified, Cargo.toml] |

No project I read writes to chat.db. BlueBubbles is the only one that opens it without a read-only flag [verified, table sources above].

## How each project sends

- **imsg base.** It runs AppleScript through osascript with a time limit. It then looks for the new outgoing row in chat.db for up to eight seconds and normalizes Unicode before comparing text [verified, docs/send.md line 104 and docs/troubleshooting.md line 59]. It returns one of three dispositions. `not_started` is safe to retry, while `may_have_completed` and `still_in_flight` are not [verified, openclaw/imsg docs/troubleshooting.md lines 60-74 and docs/rpc.md line 126]. It stages attachments under ~/Library/Messages/Attachments/imsg/ because Messages reads its own directory more reliably than ~/Desktop or ~/Downloads [verified, docs/attachments.md line 64]. `imsg react` sends the six classic tapbacks by driving System Events, only to the last or selected message [verified, Sources/imsg/Commands/ReactCommand.swift line 173].
- **imsg bridge.** `imsg launch` injects a helper dylib into Messages.app with DYLD_INSERT_LIBRARIES. Commands travel as JSON files through ~/Library/Containers/com.apple.MobileSMS/Data/.imsg-rpc/in and out, with a `.imsg-bridge-ready` marker and an `.imsg-events.jsonl` event log [verified, Sources/IMsgHelper/*.inc and docs/bridge.md]. An optional LaunchAgent, org.openclaw.imsg.bridge.plist, keeps the bridge running [verified, repo resources].
- **BlueBubbles.** AppleScript `send` for text and files, and `make new chat with properties {participants}` for new chats. Rename, add and remove participant, tapback and typing checks run through System Events [verified, packages/server/src/server/api/apple/scripts.ts]. With the helper, all of these go through the private API instead. The helper loads through MacForge or a process dylib mode [verified, api/privateApi/modes/MacForgeMode.ts and appResources/private-api/macos11/BlueBubblesHelper.dylib].
- **imessage-kit.** It uses the AppleScript `buddy` form with service type hard-coded to iMessage for direct messages and `chat id` for groups. It copies attachments with `cat >` into a `mktemp -d` directory so the copy loses quarantine and other extended attributes [verified, src/infra/outgoing/applescript-builder.ts lines 154-168]. A code comment says `chat id` only resolves chats that already exist, so a never-contacted number fails with -1728 [verified, same file line 97].
- **carterlasalle.** It writes the message to a file and has AppleScript read the POSIX file. It uses `participant ... of` the iMessage service for 1:1 sends and `chat id` for groups. A code comment says `chat "<name>"` fails with -1728. It refuses file sends to groups [verified, mac_messages_mcp/messages.py]. Sends ask the user to confirm through MCP elicitation [verified, same file].
- **Anthropic plugin.** It runs `osascript` with the text and chat GUID as argv, never inside the script source [verified, server.ts lines 420-424]. It chunks long text, appends "\nSent by Claude" by default and removes that suffix again when it reads echoed messages back [verified, server.ts lines 39 and 437]. Its README says AppleScript cannot tapback, edit or thread [verified, external_plugins/imessage/README.md].
- **jeffhuber Grok skill.** `send_preview` returns a nonce, then a native confirm dialog appears, then AppleScript sends. A hardened mode makes the helper root-owned and enforces an allowlist [verified, SKILL.md].
- **tszaks.** Text sends need `confirm: true`, and batches also need a token from a preview call [verified, README.md line 34]. `react_to_message` builds `add reaction N to message id X` and runs it through `execSync` with shell quoting [verified, index.js lines 3004-3050]. The macOS 26.2 dictionary has no `add reaction` command and no message class, so this call should always fail [inferred, research/messages.sdef]. Edit and undo send open the conversation, find the bubble by text, use the context menu and then check chat.db [verified, README.md lines 170 and 197].
- **herald.** The doc recommends passing chat.guid verbatim to `send ... to chat id`, falling back to `chat id ... of` a service after -1728, then to `buddy` for 1:1 chats. It says AppleScript never falls back to SMS on its own and that `make new chat` for groups has been broken since Big Sur, leaving Shortcuts as the only non-private way to start a group [reported, ack-ventures/herald docs/research/sending.md sections 3 and 5]. It also says parallel Apple events to Messages cause flaky -1712 and -1728 errors, so sends should run one at a time [reported, same doc section 4].

## Features that only the private API can deliver

On macOS 26.2 the scripting dictionary exposes only send, login and logout, so these actions have no AppleScript form [verified, research/messages.sdef]. Every project that offers them does so through IMCore code injected into Messages.app [verified, openclaw/imsg Sources/IMsgHelper; BlueBubblesApp/bluebubbles-helper; Deibler/imcore-bridge].

- Threaded reply to a chosen message.
- Tapback on any message, including custom emoji tapbacks. UI scripting can only reach the last or selected message [verified, openclaw/imsg ReactCommand.swift].
- Edit and unsend. tszaks offers an experimental UI-scripting version [verified, tszaks/imessage-mcp README.md line 197].
- Sending a typing indicator.
- Sending read receipts and marking a chat read or unread.
- Message effects such as confetti or slam.
- Stickers, with placement on a bubble.
- Polls, including voting.
- Creating a group chat. herald reports Shortcuts as the only non-private workaround [reported, ack-ventures/herald docs/research/sending.md section 5].
- Renaming a group, adding and removing members, setting a group photo and leaving a group. BlueBubbles also offers UI-scripting versions of rename, add and remove [verified, bluebubbles-server scripts.ts].
- Deleting a message or a chat.
- "Notify anyway" past a recipient's Focus mode, and reading a contact's Focus status [verified, BlueBubbles PrivateApiHandle.ts and imsg bridge commands].
- Sharing your name and photo.
- Checking whether a handle has iMessage or FaceTime before sending [verified, BlueBubbles PrivateApiHandle.ts; imsg `handles.check` and `whois`].
- Downloading attachments that iCloud has purged from the Mac [verified, BlueBubbles PrivateApiAttachment.ts].
- Find My friends and FaceTime links [verified, BlueBubbles PrivateApiFindMy.ts and PrivateApiFaceTime.ts].

### What each private API project requires

| Project | Requirements | Source |
|---|---|---|
| imsg bridge | SIP disabled. `imsg launch` refuses to inject while SIP is on and has no override. Library validation off. On macOS 26, imagent also checks private entitlements and can refuse some calls even after a successful injection. The doc opens with "You almost certainly do not need any of this for normal use." | [verified, openclaw/imsg docs/advanced-imcore.md lines 10, 50-52, 76, 191] |
| OpenClaw private API mode (uses imsg) | "macOS 26 (Tahoe), verified on 26.5.1: SIP off plus the DisableLibraryValidation command above is sufficient ... No boot-args are required." The command is `sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true`. Without that plist, `imsg launch` times out waiting for Messages.app. | [verified, openclaw/openclaw docs/channels/imessage/private-api.md lines 53-58] |
| imsg on 26.6.1 | One issue reporter said injection worked on 26.6.1 without the library validation plist. The same issue reported every bridge selector returning false because of IMCore selector drift. | [reported, https://github.com/openclaw/imsg/issues/236] |
| BlueBubbles helper | Run `csrutil disable` from Recovery, holding Left Shift when clicking Continue on Apple Silicon. Then set the same DisableLibraryValidation plist. The install doc does not mention boot-args. | [reported, https://docs.bluebubbles.app/private-api/installation] |
| BlueBubbles helper on Tahoe | Users in issue #776 listed boot-args such as `amfi_get_out_of_my_way=1`, `amfi_allow_any_signature=1`, `-arm64e_preview_abi` and `ipc_control_port_options=0` as workarounds, and shared a community dylib named v0.0.22-tahoe. A maintainer later wrote that all Tahoe functionality was fixed. v1.9.12 ships Tahoe fixes and is notarized again. | [reported, https://github.com/BlueBubblesApp/bluebubbles-server/issues/776, https://github.com/BlueBubblesApp/bluebubbles-server/issues/814, v1.9.12 release notes] |
| Deibler/imcore-bridge | SIP off plus the boot-arg `amfi_get_out_of_my_way=0x1`, verified by the author on 26.4.1. The dylib dials out to a Unix socket because the Messages sandbox blocks `listen()`. | [reported, Deibler/imcore-bridge README.md] |
| mautrix/imessage | Has a `mac` mode and a `mac-nosip` mode. | [verified, mautrix/imessage repo layout] |
| Photon advanced-imessage-kit | Talks to a server on localhost:1234 with a BlueBubbles-like /api/v1. That server is Photon's and its source is not public, so its requirements are unknown. | [verified client code, photon-hq/advanced-imessage-kit] |

## macOS 26 compatibility and known breakages

| Project | macOS 26 status | Sources |
|---|---|---|
| imsg | Supported on macOS 14 and later. Fixed on 26: typing broke because imagent requires private entitlements (#60), bridge selectors drifted, for example `isCurrentlyTyping` became `localUserIsTyping`, `loggedIn` became `isConnected`, and `editMessageItem` gained `newPartTranslation:` (#194). Typing now goes through `setLocalUserIsComposing:typingIndicatorData:`. A release binary was killed by taskgated while a local build worked (#291). On macOS 27 the react keystroke sequence stopped working (#311). Open: group renames show as empty messages (#372) and Messages sometimes saves a tracked send under a different GUID (#385). | [verified issue titles and state, https://github.com/openclaw/imsg/issues/60, /194, /291, /311, /372, /385; selector names verified in Sources/IMsgHelper] |
| BlueBubbles | On Tahoe, AppleScript sends to `any;-;` chats failed with -1700 because `any` is not a valid service constant. Fixed in 1.9.10 (#777), which was later pulled. The helper did not connect on Tahoe because of a flat-namespace `_OBJC_CLASS_$_CKChatController` reference and a changed `IMMessageAcknowledgmentChatItem -index` selector (#776, open). The community dylib delayed inbound messages through APNs drops (#779, open). Threaded sends stall (#814, open). A dasd deadlock starves imagent so sends never reach chat.db, fixed by `sudo launchctl kickstart -k system/com.apple.dasd` (#890, open). | [verified issue titles and state, https://github.com/BlueBubblesApp/bluebubbles-server/issues/776, /777, /779, /814, /890; root causes reported in issue comments] |
| imessage-kit | Has a dedicated macOS 26 query builder [verified, src/]. Archived on 2026-06-08, so no further fixes [verified, GitHub API]. | |
| carterlasalle | Active. Reports that outgoing group rows have handle_id 0 and that group iMessages never report delivery on macOS 26 (#105). | [reported, https://github.com/carterlasalle/mac_messages_mcp/issues/105] |
| Anthropic plugin | Uses only chat GUIDs read from chat.db and argv sends, so the `any;` prefix passes through unchanged. | [inferred, server.ts lines 420-424] |
| OpenClaw | Bridge mode verified on 26.5.1 with SIP off and the plist, as quoted above. | [verified, docs/channels/imessage/private-api.md] |
| Deibler/imcore-bridge | Verified by its author on 26.4.1. | [reported, README.md] |

The user's schema dump for macOS 26.2 contains columns that older readers may not handle: `date_edited`, `date_retracted`, `date_recovered`, `thread_originator_guid`, `thread_originator_part`, `associated_message_emoji`, `schedule_type`, `schedule_state`, `was_detonated`, `is_stewie`, `is_kt_verified`, `is_pending_satellite_send` and `message_summary_info` [verified, research/chatdb-schema.sql]. The `chat` table carries `ck_chat_id`, and `chat.style` is 45 for a 1:1 chat and 43 for a group [verified schema; style values verified in anthropics external_plugins/imessage/server.ts lines 147 and 509].

## Output design for the LLM

- **imsg.** Every read command emits NDJSON with a stable documented schema on stdout and sends prose to stderr [verified, docs/json.md]. Chat rows carry routing diagnostics such as `account_id`, `account_login` and `last_addressed_handle` [verified, docs/json.md]. Message rows repeat chat fields and participants on every line, which costs tokens on long histories [verified, docs/json.md message schema]. `imsg completions llm` prints help text written for a model [verified, docs/completions.md]. JSON-RPC methods include chats.list, messages.history, messages.search, messages.after, watch.subscribe, send.tracked and message.send_status [verified, docs/rpc.md].
- **OpenClaw.** It maps long message GUIDs to short numeric IDs before the model sees them [verified, openclaw/openclaw extensions/imessage/src/monitor-reply-cache.ts lines 25-74].
- **imessage-max.** It has 13 tools shaped around questions a user asks, such as find_chat followed by get_messages(since="yesterday"). Its README argues that table-shaped tools need 3 to 5 calls per intent [reported, README.md]. It returns images at three sizes, 1568 px for vision, 400 px thumbnails and full size [verified, README.md and swift/Sources/iMessageMax/Enrichment/ImageProcessor.swift]. It tells the agent to use `chat123`-style IDs internally and human names in replies [verified, README.md].
- **carterlasalle.** It returns plain text wrapped in `<untrusted-mcp-output>` tags, with limit, offset and since_rowid paging [verified, mac_messages_mcp/untrusted.py, server.py and messages.py].
- **Anthropic plugin.** It has two tools, reply and chat_messages. History comes as text with headers like `=== Group name(who) ===`. New messages arrive as channel pushes rather than tool calls. Pairing and allowlists decide which chats the model may read [verified, server.ts lines 292-366 and 503-511].
- **jeffhuber Grok skill.** It exchanges small JSON request and response files. All actions are review, search, chat_history, response_stats, contacts_lookup, send_preview, send and status [verified, SKILL.md].
- **thenavidm.** `--select` picks fields and `--compact` trims output. The author measured MCP tool definitions at about 1,800 tokens on every message, against about 2,200 tokens loaded once for a SKILL.md [reported, README.md].
- **yashodhank.** It emits TOON, a compact tabular text format [reported, README.md].
- **anipottsbuilds.** `sync_messages` returns a cursor so the agent fetches only new rows [verified, repo source].
- **wolfiesch.** It argues that a direct CLI is about 19 times faster than an MCP round trip for the same queries [reported, README.md performance table].

## Common bugs and pitfalls from issue trackers

1. **Text lives in attributedBody, not `text`.** About 93% of rows had only attributedBody, so imsg search silently missed them (#223). imsg's send verifier matched on the `text` column, which modern macOS leaves NULL for sent messages, so every send reported `may_have_completed` (#249). imessage-kit had the same NULL text bug (#2, #16) [verified issue titles, https://github.com/openclaw/imsg/issues/223, https://github.com/openclaw/imsg/issues/249, https://github.com/photon-hq/imessage-kit/issues/2, https://github.com/photon-hq/imessage-kit/issues/16].
2. **Chat lookup error -1728.** A chat GUID can exist in SQLite but be missing from Messages' live chat list, and then `send to chat id` fails (#244) [verified issue title, https://github.com/openclaw/imsg/issues/244]. Looking a chat up by display name with `chat "<name>"` also fails with -1728 [verified, carterlasalle messages.py comment]. Only E.164 numbers with a leading + are reliable as recipients [verified issue title, https://github.com/carterlasalle/mac_messages_mcp/issues/51].
3. **Wrong service.** imessage-kit sent green-bubble SMS when the caller named no service (#39) [verified issue title, https://github.com/photon-hq/imessage-kit/issues/39]. On Tahoe new chats use the `any;-;` and `any;+;` prefixes. Code that turned that prefix into an AppleScript service constant failed with -1700 (#777) [verified issue title, https://github.com/BlueBubblesApp/bluebubbles-server/issues/777]. The dictionary has no `any` service type [verified, research/messages.sdef].
4. **AppleScript success does not mean delivery.** On macOS 26 Messages sometimes reports success but writes an empty, unjoined SMS row (the "ghost row") [verified, openclaw/imsg docs/troubleshooting.md line 65]. Group iMessages may never show delivered (#105) [reported]. Messages can store a tracked send under a different GUID (#385, open) [verified issue title]. The bridge sometimes delivered one request twice, in 15% to 30% of sends (#158) [verified issue title, https://github.com/openclaw/imsg/issues/158].
5. **Watchers that go quiet.** imsg watch stopped seeing new messages after a WAL checkpoint rotated the sidecar files, and the poll fallback did not re-arm (#126) [verified issue title, https://github.com/openclaw/imsg/issues/126]. Opening with `immutable=1` ignores the WAL, so recent messages stay invisible until the next checkpoint, which can take hours [verified, mattt/Madrid Sources/iMessage/Database.swift lines 65-88]. Copying chat.db without chat.db-wal has the same effect [inferred, same source].
6. **Wrong reply parent.** `reply_to_guid` is set on about 87% of rows and points at the previous message, not the quoted one. Use `thread_originator_guid` (#346) [verified issue title, https://github.com/openclaw/imsg/issues/346].
7. **Edit and unsend edge cases.** Unsends that leave `date_retracted` at 0 looked like edits with empty text (#370). Editing or unsending a self-chat's echo row did nothing (#350) [verified issue titles, https://github.com/openclaw/imsg/issues/370, https://github.com/openclaw/imsg/issues/350].
8. **Group events read as empty messages.** Renames and member changes are rows with an `item_type` and `group_action_type` and no text. Readers that ignore those fields print an empty message from the person who renamed the group (#372, open) [verified issue title, https://github.com/openclaw/imsg/issues/372].
9. **Attachment paths.** Messages cannot read files from some locations under newer sandboxing, so projects stage a copy first [verified, openclaw/imsg docs/attachments.md line 64]. imessage-kit once delivered a file named `imsg_temp_*` instead of the image (#34) [verified issue title, https://github.com/photon-hq/imessage-kit/issues/34].
10. **AppleScript injection.** Building the script by pasting in recipient or file path strings let crafted input run AppleScript (#23) [verified issue title, https://github.com/photon-hq/imessage-kit/issues/23]. The safe pattern passes values as argv to `on run` [verified, anthropics server.ts lines 420-424; reported, herald sending.md section 4]. tszaks still interpolates `message_id` into the script source [verified, tszaks index.js lines 3039-3041].
11. **AppleScript commands that do not exist.** tszaks calls `add reaction` and adelaidasofia sets `unread count`. Neither appears in the macOS 26.2 dictionary [verified code; failure inferred from research/messages.sdef].
12. **Permissions attach to the wrong process.** A grant to Terminal does not cover a background LaunchAgent [verified, openclaw/openclaw docs/channels/imessage/troubleshooting.md]. After updating the parent app, the Full Disk Access entry must be toggled off and on [verified, openclaw/imsg docs/permissions.md line 104]. Error -1743 means Automation was denied and -1712 means an Apple event timed out [verified, OpenClaw troubleshooting.md]. A send that worked from Claude Desktop failed from Claude Code because of the `buddy` form (#7) [verified issue title, https://github.com/carterlasalle/mac_messages_mcp/issues/7]. A background process has no window to show the Contacts permission prompt, so names can silently go missing [inferred, TCC behavior described in OpenClaw troubleshooting.md]. RyanNewsom's reader avoids the Contacts permission entirely. It reads the AddressBook SQLite files under ~/Library/Application Support/AddressBook/ read-only under the same Full Disk Access grant and adds a `warning` field when they cannot be read [verified, RyanNewsom/grokbot-imessage-reader README.md lines 72-74].
13. **Private API drift.** IMCore selectors change between point releases (imsg #194, #236). imagent entitlement checks block some calls (imsg #60). The BlueBubbles helper needed Tahoe-specific fixes (#776, #779, #814, #890) [verified issue titles, see the macOS 26 table].
14. **UI scripting breaks with UI changes.** imsg's tapback keystrokes stopped working on macOS 27 (#311) [verified issue title, https://github.com/openclaw/imsg/issues/311].
15. **Spoofed SMS senders.** The Anthropic plugin drops inbound SMS and RCS by default because SMS sender IDs can be forged, while iMessage senders are tied to an Apple ID [verified, server.ts lines 35-38].

## Paid relays and non-Mac options

These fall outside the free, local goal.

- Sendblue, Linq and LoopMessage are paid iMessage relays [verified as dependencies of boop-agent, OpenInstinct and linq-team/claude-code-imessage-channel].
- Photon Spectrum Cloud lists a Free plan on shared lines, Pro at $25 per month and Business at $250 per line per month. Free quotas are reported as 5,000 messages per day and 50 new conversations per line per day [reported, https://photon.codes/pricing]. Photon's local package, spectrum-ts packages/imessage-local, wraps imessage-kit and is free [verified, photon-hq/spectrum-ts].
- pypush and OpenBubbles emulate Apple's protocol without a Mac. That carries terms of service risk [reported, project READMEs].

## Gaps that no free project fills

- No project sends a location pin [verified, absence across all surveyed send code].
- imsg does not convert HEIC and does not shrink images for vision models [verified, openclaw/imsg docs/attachments.md].
- Both Grok-specific projects are text-only and refuse group sends [verified, see above].
- imsg's NDJSON repeats chat fields per message, and no project combines a compact output format with the full imsg feature set [inferred, output design section].
- Starting a group chat without the private API has no working AppleScript path [reported, herald sending.md section 5.2].

## Implications for a Grok Bot repo

These follow from the findings and are [inferred].

- imsg already covers the free base path and the opt-in bridge. A thin layer on top of it could add compact output, HEIC conversion and Grok-specific setup instructions without rewriting the read and send engine.
- The free tier should stay SIP-on. The private API tier needs SIP off and the library validation plist on macOS 26 and should be a separate, explicit step.
- Send verification should use the three imsg dispositions and never auto-retry `may_have_completed`.
- Full Disk Access is safer on a small helper app bundle started by a LaunchAgent, as RyanNewsom and jeffhuber do, than on the Grok runtime itself.

## Source index

| Repo | URL | Local clone |
|---|---|---|
| openclaw/imsg | https://github.com/openclaw/imsg | /tmp/gbim-research/repos/openclaw_imsg |
| BlueBubblesApp/bluebubbles-server | https://github.com/BlueBubblesApp/bluebubbles-server | /tmp/gbim-research/repos/BlueBubblesApp_bluebubbles-server |
| BlueBubblesApp/bluebubbles-helper | https://github.com/BlueBubblesApp/bluebubbles-helper | /tmp/gbim-research/repos/BlueBubblesApp_bluebubbles-helper |
| photon-hq/imessage-kit | https://github.com/photon-hq/imessage-kit | /tmp/gbim-research/repos/photon-hq_imessage-kit |
| photon-hq/advanced-imessage-kit | https://github.com/photon-hq/advanced-imessage-kit | /tmp/gbim-research/repos/photon-hq_advanced-imessage-kit |
| photon-hq/advanced-imessage-ts | https://github.com/photon-hq/advanced-imessage-ts | /tmp/gbim-research/repos/photon-hq_advanced-imessage-ts |
| photon-hq/spectrum-ts | https://github.com/photon-hq/spectrum-ts | /tmp/gbim-research/repos/photon-hq_spectrum-ts |
| carterlasalle/mac_messages_mcp | https://github.com/carterlasalle/mac_messages_mcp | /tmp/gbim-research/repos/carterlasalle_mac_messages_mcp |
| anthropics/claude-plugins-official | https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/imessage | /tmp/gbim-research/repos/anthropics_claude-plugins-official |
| openclaw/openclaw | https://github.com/openclaw/openclaw | /tmp/gbim-research/repos/openclaw_openclaw |
| ReagentX/imessage-exporter | https://github.com/ReagentX/imessage-exporter | /tmp/gbim-research/repos/ReagentX_imessage-exporter |
| jeffhuber/grokbot-imessage-skill | https://github.com/jeffhuber/grokbot-imessage-skill | /tmp/gbim-research/repos/jeffhuber_grokbot-imessage-skill |
| RyanNewsom/grokbot-imessage-reader | https://github.com/RyanNewsom/grokbot-imessage-reader | /tmp/gbim-research/repos/RyanNewsom_grokbot-imessage-reader |
| cyberpapiii/imessage-max | https://github.com/cyberpapiii/imessage-max | /tmp/gbim-research/repos/cyberpapiii_imessage-max |
| tszaks/imessage-mcp | https://github.com/tszaks/imessage-mcp | /tmp/gbim-research/repos/tszaks_imessage-mcp |
| anipottsbuilds/imessage-mcp | https://github.com/anipottsbuilds/imessage-mcp | /tmp/gbim-research/repos/anipottsbuilds_imessage-mcp |
| wyattjoh/imessage-mcp | https://github.com/wyattjoh/imessage-mcp | /tmp/gbim-research/repos/wyattjoh_imessage-mcp |
| hannesrudolph/imessage-query-fastmcp-mcp-server | https://github.com/hannesrudolph/imessage-query-fastmcp-mcp-server | /tmp/gbim-research/repos/hannesrudolph_imessage-query-fastmcp-mcp-server |
| marissamarym/imessage-mcp-server | https://github.com/marissamarym/imessage-mcp-server | /tmp/gbim-research/repos/marissamarym_imessage-mcp-server |
| adelaidasofia/imessage-mcp | https://github.com/adelaidasofia/imessage-mcp | /tmp/gbim-research/repos/adelaidasofia_imessage-mcp |
| yashodhank/macOS-iMessage-MCP-Native | https://github.com/yashodhank/macOS-iMessage-MCP-Native | /tmp/gbim-research/repos/yashodhank_macOS-iMessage-MCP-Native |
| thenavidm/imessage-mcp-cli | https://github.com/thenavidm/imessage-mcp-cli | /tmp/gbim-research/repos/thenavidm_imessage-mcp-cli |
| zohairrk5/imessage-mcp | https://github.com/zohairrk5/imessage-mcp | /tmp/gbim-research/repos/zohairrk5_imessage-mcp |
| macos-cli-tools/imessage-cli | https://github.com/macos-cli-tools/imessage-cli | /tmp/gbim-research/repos/macos-cli-tools_imessage-cli |
| wolfiesch/wolfies-imessage-gateway | https://github.com/wolfiesch/wolfies-imessage-gateway | /tmp/gbim-research/repos/wolfiesch_wolfies-imessage-gateway |
| mattt/Madrid | https://github.com/mattt/Madrid | /tmp/gbim-research/repos/mattt_Madrid |
| daya0576/pi-imessage | https://github.com/daya0576/pi-imessage | /tmp/gbim-research/repos/daya0576_pi-imessage |
| Deibler/imcore-bridge | https://github.com/Deibler/imcore-bridge | /tmp/gbim-research/repos/Deibler_imcore-bridge |
| mautrix/imessage | https://github.com/mautrix/imessage | /tmp/gbim-research/repos/mautrix_imessage |
| ack-ventures/herald | https://github.com/ack-ventures/herald/blob/main/docs/research/sending.md | read through `gh api`, not cloned |
| raroque/boop-agent | https://github.com/raroque/boop-agent | /tmp/gbim-research/repos/raroque_boop-agent |
| Merit-Systems/OpenInstinct | https://github.com/Merit-Systems/OpenInstinct | /tmp/gbim-research/repos/Merit-Systems_OpenInstinct |
| linq-team/claude-code-imessage-channel | https://github.com/linq-team/claude-code-imessage-channel | /tmp/gbim-research/repos/linq-team_claude-code-imessage-channel |
| lucasgelfond/biscotti | https://github.com/lucasgelfond/biscotti | /tmp/gbim-research/repos/lucasgelfond_biscotti |
| macOS 26.2 chat.db schema | local | research/chatdb-schema.sql |
| macOS 26.2 Messages dictionary | local | research/messages.sdef |
