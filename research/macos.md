# What macOS 26.2 Messages lets an agent do

Written 2026-11-05 on the target Mac: macOS 26.2 build 25C56, Messages 26.0 build 1450.300.41.1.4, SIP enabled.

## Summary

- Without touching SIP, an agent can read everything Messages stores and can send text and files. Reading means opening `~/Library/Messages/chat.db` read-only, which needs Full Disk Access. Sending uses the AppleScript `send` command, which needs Automation permission for Messages.
- Messages has no scripting API for tapbacks, replies, edits, unsends, typing, mark read, group changes, or Send Later. These exist only in the Messages UI. An agent can reach them through Accessibility, but only for messages that are on screen in the open chat. This kind of automation has already broken once between macOS releases.
- The private IMCore methods for all of those actions still exist in 26.2. Calling them means injecting a dylib into Messages. That needs SIP off and library validation off. On 26.4 and later it has also needed AMFI boot-args. An agent cannot do these steps because they need a reboot into recoveryOS, and they leave the Mac in Permissive Security.
- Grok Bot already ships a Messages integration in its Computer Use sidecar. It snapshots chat.db, copies attachments, sends text to a participant or chat id, looks up contacts, and checks permissions. A new repo should fill the gaps and should not rebuild these.
- TCC charges a command-line tool to its responsible app. A CLI started from Grok Bot's shell is charged to Grok Bot.app, `com.anysphere.sand`. That app has the apple-events entitlement but no `NSAppleEventsUsageDescription`. Two public bug reports show that in this setup tccd refuses to prompt and returns -1743. They also say `/usr/bin/osascript` is the exception. On this Mac osascript carries the `com.apple.private.tcc.allow-prompting` entitlement for all services. Sending through osascript is the safest route, but it still needs a first-run test.

## How claims are marked

Every claim has a tag in square brackets with a status and a source id. The source list is at the end.

- verified: I read the file, binary, header, code, or official document myself.
- reported: secondhand, such as an issue, blog, README, or forum post.
- inferred: my own conclusion from the evidence.

A private selector marked verified only exists by name in the 26.2 binary. I did not load or call any private code, and I sent no messages. I did not open anything under `~/Library/Messages`. All schema facts come from the saved schema file.

## Machine facts

- macOS is 26.2 build 25C56, and SIP is enabled with empty boot-args. [verified, L21]
- Messages.app reports version 26.0, build 1450.300.41.1.4, and bundle id `com.apple.MobileSMS`. `NSAppleScriptEnabled` is true and `OSAScriptingDefinition` is `Messages`. [verified, L3]
- Messages is a Mac Catalyst app. Its Info.plist sets `UIDeviceFamily` to 2, and it links the IMCore and ChatKit copies in `/System/iOSSupport`. [verified, L3, L5]
- Messages runs in the App Sandbox with hardened-process and library-validation flags. It is a platform binary with x86_64 and arm64e slices. [verified, L4]
- chat.db uses WAL journal mode and `user_version` 0. [reported, not verified here; L2 records neither]

## The AppleScript dictionary

I dumped the dictionary with `sdef /System/Applications/Messages.app`. It matches `research/messages.sdef` byte for byte. [verified, L1]

### Commands

All three Messages commands are implemented by the Cocoa class `CKScriptCommand`. [verified, L1]

| Command | Parameters | Effect |
|---|---|---|
| `send` | Direct parameter is text or a file. `to` takes a participant or a chat. | Sends one text or one file. |
| `login` | none | Logs in all accounts. |
| `logout` | none | Logs out all accounts. |

The dictionary also pulls in the standard suite: `close`, `count`, `delete`, `duplicate`, `exists`, `make`, `move`, `open`, `print`, `quit`, and `save`, plus the `application`, `document`, and `window` classes. [verified, L1]

### Classes

| Class | Synonym | Cocoa class | Properties | Elements |
|---|---|---|---|---|
| application | | `SMSApplication` | standard | participants, accounts, file transfers, chats. All read-only. |
| participant | buddy | `IMHandle` | `id`, `account`, `name`, `handle`, `first name`, `last name`, `full name`. All read-only. | none |
| account | service | `IMAccount` | `id`, `description`, `enabled` (the only writable property), `connection status`, `service type` | chats, participants |
| chat | | `IMChat` | `id`, `name`, `account`. All read-only. | participants. Read-only, documented as "may be specified at time of creation". |
| file transfer | | `IMFileTransfer` | `id`, `name`, `file path`, `direction`, `account`, `participant`, `file size`, `file progress`, `transfer status`, `started`. All read-only. | none |

[verified, L1]

### Enumerations

- service type: `SMS`, `iMessage`, `RCS`.
- direction: `incoming`, `outgoing`.
- transfer status: `preparing`, `waiting`, `transferring`, `finalizing`, `finished`, `failed`.
- connection status: `disconnecting`, `connected`, `connecting`, `disconnected`.

[verified, L1]

### What the dictionary lacks

The dictionary has no message class, so AppleScript cannot read messages. It has no event handlers, so AppleScript cannot react to incoming messages. It has no commands for tapbacks, replies, edits, unsends, typing, marking read, scheduling, or group changes. The chat name and participant list are read-only. [verified, L1]

### Error strings in the Messages binary

The main binary contains these scripting errors. [verified, L5]

- "Could not resolve "to" parameter to a participant or chat!"
- "Can not send message to a chat you are not a member of!"
- "Could not send specified file!"
- "Message provided is not text or a file!"
- "_handleAppleEvent: expected scene delegate of type 'CKMessagesSceneDelegate'... Dropping Apple Event."

The last string suggests Messages drops Apple Events when it has no window scene of the right type. Keeping a Messages window open may avoid silent drops. [inferred, L5]

## Shortcuts, Siri intents, and App Intents

- Shortcuts has one Messages action, `WFSendMessageAction`. It is built on `INSendMessageIntent` and gated by `WFMessagesAccessResource`. [verified, L8]
- Shortcuts has a Message automation trigger class, `WFMessageTrigger`. [verified, L9] MacStories reports that macOS 26 brought personal automations to the Mac, including a Message trigger that fires on sender or message text. [reported, W1]
- I found no Shortcuts action for tapback, edit, unsend, reply, mark read, or group changes in the ActionKit strings. Absence from a string dump is weak evidence. [verified, L8]
- The Messages Assistant Extension declares these intents: `INEditMessageIntent`, `INSearchForMessagesIntent`, `INSendMessageIntent`, `INPlayMessageSoundIntent`, `INSetMessageAttributeIntent`, and `INUnsendMessagesIntent`. [verified, L6] The edit and unsend intents are public SiriKit classes, available since macOS 14. [verified, L15]
- Only Siri and the system dispatch intents to another app's extension. A third-party process has no public call that hands an intent to Messages. So edit and unsend exist for Siri but not for an agent. [inferred, L6, L15]
- The `MessagesActionExtension` App Intents metadata contains only `ConversationListFocusFilterAction`, which is a Focus filter. [verified, L7]
- `/usr/bin/shortcuts run <name>` runs a saved shortcut from a shell, and `shortcuts sign` signs a shortcut file. [verified, L21] An agent cannot add a shortcut without the user confirming the import in the Shortcuts app. [inferred]

Shortcuts can send, which AppleScript already does. It adds no other Messages action. [inferred, L8]

## Private frameworks

### Method

I listed Objective-C selector names from the `__objc_methname` section of each framework image in the dyld shared cache, using `dyld_info`. I did this for IMCore in both `/System/Library/PrivateFrameworks` and `/System/iOSSupport`, and for ChatKit, IMSharedUtilities, IMDaemonCore, IMDPersistence, IMFoundation, and MessagesKit. [verified, L10 to L13] A name in that section proves the selector exists in some class in that image. It does not prove which class implements it, or that a call from an injected dylib would work.

### Selector findings

| Feature | Selector present in 26.2 | Image | Used by BlueBubbles helper | Judgment |
|---|---|---|---|---|
| Classic tapback | `initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:` then `sendMessage:` | IMCore | Yes. GUID `p:N/<guid>`, type 2000 to 2005, and 3000 to 3005 to remove. | Works if injection works. [verified, L10, G1] |
| Emoji tapback | `instantMessageWithAssociatedMessageContent:associatedMessageGUID:associatedMessageType:associatedMessageRange:associatedMessageEmoji:messageSummaryInfo:threadIdentifier:` | IMCore | No | Untested anywhere I found. [verified, L10, G1] |
| Threaded reply, scheduled send | `instantMessageWithText:messageSubject:flags:threadIdentifier:associatedMessageGUID:scheduledDate:` | IMCore | Not for scheduling | Has both a thread id and a scheduled date. [verified, L10] |
| Edit | `editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:` | IMCore | Yes, passes nil translation | The older selector without `newPartTranslation:` is gone, so code written for macOS 13 to 15 breaks. [verified, L10, G1] |
| Unsend | `retractMessagePart:` | IMCore | Yes | [verified, L10, G1] |
| Typing | `setLocalUserIsTyping:` | IMCore | Yes | imsg reports frequent entitlement errors on 26. [verified, L10, G1; reported, G4] |
| Mark read | `markAllMessagesAsRead`, `markMessageAsRead:`, `markLastMessageAsUnread` | IMCore | Yes | [verified, L10, G1] |
| Rename group | `_setDisplayName:`, `setDisplayName:` | IMCore | Yes | [verified, L10, G1] |
| Group photo | `sendGroupPhotoUpdate:` | IMCore | Yes | A setup guide reports silent failure on Tahoe. [verified, L10; reported, I20] |
| Add or remove member | `addRecipientHandles:`, `removeRecipientHandles:` in ChatKit only. IMCore has `_chat:inviteParticipants:reason:` and `_chat:removeParticipants:reason:`. | ChatKit, IMCore | Yes, the ChatKit pair | [verified, L10, L11, G1] |
| Leave group | `leave`, `canLeaveChat` | IMCore | Yes | [verified, L10, G1] |
| Create or find chat | `chatForIMHandles:`, `existingChatWithGUID:`, `existingChatWithChatIdentifier:` | IMCore | Yes | [verified, L10, G1] |
| Delete | `deleteChatItems:` | IMCore | Yes | imsg reports `deleteChat:` unavailable on 26.5.1. [verified, L10; reported, I5] |
| Scheduled messages | `cancelScheduledMessageWithGUID:`, `editScheduledMessageItem:scheduleType:deliveryTime:`, `editScheduledMessageItem:atPartIndex:withNewPartText:newPartTranslation:` | IMCore | No | [verified, L10, G1] |
| Pins | `_setPinnedConversationIdentifiers:withChatMetadata:updateReason:shouldUpdateStores:` replaces the absent `setPinnedConversationIdentifiers:withUpdateReason:` | IMCore | Yes, old form | Old pin code breaks. [verified, L10, G1] |
| Polls | `isPollsEnabled`, `pollOptionsFromChatItem:...`, `IMBalloonBundleIdentifierPolls` = `com.apple.messages.Polls` | IMCore, IMSharedUtilities | No | No known send path. [verified, L10, L12] |
| Backgrounds | `setTranscriptBackgroundAndSendToChat:transferID:` | IMCore | No | [verified, L10] |
| Junk | `_chat_markAsSpam:...` | IMCore | No | [verified, L10] |
| Apple automation hooks | `IMCoreAutomationPerformOperationWithDictionary:`, `_automation_markAsRead...`, and the entitlement string `com.apple.private.IMCore.IMAutomationMessageSend` | IMCore | No | Looks like an internal test hook gated by a private entitlement that third parties cannot hold. [verified, L10; inferred] |

IMSharedUtilities also exports `IMMessageEditTimeout`, `IMMessageRetractionTimeout`, `IMServiceCapabilityEditMessage`, `IMServiceCapabilityPolls`, and the `IMMessageSummaryInfo*` keys. [verified, L12]

## chat.db by feature

This section covers the columns that matter for features. The full schema is in `research/chatdb-schema.sql`. [verified, L2]

### Time

`message.date`, `date_read`, `date_delivered`, `date_played`, `date_edited`, `date_retracted`, and `date_recovered` count nanoseconds since 2001-01-01 UTC. Unix seconds equal the value divided by 1e9, plus 978307200. [verified, L2, G3 `util/dates.rs`]

### Text and attachments

- `message.text` is often NULL on recent macOS. The text then lives only in `attributedBody`. [reported, G3]
- `message.part_count` counts message parts. A tapback targets one part through the `p:N/` prefix. [verified, L2, G1]
- In `attachment`, the useful columns are:
  - `filename`, `uti`, `mime_type`, `transfer_name`, and `total_bytes`
  - `transfer_state`, where 5 is reported to mean done
  - `is_outgoing`, `is_sticker`, `sticker_user_info`, `attribution_info`, `hide_attachment`, and `is_commsafety_sensitive`
  - `emoji_image_content_identifier` and `emoji_image_short_description`, used for Genmoji
  - `preview_generation_state`

  [verified, L2; transfer_state meaning reported]
- `message_attachment_join` links messages to attachments. [verified, L2]

### Identity and routing

- `message.handle_id` points to `handle.ROWID`. `handle.id` is the phone number or email. `handle` also has `service`, `country`, `uncanonicalized_id`, and `person_centric_id`. [verified, L2]
- `message.service` holds `iMessage`, `SMS`, or `RCS`. `message.account`, `account_guid`, and `destination_caller_id` show which of your addresses sent or received the message. [verified, L2]
- `chat.guid` is the id that AppleScript `chat id` takes. Its other routing columns are `chat_identifier`, `service_name`, `last_addressed_handle`, and `last_addressed_sim_id`. [verified, L2]
- `chat.style` is 43 for a group and 45 for a direct chat. [verified, G2 `entity/Chat.ts`, `MessageSerializer.ts`]
- `chat_handle_join` lists external members only. Your own handle is not stored there. [reported, G4 groups.md]

### Groups

- `chat` has `display_name`, `room_name`, `group_id`, and `original_group_id`. [verified, L2]
- Group events are message rows with `item_type` 1 to 3. [verified, G3 `models/group_action.rs`]
  - `item_type` 1 with `group_action_type` 0 means someone was added. With 1 it means someone was removed. `other_handle` says who.
  - `item_type` 2 is a name change, with the new name in `group_title`.
  - `item_type` 3 with `group_action_type` 0 means someone left. Values 1 to 3 cover group photo changes. Values 4 to 7 cover chat background changes.
- Other `item_type` values: 4 is a location share, 5 is a kept audio or video message, and 6 is FaceTime or SharePlay. Value 7 means transcript sharing stopped and 8 means an emergency location was sent. [verified, G3 `message.rs`]

### Reactions, replies, edits, unsends

- `associated_message_guid` holds `p:N/<guid>` or `bp:<guid>`. `associated_message_type` is 2000 to 2007 for an added reaction and 3000 to 3007 for a removed one. 2006 is an emoji tapback, 2007 is a sticker tapback, 1000 is a sticker, and 4000 is a poll vote. `associated_message_emoji` holds the emoji. `associated_message_range_location` and `_length` give the target range. [verified, L2, G3 `message.rs`]
- `thread_originator_guid` and `thread_originator_part` mark inline replies. `reply_to_guid` also exists. [verified, L2, G3]
- `date_edited` and `message_summary_info` record edits. `message_summary_info` is a binary plist. Its `ec` key holds edit history, `ep` lists edited parts, `rp` lists retracted parts, and `otr` holds original text ranges. [verified columns, L2; reported keys, I3, G3]
- On macOS 15 and 26, an unsend can leave `date_retracted` at 0. In that case Messages clears `text` and `attributedBody`, sets `date_edited`, and adds `rp` to `message_summary_info`. Code that checks only `date_retracted` will misread an unsend as an edit to empty text. [reported, I3]

### Delivery state

`is_sent`, `is_delivered`, `date_delivered`, `is_read`, `date_read`, `is_finished`, and `error` show delivery state. `is_read` and `date_read` on your own outgoing message mean the recipient read it. [verified columns, L2; meaning inferred] The index for undelivered messages filters on `service IN ('iMessage','RCS')` and `schedule_type == 0`, so SMS has no delivered state. [verified, L2; inferred meaning]

### Scheduling, filtering, and other features

- Send Later rows use `schedule_type` and `schedule_state`. The index `message_idx_is_scheduled_message` filters on `schedule_type=2`, so 2 means scheduled. [verified, L2; meaning inferred] The table `scheduled_messages_pending_cloudkit_delete` also exists. [verified, L2]
- `chat.is_filtered` is 0 for the main list, 1 for Unknown Senders, and 2 for Junk. [verified, G3 `tables/chat.rs`]
- These columns appear in the schema without a confirmed meaning. [verified, L2]
  - In `message`: `is_spam`, `has_unseen_mention`, `is_kt_verified`, `is_time_sensitive`, `is_critical`, `is_sos`, `is_stewie`, `is_pending_satellite_send`, `sent_or_received_off_grid`, and `needs_relay`
  - In `chat`: `is_blackholed`, `is_pending_review`, and `is_archived`
- `balloon_bundle_id` and `payload_data` carry app messages. Examples are `com.apple.messages.Polls` for polls and `com.apple.SafetyMonitorApp.SafetyMonitorMessages` for Check In. [verified, L2, G3]
- `expressive_send_style_id` holds the effect id, such as `com.apple.messages.effect.CKHappyBirthdayEffect`. [verified, L2, G3 tests]
- Recently Deleted lives in `chat_recoverable_message_join`, which has `delete_date`, and in `recoverable_message_part`, which has `part_text`. Related tables are `deleted_messages` and `unsynced_removed_recoverable_messages`. [verified, L2]

### Why nothing outside Messages should write chat.db

The triggers call custom SQL functions that exist only inside Apple's processes: `verify_chat`, `delete_attachment_path`, `before_delete_attachment_path`, `after_delete_message_plugin`, `delete_chat_background_before_deleting_chat`, `is_mic_enabled`, and `guid_for_chat`. A write from another process would fail or skip Apple's side effects. [verified function names, L2; consequence inferred]

`user_version` is 0, so it cannot identify the schema version. Detect features with `PRAGMA table_info(message)` instead. [inferred, L2]

## Schema changes through macOS 26

| Change | Evidence in 26.2 | When it arrived |
|---|---|---|
| Edit and unsend: `date_edited`, `date_retracted`, `message_summary_info` | Columns present [verified, L2] | Edit and unsend need macOS 13 or later [verified, A2], so macOS 13 [inferred] |
| Unsend no longer sets `date_retracted` | | macOS 15 and 26 [reported, I3] |
| Send Later: `schedule_type`, `schedule_state` | Columns and index present [verified, L2] | Send Later needs macOS 15 or later [verified, A3] |
| Emoji and sticker tapbacks: types 2006 and 2007, `associated_message_emoji` | [verified, L2, G3] | macOS 15 [inferred] |
| Text formatting and effects in `attributedBody`: `__kIMTextBold`, `__kIMTextItalic`, `__kIMTextUnderline`, `__kIMTextStrikethrough`, `__kIMTextEffectAttributeName` | Keys in IMSharedUtilities [verified, L12] | macOS 15 [inferred] |
| Genmoji: `emoji_image_content_identifier`, `emoji_image_short_description`, `__kIMEmojiImageAttributeName` | [verified, L2, L12] | macOS 15 [inferred] |
| RCS as a service | Enum value and index filter [verified, L1, L2] | Not dated here |
| Polls: `com.apple.messages.Polls`, vote rows with type 4000 | [verified, G3, L12] | macOS 26 [reported, W1] |
| Chat backgrounds: group action 4 to 7, delete trigger | [verified, G3, L2] | macOS 26 [reported, W1] |
| Unknown Senders screening: `is_filtered` 1 | [verified, G3] | macOS 26 [reported, W1] |
| Chat GUIDs become `any;-;<handle>` and `any;+;chat<digits>` | | macOS 26. BlueBubbles server says Tahoe migrated every chat to the `any` prefix, and legacy `iMessage;-;` GUIDs then fail in AppleScript with -1728. [reported, G2 `chatGuid.ts`, I6] |

## Decoding attributedBody

`attributedBody` is an `NSAttributedString` archived in Apple's old typedstream format, the one `NSArchiver` writes. [reported, G3] There are four ways to decode it.

1. **NSUnarchiver in a small Swift helper.** `+[NSUnarchiver unarchiveObjectWithData:]` is deprecated but still declared in the 26.2 SDK. [verified, L14] It returns the full attributed string with Apple's attributes. [inferred] The useful attributes are:
   - `__kIMMessagePartAttributeName`, the part index that a tapback's `p:N` refers to
   - `__kIMFileTransferGUIDAttributeName`, which marks where an attachment sits
   - `__kIMMentionConfirmedMention`
   - `__kIMOneTimeCodeAttributeName`
   - `__kIMDataDetectedAttributeName`
   - `__kIMInlineMediaWidthAttributeName` and `__kIMInlineMediaHeightAttributeName`
   - `__kIMFilenameAttributeName`
   - the text style and effect keys

   [verified names, L12] `NSUnarchiver` has no class allowlist. The blobs come from Apple's own daemon, so the risk is low but not zero. [inferred] This option adds no dependency and no license.
2. **Byte scan.** imessage-exporter's fallback finds the start bytes `0x01 0x2B`, reads the string, and stops at `0x86 0x84`. It returns plain text only, with U+FFFC for each attachment and U+FFFD for app messages. [verified, G3 `util/streamtyped.rs`] It is about 40 lines in any language. It can fail on unusual archives. [inferred]
3. **crabstep.** imessage-exporter pins this Rust typedstream parser at version 0.7.0. [verified, G3 `Cargo.toml`] GitHub lists its license as GPL-3.0, and it was last pushed on 2026-09-16. [verified, W3]
4. **python-typedstream.** GitHub lists its license as GPL-3.0, and it was last pushed on 2023-06-26. [verified, W3]

imessage-exporter itself is GPL-3.0. [verified, G3 `LICENSE`] Copying GPL code into a shareable repo would make the repo GPL. A Swift helper that calls `NSUnarchiver`, with the byte scan as a fallback, avoids that. [inferred]

## AppleScript quirks

### Addressing

- Use `chat.guid` from chat.db as the `chat id`. On Tahoe that is `any;-;+15551234567` or `any;+;chat123...`. Sends by chat id and by participant both work on 26.4 with SIP on, including from a LaunchAgent. [reported, I6]
- An `osascript` exit code of 0 does not mean the message went out. Check `error`, `is_sent`, and `is_delivered` in chat.db. The first send after Messages launches can take about 60 seconds. [reported, I6]
- Some chats exist in chat.db but not in AppleScript's live `chats` collection. These sends fail with -1728. Sending to the participant instead works for direct chats. [reported, I2, I7]
- A handle with no prior chat is addressed as `participant "<handle>" of (1st account whose service type = iMessage)`. In AppleScript, `account` and `service` are synonyms. BlueBubbles uses this form as its 1:1 fallback. [verified, G2 `scripts.ts`] Grok Bot's helper uses `set targetService to 1st service whose service type is ...` and then `send targetText to participant "..." of targetService`. [verified, L18] I found no 26.2 report for a handle with no history. [open question]
- AppleScript cannot pick which of your numbers or addresses sends the message. It can only pick the service. [reported, G4 send.md]

### Groups

- On Tahoe 26.3.1, sending to a group by chat id is unreliable. `any;+;chat...` fails with -1728. `any;-;chat...` reports success but writes an empty SMS row that is not joined to the group. The imsg maintainer could not make it deliver and now detects the false success instead. [reported, I1, G4 groups.md]
- `make new chat with properties {participants: {...}}` is in the dictionary through the standard `make` command. BlueBubbles tries it twice, then guesses the new chat from the database. [verified, G2 `scripts.ts`, `actions.ts`] It errors on Sonoma. [reported, I13] Treat creating a group from AppleScript as unsupported.

### Attachments

- On 26.x, send `(POSIX file "/path" as alias)`. A bare path or a POSIX file without `as alias` fails. Files under `~/Pictures` work. [reported, I9, I10, I12]
- The failure is silent. Files in `~/Documents` give error 34. [reported, I9, I11]
- Messages' sandbox gives it read-write access to these locations [verified, L4]:
  - `~/Library/Messages/` and `~/Downloads`
  - user-selected files
  - `/private/var/tmp/com.apple.messages/`
- An alias sent in an Apple Event normally carries a sandbox extension for that file. That would explain why `as alias` matters. [inferred] Desktop, Documents, and Downloads also need Messages' own folder consent, and `~/Pictures` does not. That would explain the Documents failure. [inferred]
- imsg stages files in `~/Library/Messages/Attachments/imsg/` and reports that this is more reliable than Desktop or Downloads. [reported, G4 attachments.md] Writing there needs Full Disk Access. [inferred]
- Grok Bot's helper refuses attachment copies from outside Messages' folder and sends text only. [verified, L18 string `attachment_outside_messages`, L19]

### Passing text safely

Grok Bot writes the text to a file and reads it inside the script with `set targetText to (read POSIX file "..." as «class utf8»)`. [verified, L18] This avoids AppleScript quoting bugs and keeps the message out of the process list. [inferred]

### Error codes

| Code | Meaning | Source |
|---|---|---|
| -1743 | `errAEEventNotPermitted`. The user denied Automation, or tccd refused to ask. | [verified, L14] |
| -1744 | `errAEEventWouldRequireUserConsent`. Returned when the sender passed the no-prompt flag. | [verified, L14] |
| -600 | `procNotFound`. The target app is not running, which `AEDeterminePermissionToAutomateTarget` returns. | [verified, L14] |
| -1728 | The object was not found, such as an unknown chat id. | [reported, I2, I6] Grok Bot maps -1728 and -1700 to `messages_addressing_failed`. [verified, L19] |
| -1712 | Apple Event timeout. Grok Bot maps it to `messages_not_responding`. | [verified, L19] |

After a denial, `tccutil reset AppleEvents <bundle id>` clears the decision so the prompt can appear again. It cannot grant access. [verified usage, L21; effect inferred]

## UI scripting

Messages exposes an Accessibility tree because it is a Catalyst app. [inferred, L3]

### Evidence

- Each message bubble on macOS 26 is an `AXGroup` with id `Sticker`. It has named actions `Heart`, `Thumbs up`, `Thumbs down`, `Ha ha!`, `Exclamation mark`, and `Question mark`. `AXUIElementPerformAction` applies the tapback without opening the picker. [reported, I14]
- The same report says a tapback menu item does not exist on Tahoe, and that cross-process keystrokes to the picker fail. [reported, I14]
- Apple documents these shortcuts. [verified, A1]

  | Shortcut | Action |
  |---|---|
  | Command-E | Edits a sent message. |
  | Command-R | Replies to the last incoming or the selected message. |
  | Command-T, then 1 to 6 | Adds a tapback to the last or selected message. |
  | Shift-Command-U | Marks a conversation read or unread. |
  | Delete | Deletes the selected message. |
  | Option-Command-I | Opens the Info view, where group name and members live. |
  | Control-Command-1 to 5 | Switch the conversation filter. |
  | Command-1 to 9 | Jump to a pinned conversation. |

- Unsend is Control-click and Undo Send, within 2 minutes. Edit is allowed up to five times within 15 minutes. Both work only with iMessage, and only when both sides run macOS 13, iOS 16, or later. [verified, A2]
- Send Later needs macOS 15 or later and iMessage. It schedules up to 14 days ahead, keeps the message on Apple's server, and needs the Mac to be online. [verified, A3]
- imsg's keystroke tapback stopped working on macOS 27. The fix opens the chat by database id, waits for composer focus, and presses the picker button. [reported, I4, G4 send.md] imsg also notes that sending the same tapback twice removes it. [reported, G4 send.md]
- An AX prototype could find, focus, and set the compose field in the background in under 15 ms. Nobody tested whether this shows a typing bubble on the other device, and the work stopped because it needs the target chat focused. [reported, I16]
- Reading incoming typing without private APIs was judged not possible on Tahoe. Unified logs, the dictionary, and IMCore gave nothing usable. [reported, I15]
- ChatKit contains the URL templates `messages://open?addresses=%@`, `messages://open?message-guid=%@`, `sms://open?groupid=`, and `sms://open?message-guid=`. [verified, L11] They might let an agent open a chat or scroll to a message before acting on it. [inferred, untested]

### Limits

- Every UI action needs the chat open with the target message rendered. [reported, I14, I15]
- UI actions need the screen unlocked. [inferred]
- UI actions take over Messages while the user may be using it. [inferred]
- Keystrokes need Messages frontmost. Named AX actions do not. [reported, I14]
- Each new macOS release can move the elements. [reported, I4]
- Accessibility permission goes to the responsible app. If the agent drives the UI through System Events, it also needs Automation for System Events. [reported, G4 send.md; inferred]

## Private API status and risks

- BlueBubbles' Private API requires disabling SIP and library validation. [reported, I19]
- On 26.4, the BlueBubbles helper crashed Messages. [reported, I17]
  - One reported fix is a patched helper, willsigmon v0.0.22-tahoe. [reported, I17, I18]
  - The other reported fix adds the boot-args `amfi_get_out_of_my_way=1 amfi_allow_any_signature=1 -arm64e_preview_abi ipc_control_port_options=0`. [reported, I17, I18]
  - A commenter traced the 26.5 crash (build 25F71) to dyld aborting on a flat-namespace bind to `_OBJC_CLASS_$_CKChatController`. [reported, I17]
- Another fork says private-API typing is dead on Tahoe. Launch constraints block dylib injection there, and imagent's XPC needs Apple-private entitlements. [reported, I16] This conflicts with the BlueBubbles reports that injection works with boot-args.
- imsg's docs say macOS 26 tightened library validation and added imagent entitlement checks, so the private tier is "increasingly limited". The maintainers recommend against it for agents. [reported, G4 advanced-imcore.md]
- A setup guide reports that edits and group icon updates fail silently on Tahoe even with the Private API. [reported, I20]
- MacForge, an older injection tool, was last pushed on 2023-07-04. [verified, W2]
- Apple describes Permissive Security as much more insecure, and it is required to run unsigned kernel code. [verified, A4] Turning SIP off also turns off kext signature enforcement. [verified, A4]
- Disabling SIP needs `csrutil disable` from recoveryOS, which means a reboot and the user's credentials. [reported, I19] An agent cannot do this. [inferred]
- The selectors changed between releases. Edit gained `newPartTranslation:`, pins moved to a new selector, and `deleteChat:` is reported gone on 26.5.1. A private tier would need retesting on every point release. [verified, L10; reported, I5]

For a free, shareable repo that an agent sets up alone, the private tier does not fit. At most it can be an opt-in that the user enables by hand. [inferred]

## TCC permissions

### Which permission each operation needs

| Operation | Permission | Who holds it |
|---|---|---|
| Read chat.db and attachments | Full Disk Access (`kTCCServiceSystemPolicyAllFiles`). It never prompts, so the user must toggle it in Settings. | Responsible app [reported, G4 permissions.md, A5] |
| AppleScript send, login, logout | Automation for Messages (`kTCCServiceAppleEvents`). It prompts once per sender and target pair. | Responsible app [reported, G4, A5] |
| Contact names | Contacts (`kTCCServiceAddressBook`). Full Disk Access does not cover Contacts.framework. | Responsible app [reported, G4 permissions.md] |
| UI actions | Accessibility, plus Automation for System Events if the agent uses System Events | Responsible app [reported, G4 send.md; inferred] |
| Screenshots of Messages for checking | Screen Recording | Responsible app [inferred] |

### Checking permissions without surprise prompts

| Permission | Silent check |
|---|---|
| Full Disk Access | There is no query API. Open `~/Library/Messages/chat.db` with `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)` and run `SELECT count(*) FROM sqlite_schema`. An open or authorization error means no access. This never prompts. Grok Bot's helper does the same: it links `sqlite3_open_v2` and contains `BEGIN; SELECT count(*) FROM sqlite_schema` and `chat_db_unreadable_at_`. [verified, L18; no-prompt behavior reported, G4] |
| Automation | Launch Messages hidden with `open -gj -a Messages`. Then call `AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false)`. It returns 0 when allowed, -1744 when it would prompt, -1743 when denied, and -600 when Messages is not running. [verified, L14] Grok Bot's helper imports this function. [verified, L18] No shell command does this silently. Plain `osascript` against Messages prompts if the user has not decided yet. [inferred] |
| Contacts | `CNContactStore.authorizationStatus(for: .contacts)` returns not determined, restricted, denied, or authorized without prompting. The Limited status in the header is iOS only. [verified, L14] |
| Accessibility | `AXIsProcessTrusted()`, or `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt` set to false. [verified, L14] |

Each check answers for the process that runs it, and TCC charges that process to its responsible app. Run the checker the same way the sender will run. [inferred, A5]

Building the checker means compiling about 60 lines of Swift with `swiftc` at setup. Command Line Tools are installed on this Mac. [verified, L21 SDK listing; inferred]

### Settings URLs

Grok Bot's helper uses this form. [verified, L18]

- `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` for Full Disk Access
- `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation`
- `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts`
- `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`
- `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture`

The Privacy and Security extension's bundle id is `com.apple.settings.PrivacySecurity.extension`. Its `legacyBundleIdentifier` is `com.apple.preference.security`, and `allowsXAppleSystemPreferencesURLScheme` is true. These anchors exist in its binary: `Privacy_AllFiles`, `Privacy_Automation`, `Privacy_Contacts`, `Privacy_Accessibility`, `Privacy_ScreenCapture`, `Privacy_DesktopFolder`, `Privacy_DocumentsFolder`, and `Privacy_DownloadsFolder`. There is no Pictures anchor. `TCCServiceList.plist` maps `kTCCServiceSystemPolicyAllFiles` to `Privacy_AllFiles` and `kTCCServiceAddressBook` to `Privacy_Contacts`. [verified, L16] The older form `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` should still route through the legacy id. [inferred, L16] Open either form with `/usr/bin/open`.

### The responsible app

Quinn from Apple DTS describes how TCC picks the responsible code. [reported, A5]

- A tool run from Terminal is charged to Terminal.
- A child process of an app is charged to that app.
- A launchd agent installed with `SMAppService` is charged to the app that installed it. Other agents should name their app with `AssociatedBundleIdentifiers`.
- Grants follow the code-signing identity, so that identity must stay stable.

#### CLI launched from Grok Bot's shell

The responsible app is Grok Bot.app, `com.anysphere.sand`. [inferred, A5, L17]

- Grok Bot.app has the `com.apple.security.automation.apple-events` entitlement but no `NSAppleEventsUsageDescription`. [verified, L17]
- VS Code and cmux hit the same setup. tccd logs "Refusing TCCAccessRequestIndirect for service kTCCServiceAppleEvents ... without NSAppleEventsUsageDescription key". Tools get -1743 with no prompt, and no switch appears in Settings. [reported, I21, I22]
- The VS Code report says `osascript` is the exception and can still make macOS ask. [reported, I21] On this Mac, `/usr/bin/osascript` has the entitlement `com.apple.private.tcc.allow-prompting` set to `kTCCServiceAll`, which fits that report. [verified, L20]
- So a CLI should send Apple Events by running `/usr/bin/osascript`. It should not use NSAppleScript or raw `AESend` from a compiled binary. [inferred]
- Grok Bot.app would also need Full Disk Access. A user who granted Full Disk Access to "Grok Bot Computer Use" has not granted it to Grok Bot.app. [inferred, A5]
- I have not tested whether the Automation grant then appears under Grok Bot or under osascript. [open question]

#### Grok Bot's Computer Use helper

`Grok Bot Computer Use.app`, `co.anysphere.grok-bot-computer-use`, team DCNK4UB866, is an `LSUIElement` app. [verified, L18]

- It has usage strings for Apple Events, Contacts, Accessibility, and Screen Capture. Its Contacts string mentions finding "the people you ask them to text by name". [verified, L18]
- Its entitlements include apple-events and addressbook. [verified, L18]
- Whether TCC charges it to itself or to Grok Bot.app depends on how Grok Bot launches it. I did not confirm this. [open question]

#### LaunchAgent with a bare binary

The binary is its own responsible code. [reported, A5]

- If the binary is ad hoc signed, its identity is its cdhash, so each rebuild loses its grants. [inferred, A5]
- If the agent runs a shell or an interpreter, the grant goes to `/bin/zsh` or `node`. Every other agent that uses the same interpreter then shares that grant. [inferred]
- One user reports AppleScript sends working from a LaunchAgent on 26.4. [reported, I6]
- A background watcher is not needed just to read new messages. A CLI that polls chat.db when Grok runs it is enough. [inferred]

## Grok Bot's existing Messages integration

This matters for scope because part of the job is already done. [verified, L18, L19]

- The app bundle defines tools named:
  - `SendIMessage`
  - `SearchIMessages`
  - `FindIMessageChats`
  - `FetchIMessageAttachment`
  - `CheckIMessagePermissions`
  - `IMessageActivity`
- The helper verbs are:
  - `messages/snapshot`, which copies chat.db and chat.db-wal to a folder
  - `messages/copy-attachment`
  - `messages/send`, which sends text only, to a participant with a service or to a chat id
  - `messages/check-permissions`, which reports `fullDiskAccess`, `automation`, and `contacts`
  - `messages/find-contacts`
  - `messages/resolve-handles`
- Users can turn Read Texts and Send Texts off for Grok Bot under Connect Apps, then Mac, then Messages. Sends go through approval with "standing grants" per recipient.

None of these verbs cover tapbacks, replies, edits, unsends, typing, mark read, attachments sent out, group creation or changes, or scheduling. [verified, L19 verb list; inferred gap]

## Capability table

Reliability uses these levels:

- High means it works on 26.x, and chat.db can confirm the result.
- Medium means it works with known failure modes.
- Low means it uses the UI, depends on what is on screen, or has conflicting reports.
- None means no method is known.

| Operation | Method without SIP | Reliability | Permission needed | Method with private API |
|---|---|---|---|---|
| Read chats, messages, handles | SQLite read-only on chat.db, aware of WAL | High [verified, L2] | Full Disk Access | Not needed |
| Detect new messages | Poll `message.ROWID` above a saved cursor, or watch chat.db-wal for changes | High [inferred] | Full Disk Access | IMCore notifications in the injected dylib |
| Decode message text | `attributedBody` through `NSUnarchiver`, with the byte scan as fallback | High [verified, L14, G3] | Full Disk Access | Not needed |
| Fetch received attachment | Copy from the `attachment.filename` path | High [verified, L2, L18] | Full Disk Access | Not needed |
| Delivery and read state of sent messages | `is_sent`, `is_delivered`, `date_delivered`, `is_read`, `date_read`, `error` | High for iMessage, none for SMS [inferred, L2] | Full Disk Access | Not needed |
| Send text to existing 1:1 chat | `send` to `chat id "any;-;..."`, with participant fallback on -1728, then confirm in chat.db | High [reported, I6, I2] | Automation for Messages | `IMChat sendMessage:` |
| Send text to new handle | `send` to `participant "..." of (1st account whose service type = iMessage)` | Medium, untested on 26.2 [verified code, G2, L18] | Automation | `chatForIMHandles:` then `sendMessage:` |
| Send text to existing group | `send` to `chat id`, then check for a ghost row. Fallback is opening the chat and setting the compose field through AX, then Return. | Low on 26.3.1 and later [reported, I1] | Automation, Full Disk Access to confirm, Accessibility for fallback | `sendMessage:` on the group `IMChat` |
| Send file | `send (POSIX file p as alias)`, with the file staged in `~/Pictures/<dir>`, then confirm the attachment row | Medium, fails silently [reported, I9, I10] | Automation, Full Disk Access to confirm | File transfer plus `sendMessage:` with transfer GUIDs |
| Pick service: iMessage, SMS, RCS | `participant of account whose service type = X` | Medium [verified, L1] | Automation | `IMAccount` choice |
| Create group | `make new chat with properties {participants: ...}`, or compose with several recipients in the UI | Low [reported, I13] | Automation or Accessibility | `chatForIMHandles:` [verified, L10] |
| Classic tapback, add or remove | AX named action on the bubble in the open chat, or Command-T then 1 to 6 on the selected message | Low to Medium, last or visible message only [reported, I14, I4] | Accessibility | Associated message type 2000 to 2005, or 3000 to 3005 to remove [verified, G1] |
| Emoji tapback | Tapback picker in the UI, untested | Low [inferred] | Accessibility | `associatedMessageEmoji:` selector, untested [verified, L10] |
| Threaded reply | Select message, Command-R, type, Return | Low [verified, A1; reliability inferred] | Accessibility | `threadIdentifier:` on the new message [verified, L10] |
| Edit own message | Select it, Command-E, replace text, Return. Limit is 15 minutes and 5 edits. | Low [verified, A1, A2] | Accessibility | `editMessageItem:...newPartTranslation:...` [verified, L10] |
| Unsend | Control-click, Undo Send through the AX menu, within 2 minutes | Low [verified, A2] | Accessibility | `retractMessagePart:` [verified, L10] |
| Show typing to others | AX set value in the compose field of the open chat. The remote effect is unverified. | Low [reported, I16] | Accessibility | `setLocalUserIsTyping:`, reported broken on 26 [reported, G4, I16] |
| See others typing | None | None [reported, I15] | none | IMCore observer, reported dead on Tahoe [reported, I15] |
| Mark chat read or unread | Open the chat in Messages, or Shift-Command-U | Low to Medium [verified, A1] | Accessibility | `markAllMessagesAsRead`, `markLastMessageAsUnread` [verified, L10] |
| Rename group | Info view with Option-Command-I, edit name | Low [verified, A1] | Accessibility | `_setDisplayName:` [verified, L10] |
| Add or remove member | Info view | Low [inferred] | Accessibility | ChatKit `addRecipientHandles:` and `removeRecipientHandles:` [verified, L11] |
| Leave group | Info view | Low [inferred] | Accessibility | `leave` [verified, L10] |
| Group photo | Info view | Low [inferred] | Accessibility | `sendGroupPhotoUpdate:`, reported failing on Tahoe [reported, I20] |
| Scheduled send | The repo's own timer sends at the due time. Messages' Send Later through the UI is the alternative. | High for own timer, Low for UI [inferred, A3] | Automation | `scheduledDate:` selector, untested [verified, L10] |
| List Messages' scheduled sends | `schedule_type = 2` rows | High [verified, L2] | Full Disk Access | Not needed |
| Delete message | Select it, press Delete | Low [verified, A1] | Accessibility | `deleteChatItems:` [verified, L10] |
| Delete chat | UI | Low [inferred] | Accessibility | `deleteChat:` reported unavailable on 26.5.1 [reported, I5] |
| Read polls and votes | `balloon_bundle_id = 'com.apple.messages.Polls'` and type 4000 rows. The `payload_data` format is undocumented. | Medium [verified, G3] | Full Disk Access | Not needed |
| Create poll or vote | UI only, untested | Low [inferred] | Accessibility | No known path [verified, L10] |
| Send with effect | UI only | Low [inferred] | Accessibility | `expressive_send_style_id` on the message [inferred, L2] |
| Mention someone | UI only. Plain "@Name" text is not a mention. | Low [inferred, L12] | Accessibility | `__kIMMentionConfirmedMention` in the body [inferred, L12] |
| Contact names | Contacts framework | High [reported, G4] | Contacts | Not needed |
| Pin chat | UI | Low [inferred] | Accessibility | `_setPinnedConversationIdentifiers:...` [verified, L10] |
| Report junk | UI | Low [inferred] | Accessibility | `_chat_markAsSpam:...` [verified, L10] |
| Sign in or out, enable account | `login`, `logout`, `enabled` property | Medium [verified, L1] | Automation | Not needed |

## Recommendations

1. Build only the no-SIP tier. Use chat.db read-only for every read. Use `/usr/bin/osascript` for every send. After each send, confirm the result by finding the new outgoing row in chat.db.
2. Run the CLI from Grok Bot's shell and send through `/usr/bin/osascript`, which carries `com.apple.private.tcc.allow-prompting`. Avoid NSAppleScript or `AESend` in a compiled helper, because tccd refuses the indirect request from Grok Bot.app. Test this on first run before building on it.
3. Ship a `doctor` command. It builds a small Swift checker that calls `AEDeterminePermissionToAutomateTarget` with prompting off, `AXIsProcessTrusted`, the Contacts status, and a read-only open of chat.db. It prints one JSON line. It opens the `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_*` URL only when the user asks.
4. Address chats by `chat.guid`. For a direct chat that fails with -1728, fall back to the participant. For groups, check for the ghost SMS row after every send, and fall back to sending through the UI in the open chat.
5. Stage outgoing files in a folder under `~/Pictures`, send them as an alias, and delete the copy after `transfer status` reaches finished. The attachment row in chat.db can also confirm the send.
6. Offer tapback, reply, edit, unsend, mark read, and group changes as opt-in UI commands. Each one opens the chat, acts through named AX actions, holds a lock, and reports failure rather than guessing.
7. Implement scheduled sends with the repo's own timer, so they work for SMS too and need no UI.
8. Leave private APIs out of the default setup. If they are offered at all, document them as a manual opt-in, with a warning that the SIP change cannot be scripted and must be retested on each point release.
9. Reuse Grok Bot's built-in iMessage tools where they already work, and limit the repo to the gaps listed above. Avoid a second set of permission prompts for the same features.
10. Keep output small for token use. Print one line per message with a ROWID cursor, decode only the rows returned, and never send image bytes to the model unless asked.

## Open questions

1. Does `/usr/bin/osascript` started from Grok Bot's shell show the Automation prompt on 26.2? Does the grant then appear under Grok Bot or under osascript?
2. Does `AXIsProcessTrustedWithOptions` with prompting on show a prompt for Grok Bot.app? Grok Bot.app has no `NSAccessibilityUsageDescription`.
3. Does Grok Bot launch its Computer Use helper as its own responsible process? If it does, the helper's existing grants do not cover a repo CLI.
4. Do group sends by chat id produce the ghost row on 26.2? The reports cover 26.3.1 and later.
5. Does a participant send reach a handle with no prior chat on 26.2?
6. Does `make new chat` work on 26.2?
7. Does setting the compose field through AX show a typing bubble on the other device?
8. Does `messages://open?message-guid=` scroll to and render a specific message, so AX actions can target messages other than the last one?
9. Does Messages drop Apple Events when its window is closed, given the scene-delegate log string?
10. Can `/private/var/tmp/com.apple.messages/` serve as a staging folder that needs no Full Disk Access?
11. What format does poll `payload_data` use?
12. Do AppleScript sends and AX actions work while the screen is locked?

## Sources

### Local files and commands

- L1: `research/messages.sdef`, from `sdef /System/Applications/Messages.app`
- L2: `research/chatdb-schema.sql`
- L3: `/System/Applications/Messages.app/Contents/Info.plist`
- L4: Messages entitlements from `codesign -d --entitlements`, saved at `/tmp/gbim-research/macos/messages-ents.plist`
- L5: strings of `/System/Applications/Messages.app/Contents/MacOS/Messages`
- L6: `/System/Applications/Messages.app/Contents/PlugIns/Messages Assistant Extension.appex/Contents/Info.plist`
- L7: `/System/Applications/Messages.app/Contents/Extensions/MessagesActionExtension.appex`, `Metadata.appintents`
- L8: strings of `/System/Library/PrivateFrameworks/ActionKit.framework`, dump at `/tmp/gbim-research/macos/ActionKit.cstr`
- L9: strings of `/System/Library/PrivateFrameworks/WorkflowKit.framework`, dump at `/tmp/gbim-research/macos/WorkflowKit.cstr`
- L10: IMCore selector and string dumps from the dyld shared cache: `/tmp/gbim-research/macos/imcore.methname`, `imcore.sels`, `ios-IMCore.sels`, `IMCore.cstr`
- L11: ChatKit dumps from `/System/iOSSupport`: `/tmp/gbim-research/macos/ios-ChatKit.sels`, `ios-ChatKit.cstr`
- L12: IMSharedUtilities dumps: `/tmp/gbim-research/macos/IMSharedUtilities.sels`, `IMSharedUtilities.cstr`, `imcore.exports`
- L13: IMDaemonCore, IMDPersistence, IMFoundation, and MessagesKit dumps in `/tmp/gbim-research/macos/`
- L14: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk`. Files read: `AE.framework/Headers/AppleEvents.h`, `HIServices.framework/Headers/AXUIElement.h`, `Foundation.framework/Headers/NSArchiver.h`, and `Contacts.framework/Headers/CNContactStore.h`
- L15: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk/System/Library/Frameworks/Intents.framework/Headers/INEditMessageIntent.h` and `INUnsendMessagesIntent.h`
- L16: `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`, including its Info.plist, binary strings, and `Contents/Resources/TCCServiceList.plist`
- L17: `/Applications/Grok Bot.app/Contents/Info.plist` and `codesign -d --entitlements` output
- L18: `/Applications/Grok Bot.app/Contents/Helpers/Grok Bot Computer Use.app`, including its Info.plist, entitlements, and strings and imports of `Contents/MacOS/CUGrokBotService`
- L19: Grok Bot `app.asar` strings, `/tmp/gbim-research/macos/grokbot-asar.strings`
- L20: `/usr/bin/osascript` embedded Info.plist and entitlements
- L21: `sw_vers`, `csrutil status`, `nvram boot-args`, `/usr/bin/tccutil`, `/usr/bin/shortcuts help`, and the SDK listing under `/Library/Developer/CommandLineTools/SDKs`

### Code read

- G1: https://github.com/BlueBubblesApp/bluebubbles-helper at 1ee57f3, `Messages/MacOS-11+/BlueBubblesHelper/BlueBubblesHelper.m`
- G2: https://github.com/BlueBubblesApp/bluebubbles-server at 76d2b2e (v1.9.12, 2026-10-27). Files read:
  - `packages/server/src/server/api/apple/scripts.ts`
  - `api/apple/actions.ts`
  - `databases/imessage/helpers/chatGuid.ts`
  - `databases/imessage/entity/Chat.ts`
  - `api/serializers/MessageSerializer.ts`
  - `services/scheduledMessagesService/index.ts`
- G3: https://github.com/ReagentX/imessage-exporter at 47b7514. Files read:
  - `imessage-database/src/tables/messages/message.rs`
  - `tables/messages/models/group_action.rs`
  - `tables/chat.rs`
  - `util/streamtyped.rs`
  - `util/dates.rs`
  - `imessage-database/Cargo.toml`
  - `LICENSE`
- G4: https://github.com/openclaw/imsg docs. Files read: `docs/advanced-imcore.md`, `docs/permissions.md`, `docs/attachments.md`, `docs/send.md`, and `docs/groups.md`. Local copies are at `/tmp/gbim-research/macos/imsg-*.md`.

### Issues, pull requests, and posts

- I1: https://github.com/openclaw/imsg/issues/90
- I2: https://github.com/openclaw/imsg/issues/244
- I3: https://github.com/openclaw/imsg/issues/370
- I4: https://github.com/openclaw/imsg/issues/311
- I5: https://github.com/openclaw/imsg/issues/146
- I6: https://github.com/nolanmak/Jarvis/issues/1280
- I7: https://github.com/anthropics/claude-plugins-official/issues/1012 and https://github.com/anthropics/claude-plugins-official/issues/1678
- I8: https://github.com/anthropics/claude-plugins-official/issues/1113
- I9: https://github.com/anthropics/claude-plugins-official/issues/6902
- I10: https://github.com/TheProxyCompany/proxy-integrations/pull/6
- I11: https://github.com/akostibas/apple-tools/issues/85
- I12: https://www.macscripter.net/t/sequoia-messages-send-file/76468
- I13: https://www.macscripter.net/t/create-new-chat-in-messages-application/75566
- I14: https://github.com/markthebest12/bluebubbles-server/pull/48
- I15: https://github.com/markthebest12/bluebubbles-server/issues/62
- I16: https://github.com/markthebest12/bluebubbles-server/issues/20, https://github.com/markthebest12/bluebubbles-server/issues/25, and https://github.com/markthebest12/bluebubbles-server/issues/26
- I17: https://github.com/BlueBubblesApp/bluebubbles-server/issues/776
- I18: https://github.com/willsigmon/bluebubbles-helper/releases/tag/v0.0.22-tahoe
- I19: https://docs.bluebubbles.app/private-api/installation
- I20: https://www.stack-junkie.com/blog/openclaw-imessage-bluebubbles-setup-guide
- I21: https://github.com/microsoft/vscode/issues/342365
- I22: https://github.com/manaflow-ai/cmux/issues/3449

### Apple documents

- A1: https://support.apple.com/guide/messages/keyboard-shortcuts-ichtc78b3bff/mac
- A2: https://support.apple.com/guide/messages/unsend-or-edit-messages-ichtd68328c6/mac
- A3: https://support.apple.com/guide/messages/schedule-messages-icht113734b8/mac
- A4: https://support.apple.com/guide/security/startup-disk-security-policy-control-sec7d92dc49f/web
- A5: https://developer.apple.com/forums/thread/756510, a forum post by Quinn of Apple DTS

### Other web sources

- W1: https://www.macstories.net/stories/macos-26-tahoe-the-macstories-review/4/
- W2: https://github.com/MacEnhance/MacForge, push date read from the GitHub API on 2026-11-05
- W3: https://github.com/ReagentX/crabstep and https://github.com/dgelessus/python-typedstream, license and push dates read from the GitHub API on 2026-11-05

I8 covers staging in `~/Library/Messages/` working on macOS 15. It is cited for completeness and is not used in the tables.
