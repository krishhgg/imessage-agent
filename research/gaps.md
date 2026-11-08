# Gaps, contradictions and late answers

This file checks the six research reports in this folder against each other and against the goal. The goal is a shareable repo that Grok Bot can use to set itself up and get full iMessage on macOS 26.2. It must be free, local and token-efficient.

Every claim carries one tag. Verified means I read the code or file, or ran the check on this Mac. Reported means a source says so and I did not reproduce it. Inferred means I reasoned it from verified or reported facts.

Clones used here are read-only and were never executed:

- /tmp/gbim-research/gaps/clones/grok-bot-imessage is jimmyliu03/grok-bot-imessage at commit 0223cfc.
- /tmp/gbim-research/gaps/clones/imessage-bridge is cmer/imessage-bridge at commit f03ae36.
- /tmp/gbim-research/realtime/grok-bot-imessage is steve228uk/grok-bot-imessage at commit 8fe13b8.

No message was sent and nothing under ~/Library/Messages was opened during this work.

## Contradictions between the reports

1. The Grok Bot version in realtime.md is wrong. The installed app and the extracted bundle both say 0.79.2, and realtime.md says 0.78.5. [verified] (/Applications/Grok Bot.app/Contents/Info.plist, /tmp/gbim-research/grokbot/app/package.json)

2. grokbot.md says a send to an `any;` chat id goes over SMS. The code does not do that. Function `Es` only picks the service label that the result reports. The actual AppleScript is `send targetText to chat id "..."`, so Messages routes the send itself. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs at offset 111188)

3. grokcli.md marks it verified that Grok Bot loads skills from ~/.agents/skills. The desktop daemon does contain the skill folder list (.cursor, .claude, .codex, .grok, .agents) and a MergedAgentSkillsService class. Nothing ever constructs that class, and no other bundle uses it. grokbot.md says skills live on the server and get written with UpdateSkill. The steve228uk installer does the same with skill-write. So local skill loading by Grok Bot is unproven. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/main.cjs at offset 2806203, /tmp/gbim-research/realtime/grok-bot-imessage/INSTALL.md)

4. grokbot.md treats Shell as a tool that runs on the Mac. The steve228uk install guide says "Grok Bot's own computer is Linux". It runs Mac commands through tools it calls ExternalShell and ExternalRead. Neither name appears in the desktop bundle, so the server defines the names the model sees. A skill that hard-codes one tool name may break. [verified for the strings, inferred for the risk] (/tmp/gbim-research/realtime/grok-bot-imessage/INSTALL.md, grep of /tmp/gbim-research/grokbot/app/dist)

5. grokbot.md says a local MCP server cannot be reached from Grok Bot because MCP servers run in the cloud box. jimmyliu03 reaches one anyway. It runs MCP on 127.0.0.1:29333, puts a cloudflared HTTPS tunnel in front, and adds the URL as a Custom connector at grok.com/connectors. So tokens.md's five-tool MCP fallback only matters for Grok Bot if the repo ships a tunnel. A tunnel is not fully local, and the connector URL is a bearer secret. [verified for the docs, inferred for the tradeoff] (/tmp/gbim-research/gaps/clones/grok-bot-imessage/GROK_BOT_SETUP.md)

6. The reports disagree on which app gets Full Disk Access. macos.md recommends running the reader from Grok Bot's shell through osascript. That charges access to Grok Bot.app, and the error text in tokens.md tells the user to add Grok Bot to Full Disk Access. grokbot.md and realtime.md say never to give Grok Bot.app Full Disk Access and to use a separate helper. The Computer Use helper co.anysphere.grok-bot-computer-use already holds the grants for the built-in tools. [verified for the report text] (research/macos.md, research/tokens.md, research/grokbot.md, research/realtime.md)

7. grokbot.md calls the routine webhook a cheap wake path. The xAI docs say every routine run uses plan usage. They warn that "an hourly schedule, a short interval, or a Slack trigger on a busy channel can use a week of usage in a day". A webhook fired on every incoming message would cost the same way. [reported] (https://docs.x.ai/grok-bot/skills-routines-and-automations)

8. realtime.md's free wake path wakes the grok CLI, not Grok Bot. The CLI is a separate product. It needs its own `grok login` session or a pay-per-token XAI_API_KEY. The reports never establish whether a Grok Bot plan covers CLI use. [inferred] (research/realtime.md, research/grokcli.md)

9. The private API requirements disagree. macos.md says macOS 26.4 and later need AMFI boot-args. repos.md quotes OpenClaw docs saying 26.5.1 needs only SIP off plus the library validation plist. Neither claim was tested on 26.2. [reported] (research/macos.md, research/repos.md)

10. realtime.md says an unsend sets `date_retracted`. macos.md and repos.md say the field can stay 0 and the edit history in `message_summary_info` is the signal. [reported] (research/realtime.md, research/macos.md, research/repos.md)

11. repos.md's feature matrix and grokbot.md say group sends work by chat id. macos.md rates group sends low because of a ghost row reported on 26.3.1 and later. Nobody checked 26.2. [reported] (research/repos.md, research/grokbot.md, research/macos.md)

12. Three places are given for staging outgoing attachments. imsg uses ~/Library/Messages/Attachments/imsg. macos.md recommends ~/Pictures. The Messages sandbox notes in the reports allow ~/Downloads and /private/var/tmp/com.apple.messages. Writing under ~/Library/Messages also conflicts with this project's own rule against touching that folder. [reported] (research/macos.md, research/repos.md)

13. The draft SKILL.md in tokens.md lists edit, unsend, typing, mark-read and group as ordinary verbs. macos.md and repos.md show each of these needs UI automation or a SIP-off private bridge. A skill that offers them without a capability check will fail on a stock Mac. [verified for the report text] (research/tokens.md, research/macos.md)

14. repos.md says it found "the two Grok-specific repos". At least five exist: jeffhuber/grokbot-imessage-skill, RyanNewsom/grokbot-imessage-reader, steve228uk/grok-bot-imessage, jimmyliu03/grok-bot-imessage and cmer/imessage-bridge. The last three each solve setup in a different way. [verified] (https://github.com/steve228uk/grok-bot-imessage, https://github.com/jimmyliu03/grok-bot-imessage, https://github.com/cmer/imessage-bridge)

15. grokcli.md says Grok Bot probably installs plugins from a `.claude-plugin/marketplace.json` on GitHub. grokbot.md says installs go only through a server catalog plugin_id. Neither tested a GitHub marketplace in Grok Bot. [reported] (research/grokcli.md, research/grokbot.md)

16. macos.md says no watcher is needed. realtime.md builds everything on one. They answer different goals. Reading on demand needs no watcher. Replying on arrival does. The repo needs to pick one default. [inferred] (research/macos.md, research/realtime.md)

17. Grok Bot's built-in fetch-attachment already converts HEIC with sips. repos.md plans its own conversion without counting this. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs, research/repos.md)

## Gaps closed in this pass

### SMS, MMS and RCS through the iPhone

A Mac sends SMS, MMS and RCS only through an iPhone signed in to the same Apple Account. Text Message Forwarding must be on for that Mac in the iPhone's Messages settings. RCS needs iOS 18 or later and carrier support. [reported] (https://support.apple.com/guide/messages/icht8a28bb9a/mac, https://support.apple.com/en-us/102545, https://support.apple.com/en-us/104972)

Grok Bot's built-in send takes iMessage, SMS or auto. It has no RCS option. The AppleScript service enum does include RCS. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs, research/macos.md)

steve228uk and jimmyliu03 both list Text Message Forwarding as a requirement. [verified] (/tmp/gbim-research/realtime/grok-bot-imessage/INSTALL.md, /tmp/gbim-research/gaps/clones/grok-bot-imessage/GROK_BOT_SETUP.md)

### Send-from address

The user picks the address for new conversations in Messages, Settings, iMessage, "Start new conversations from". [reported] (https://support.apple.com/guide/messages/icht39422/mac, https://support.apple.com/en-us/108758)

The Messages AppleScript dictionary has no parameter for it. A script can only target a service or a chat. [verified] (research/macos.md sdef dump)

`message.destination_caller_id` records which of the user's addresses a message used, so the repo can report it. [verified] (research/chatdb-schema.sql)

### Per-chat read receipts

Each conversation's details view has a Send Read Receipts switch. [reported] (https://support.apple.com/guide/messages/ichtee6857f6/mac)

The state is readable as `EnableReadReceiptForChat` in the `chat.properties` plist. The same plist holds `shouldForceToSMS`. [verified in source] (/tmp/gbim-research/repos/ReagentX_imessage-exporter/imessage-database/src/tables/chat.rs)

Changing the switch has no AppleScript path. [inferred] (research/macos.md sdef dump)

### Location

A Mac can use Share My Location or Send My Current Location from the conversation details. Both are UI only. [reported] (https://support.apple.com/guide/messages/icht08e15ab7/mac, https://support.apple.com/guide/messages/icht18df1a6a/mac)

Reading works from chat.db. `item_type` 4 is a location share, where `share_status` 0 means started and 1 means stopped. Placemark balloons also come through the URL balloon provider. [verified in source] (imessage-exporter imessage-database/src/message_types/variants.rs, research/chatdb-schema.sql)

A no-SIP send fallback is a plain Apple Maps link. [inferred]

### Check In

A Mac cannot start a Check In. The macOS 26 Messages guide only covers viewing one. [reported] (https://support.apple.com/guide/messages/ichtf161aa4d/mac, https://support.apple.com/en-gb/guide/messages/icht124f0cb1/14.0/mac/26)

imessage-exporter decodes Check In balloons, so reading works. [verified in source] (imessage-exporter variants.rs)

### Link previews

Text sent through AppleScript likely reaches the recipient with a "Tap to Load Preview" placeholder instead of a rich card. [reported] (https://github.com/photon-hq/spectrum-ts/issues/273, https://register.apple.com/resources/messages/msp-api-tutorial/rich-links)

Incoming previews are readable through the URL balloon payload. [verified in source] (imessage-exporter variants.rs)

### Voice messages

imsg sends .m4a, .caf and .aiff files as ordinary attachments. A native inline voice message needs its SIP-off bridge (`send-attachment --audio`). [verified in docs] (imsg docs/send.md line 70, path cited in research/repos.md)

Incoming voice messages are marked by `is_audio_message`, `is_played` and `date_played`. [verified] (research/chatdb-schema.sql)

Apple's transcript sits in the `IMAudioTranscription` attribute inside attributedBody. That answers the open question in tokens.md. [verified in source] (imessage-exporter imessage-database/src/tables/messages/body.rs and imessage-database/src/tables/messages/models/attachment_meta.rs)

/usr/bin/afconvert exists, so the repo can produce .caf or .m4a with no extra install. [verified] (`ls /usr/bin/afconvert`)

### Polls

imessage-exporter decodes poll payloads. A poll is an NSKeyedArchiver blob holding base64url JSON with optionIdentifier, creatorHandle, text and votes. That answers open question 11 in macos.md. [verified in source] (imessage-exporter imessage-database/src/message_types/polls.rs)

The exporter is GPL-3.0, so porting its code into an MIT repo would force a license change. Reimplementing the format from a description is the usual way around that. [verified for the license, inferred for the consequence] (/tmp/gbim-research/repos/ReagentX_imessage-exporter/LICENSE)

### Stickers and Genmoji

The `attachment` table has `is_sticker`, `sticker_user_info`, `emoji_image_content_identifier` and `emoji_image_short_description`. So reading stickers and Genmoji, including Apple's text description, needs no private API. [verified] (research/chatdb-schema.sql)

### Pinned and muted chats

chat.db has no pinned or muted column. [verified] (research/chatdb-schema.sql)

BlueBubbles headers expose `CKConversation isMuted` and `IMPinnedConversationsController`. imsg's helper uses `chatContextForPinnedChat`. So both states are private API only. [verified in source] (BlueBubbles helper headers and imsg IMsgHelper, as cloned for research/repos.md)

### FaceTime links and contact cards

FaceTime has no scripting dictionary. `sdef /System/Applications/FaceTime.app` fails with error -192, so a script cannot create a FaceTime link. [verified] (local run)

Contacts' dictionary has a `vcard` property. A script could export a .vcf and send it as a file. [verified for the property, inferred for the flow] (`sdef /System/Applications/Contacts.app`)

imsg's `contacts.shareContactCard` is Name and Photo sharing, not a vCard. [verified in docs] (imsg docs/rpc.md line 679)

### Grok Bot's built-in computer use can drive Messages

The computer-use off-limits list covers terminals, Script Editor, Automator, Shortcuts, Keychain Access, Passwords, Cursor builds, System Settings and Grok Bot itself. Messages is not on it. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/main.cjs at offset 2081164)

The tools include computer_screenshot, click, type, key, computer_app_state with accessibility element ids, computer_set_value and computer_app_action. [verified] (same file)

So Grok Bot may already reach tapbacks, edits, unsend and other UI-only features with no repo code. The token cost of screenshots or accessibility trees was not measured. [inferred]

Because System Settings is on the list, Grok Bot cannot flip privacy switches for the user. A person must do it. [inferred] (same file)

### Toolchain on a stock Mac

/usr/bin/git, swift, swiftc and python3 are the same 118880-byte xcrun shim. On a Mac without Command Line Tools they open an install prompt. [verified for the shim, inferred for the prompt] (`cmp` of the four files)

/usr/bin/sqlite3 3.51.0 (with -readonly and -json), osascript, sips, afconvert, shortcuts, plutil, codesign, curl, tar, unzip and ditto are real binaries. [verified] (local `ls` and `--version` runs)

Grok Bot bundles no git. Its daemon runs Node through ELECTRON_RUN_AS_NODE with node:sqlite. [verified] (/tmp/gbim-research/grokbot/app/dist)

Using Grok Bot's binary as a Node runtime would charge every privacy grant to Grok Bot.app. [inferred]

### Reading attributedBody with no compiler

I built a synthetic NSMutableAttributedString typedstream with swiftc and decoded it with a five-line JXA script run by /usr/bin/osascript. The script uses `$.NSUnarchiver.unarchiveObjectWithData` and printed "NSConcreteMutableAttributedString | hello ￼ typedstream 😂". [verified] (/tmp/gbim-research/gaps/mk.swift, /tmp/gbim-research/gaps/dec.js)

With /usr/bin/sqlite3 -readonly, this gives a reader that needs no Command Line Tools, Python or Homebrew. [inferred]

One JXA quirk turned up. `$.NSAttributedString.alloc.initWithString` is not exposed, but archive and unarchive calls work. [verified]

### Signing, Gatekeeper and permission stability

curl does not set com.apple.quarantine, so files fetched with curl or git skip the Gatekeeper check. [reported] (https://unit42.paloaltonetworks.com/gatekeeper-bypass-macos/, https://developer.apple.com/forums/tags/gatekeeper?page=2)

On Apple silicon the linker ad-hoc signs every binary it builds. [reported] (https://github.com/Homebrew/brew/issues/9082, https://eclecticlight.co/2020/08/22/apple-silicon-macs-will-require-signed-code/)

An ad-hoc signature changes on every rebuild, and macOS then drops the privacy grant. A stable signing identity keeps it. [reported] (https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/, https://github.com/multica-ai/multica/issues/8720, https://github.com/NousResearch/hermes-agent/issues/43365)

cmer's README says the same thing: "With a stable Developer ID, the Full Disk Access grant survives rebuilds. With ad hoc signing, you have to grant it again after every rebuild." [verified in docs] (/tmp/gbim-research/gaps/clones/imessage-bridge/README.md)

jimmyliu03 says source builds are ad-hoc signed and public binaries need a Developer ID and notarization. [verified in docs] (/tmp/gbim-research/gaps/clones/grok-bot-imessage/README.md)

A free repo has no Developer ID. A self-signed certificate is the free option, but trusting it likely needs an admin password. [inferred, untested]

### How others handle permissions, updates and uninstall

cmer installs with a Homebrew cask or a curl'd DMG copied into /Applications with ditto. The app has a button that opens the Full Disk Access pane. Grok Bot then pairs with a six-digit code at read or send scope and calls `imessage-bridge call --agent grok-bot <tool>` through its shell. The guide tells Grok Bot not to add a connector. [verified in docs] (/tmp/gbim-research/gaps/clones/imessage-bridge/AGENT_SETUP.md)

cmer updates through Sparkle and documents the paths to delete for uninstall. [verified in docs] (/tmp/gbim-research/gaps/clones/imessage-bridge/README.md)

jimmyliu03 installs with `git clone` and `make install`, then walks the user through in-app setup. That covers Full Disk Access, quit and reopen, a chat allowlist, local approval for writes, launch at login, and Start Bridge. [verified in docs] (/tmp/gbim-research/gaps/clones/grok-bot-imessage/GROK_BOT_SETUP.md)

steve228uk fetches its skill through jsDelivr, saves it with skill-write, installs imsg with Homebrew after a confirm widget, and asks for a confirm widget before every send. [verified in docs] (/tmp/gbim-research/realtime/grok-bot-imessage/INSTALL.md)

Grok Bot's own send tool has a `confirm` flag. Without it the tool returns a preview and sends nothing. [verified] (/tmp/gbim-research/grokbot/app/dist/local-exec-daemon/messages-worker.cjs)

Grok Bot's local-execution setting takes always, ask or never. The local actions it covers include read-messages, send-imessage and run-command. [verified] (Grok Bot renderer bundle, index.eager-app)

tccutil's usage line is `reset SERVICE [BUNDLE_ID]`. It resets by bundle id only, so a bare helper binary cannot be reset on its own. Wrapping the helper in a small .app gives it a bundle id and a stable path for the Full Disk Access picker. [verified for usage, inferred for the fix] (local `tccutil` run)

## Features nobody has a send path for yet

Each of these has no researched no-SIP send path.

- Genmoji. Reading works, but there is no AppleScript or Shortcuts send. [inferred] (research/chatdb-schema.sql, research/macos.md)
- Stickers placed on a bubble, as opposed to a sticker sent as an image file. [inferred]
- Bubble and screen effects. `expressive_send_style_id` is readable, but there is no send parameter. [verified for the column] (research/chatdb-schema.sql)
- Polls. Creating one was not researched. [inferred]
- Send Later. `schedule_type` and `schedule_state` are readable. Creating a scheduled send from a script was not researched. [verified for the columns] (research/chatdb-schema.sql)
- Focus status and "Notify Anyway". `was_delivered_quietly` and `did_notify_recipient` are readable. Sharing or overriding Focus looks private API only. [verified for the columns, inferred for the rest] (research/chatdb-schema.sql)
- Mute and Hide Alerts. There is no chat.db column and no AppleScript verb. [verified for the schema] (research/chatdb-schema.sql)
- Pinning, deleting a chat, deleting a single message, and recovering from Recently Deleted. Only the private bridges and UI automation were mentioned. [inferred] (research/repos.md)
- Unknown-sender filtering. `chat.is_filtered` and `is_pending_review` are readable. Moving a chat between filters was not researched. [verified for the columns] (research/chatdb-schema.sql)
- FaceTime links. There is no dictionary. Grok Bot's computer use is the only lead. [verified for the sdef] (local run)
- Satellite messages and Messages for Business chats. Nobody looked at them. [inferred]

## Setup questions still open

- Whether a non-technical user can finish Full Disk Access without help. The Grok Bot computer-use tool cannot open System Settings, so the skill must give exact clicks and then check the result. [inferred] (main.cjs at offset 2081164)
- Whether osascript started from Grok Bot's shell can raise the Automation prompt for Messages, or fails silently with -1743. Grok Bot.app lacks NSAppleEventsUsageDescription. [untested] (research/macos.md)
- Whether a LaunchAgent helper without AssociatedBundleIdentifiers shows up in the Full Disk Access list under a name the user will recognize. [untested] (research/realtime.md)
- Whether child processes of a granted helper keep its Full Disk Access when launched by launchd. [untested]
- Whether the Full Disk Access picker can select a binary inside the hidden ~/Library folder. Using ~/Applications avoids the question. [inferred]
- How the repo updates itself. git is a shim on a stock Mac, so `git pull` may trigger a Command Line Tools install. A curl plus tar fetch of a tagged release avoids that. [inferred] (cmp check above)
- How the repo uninstalls. It needs to unload the LaunchAgent, delete its files, remove the server-side skill, and reset the privacy grants with tccutil. Nobody has written this down for the Grok Bot case. [inferred]
- Whether Grok Bot routines can use the Mac's local execution at all, or only the cloud computer. [untested] (https://docs.x.ai/grok-bot/skills-routines-and-automations)
- Whether a Grok Bot plan covers grok CLI use for the wake path. [untested] (research/grokcli.md)
- Apple has said Full Disk Access will need "very explicit user action" and named AI agents as the reason, with no version or date. Any setup flow may break on a later macOS. [reported] (https://developer.apple.com/news/?id=p6zjojqw)

## Untested assumptions

- The ghost row on group sends was reported on 26.3.1 and later. Nobody checked 26.2. [reported] (research/macos.md)
- The private bridge requirements on 26.2, covering SIP off, the library validation plist and AMFI boot-args. [reported] (research/macos.md, research/repos.md)
- Creating a group through Shortcuts. [untested] (research/macos.md)
- Concurrent Apple events from Grok Bot's built-in sender and the repo's sender at the same time, which can time out with -1712. [inferred]
- Accessibility action names in non-English macOS locales. A UI script that matches "Reply" or "Tapback" by name will break in other languages. [inferred]
- Messages in iCloud with offloaded attachments. `attachment.filename` may point to a file that is not on disk. [inferred]
- Two Macs on the same Apple Account both running the bot, which would make both reply to every message. [inferred]
- Mac sleep, screen lock and fast user switching. A LaunchAgent stops when the user logs out, and UI automation fails on a locked screen. [inferred] (research/realtime.md launchd notes)
- Server-side truncation of Grok Bot shell output, which limits how many lines one read can return. [untested] (research/grokbot.md)
- Real token counts with Grok's tokenizer. tokens.md estimated with a stand-in. [reported] (research/tokens.md)
- The token cost of a Messages screenshot or accessibility tree through computer use. [untested]
- Apple's terms and the chance of an Apple Account flag for automated sending at volume. Nobody researched it. [inferred]
- A no-send test plan. The repo needs a way to test reads, parsing and send previews without messaging a real person, such as sending to the user's own address or using the `confirm` preview. [inferred] (messages-worker.cjs confirm flag)
