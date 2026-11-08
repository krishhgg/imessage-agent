# Synthetic chat.db fixture

This folder holds a Messages database built from the real macOS 26.2 schema in `research/chatdb-schema.sql`. Every person, number, address and message in it is invented. No real Messages or AddressBook data was read to make it.

Run `./build.sh` to rebuild it. The build regenerates every file listed below from seed 20261106, checks the result with `/usr/bin/sqlite3`, decodes every body with NSUnarchiver, and builds a second copy to confirm the bytes match. Do not edit the generated files by hand. Change `make-fixture/Sources` and rebuild.

## Files

- `chat.db` is the database, 1534 message rows. Its SHA-256 is `a74577080ba55b2f3aeeef2084d91e73a1a7af7a3660198c17a79fb47c89c14f`.
- `Attachments/` holds tiny stand-in files at the paths the attachment rows name, with `~/Library/Messages/Attachments/` replaced by `Attachments/`.
- `contacts.json` is the synthetic address book. Readers should use it instead of AddressBook.
- `manifest.json` has the full edge-case map, every attachment, the expected body digest, decoded samples and the answers for the benchmark tasks.
- `make-fixture/` is the Swift package that writes all of the above. `verify-fixture` in the same package checks it.
- `build.sh` builds, generates, verifies and checks determinism.

## Time

Dates in `message` are Apple-epoch nanoseconds, counted from 2001-01-01 UTC. `attachment.created_date` is in seconds. Local times below are America/Los_Angeles. Messages run from 2025-09-02 10:08:15 to 2026-11-05 22:58:40. The fixture clock reads 2026-11-06 00:30:00, so "last month" means October 2026 and no read time passes that moment.

## Chats

| ROWID | GUID | Kind | Service | Messages | Member handle ROWIDs |
| --- | --- | --- | --- | --- | --- |
| 2 | `any;-;+14155550100` | You (self-chat) | iMessage | 57 | 1 |
| 7 | `any;-;+14155550101` | Mom | iMessage | 311 | 3, 8 |
| 9 | `any;-;+14155550102` | Dad | iMessage | 163 | 4 |
| 12 | `any;+;chat836828054889214904` | Family 🏡 | iMessage | 459 | 3, 4, 5, 6 |
| 19 | `any;+;chat564517051022821277` | unnamed group | iMessage | 206 | 16, 17 |
| 23 | `any;-;jordan.kim@example.com` | Jordan Kim (email handle) | iMessage | 109 | 16 |
| 31 | `any;-;+16505550142` | Sam Lee (RCS) | RCS | 147 | 11 |
| 56 | `any;-;+15105550163` | +1 (510) 555-0163 (SMS, no contact) | SMS | 81 | 14 |

Chat 2 is the self-chat. Chat 7 also holds three SMS rows on Mom's SMS handle, ROWID 8. Chat 12 is named Family 🏡 and was renamed twice. Chat 19 has no name. Chris was removed from it and Riley joined and later left, so neither is in chat_handle_join. Chat 23 uses Jordan's email address and you reply from alex@example.com. Chat 31 is RCS. Chat 56 is SMS with a sender who is not in contacts.

## Handles

| ROWID | ID | Service | Person | In contacts |
| --- | --- | --- | --- | --- |
| 1 | +14155550100 | iMessage | You | yes |
| 3 | +14155550101 | iMessage | Mom | yes |
| 4 | +14155550102 | iMessage | Dad | yes |
| 5 | +14155550103 | iMessage | Priya | yes |
| 6 | +14155550104 | iMessage | Arjun | yes |
| 8 | +14155550101 | SMS | Mom | yes |
| 11 | +16505550142 | RCS | Sam | yes |
| 14 | +15105550163 | SMS | Marco | no |
| 16 | jordan.kim@example.com | iMessage | Jordan | yes |
| 17 | +12125550188 | iMessage | Taylor | yes |
| 18 | +13105550119 | iMessage | Chris | yes |
| 22 | +17075550131 | iMessage | Riley | no |

You are +14155550100 and alex@example.com. In group chats your rows have handle_id 0. In 1:1 chats they carry the other person's handle, the way Messages stores them.

## Counts

- Rows in message: 1534
- Rows in chat_message_join: 1533
- Rows with text NULL and a body only in attributedBody: 1424
- Rows with both text and attributedBody: 102
- Rows with no body, which are group events and unsends: 8
- Tapback rows, types 2000 to 3006: 89
- Group event rows: 5
- Unread incoming rows: 8
- Chats: 8
- Handles: 12
- Attachments: 26
- Attachments with a file on disk: 24
- Attachments offloaded to iCloud: 2
- Permanently deleted messages, the ROWID gaps: 24
- Messages in Recently Deleted: 1

## Bodies

Most rows leave `text` NULL and keep the body only in `attributedBody`. That column is an NSMutableAttributedString, or sometimes an NSAttributedString, archived with NSArchiver. That is the typedstream format, which starts with `streamtyped`. Every character carries `__kIMMessagePartAttributeName`. Attachment parts are one U+FFFC character with `__kIMFileTransferGUIDAttributeName` set to the attachment GUID. URLs carry `__kIMLinkAttributeName`. `verify-fixture` decodes all 1526 bodies and compares them with the digest in manifest.json.

Edits and unsends live in `message_summary_info`, a binary plist. `otr` holds the original part ranges, `ec` holds each edited version as its own typedstream, and `rp` lists the unsent parts. URL balloons keep an NSKeyedArchiver archive of LPLinkMetadata in `payload_data`.

## Schema notes

The generator runs every CREATE TABLE, CREATE INDEX and CREATE TRIGGER statement from the schema file as written. It skips two statements, `CREATE TABLE sqlite_sequence(name,seq)` and `CREATE TABLE sqlite_stat1(tbl,idx,stat)`, because SQLite reserves those names. SQLite creates sqlite_sequence on its own, and the final ANALYZE creates sqlite_stat1.

No triggers were dropped. All 22 triggers are in the database. Some of them call SQL functions that exist only inside Messages: `verify_chat`, `delete_attachment_path`, `before_delete_attachment_path`, `after_delete_message_plugin`, `delete_chat_background_before_deleting_chat`, `guid_for_chat`, `is_mic_enabled`. make-fixture registers stubs for them with `sqlite3_create_function_v2` while it writes. `is_mic_enabled` returns 0 and the rest return NULL. Reading the file works in any SQLite client. A write that fires one of those triggers, such as inserting a chat, needs the same stubs.

The generator relies on real triggers in four places. `after_insert_on_chat_message_join` fills `cache_roomnames`, `chat_service_on_insert_chat_message_join` fills `chat_service`, and `after_insert_on_message_attachment_join` sets `cache_has_attachments`. Deleting from `chat_message_join` makes the delete triggers remove rows and log their guids in `deleted_messages`, and setting `error` on the failed send fills `kvtable`.

## Edge cases

manifest.json has the complete ROWID lists under `edge_cases`. Long lists are cut here.

| Key | ROWIDs | What it is |
| --- | --- | --- |
| `address_decoy_june` | 40850 | An older address from Dad in June 2026. It is a decoy for the address task. |
| `address_last_month` | 41381 | The address Dad sent on 2026-10-14, which is last month relative to the fixture clock. |
| `bold_text` | 41049 | Body with a __kIMTextBoldAttributeName range on the word Reminder. |
| `delivered_no_read_receipt` | 40015, 40074, 40134, 40153, 40193, 40194, 40302, 40303 and 68 more | Outgoing iMessage rows that were delivered in a chat without read receipts, so date_read is 0. |
| `duplicate_same_minute` | 41089, 41090, 41487, 41488 | Two rows from the same sender with identical text inside one minute. |
| `duplicate_text_after_failure` | 41162, 41163 | A failed send and its retry. Both rows have the same text. |
| `edited_once` | 40913, 41427 | Edited one time. date_edited is set and message_summary_info holds both versions under ec. |
| `edited_twice` | 40779 | Edited two times. message_summary_info holds three versions under ec, oldest first. |
| `emoji_zwj_flag` | 41489 | Body made of a ZWJ family emoji, a heart and a flag. |
| `expressive_effect` | 40731 | Message sent with the confetti effect in expressive_send_style_id. |
| `failed_send` | 41162 | Outgoing row with error 4, is_sent 0 and is_delivered 0. The update fired update_last_failed_message_date, so kvtable holds lastFailedMessageDate. |
| `group_add` | 40473 | item_type 1 with group_action_type 0. Jordan added Riley, so other_handle is Riley's handle. |
| `group_leave` | 41144 | item_type 3 with group_action_type 0. Riley left the group. |
| `group_remove` | 40829 | item_type 1 with group_action_type 1. You removed Chris, so handle_id is 0 and other_handle is Chris's handle. |
| `group_rename` | 40016, 40405 | item_type 2 rows. group_title holds the new name. |
| `last_message_overall` | 41558 | The newest row in the database. |
| `link_preview_single_row` | 41434 | URL balloon in one row. The URL is the body and payload_data holds an LPLinkMetadata archive. |
| `link_preview_two_rows` | 40659, 40660 | A text row that contains a URL, then a balloon row for the same URL one second later. Readers should show one message. |
| `link_without_preview` | 40930 | A bare URL with no balloon. The body carries __kIMLinkAttributeName. |
| `long_body` | 40458, 40598, 41266 | Body longer than 400 characters. |
| `long_body_over_8kb` | 40927 | Self-note longer than 8 KB, more than one show call returns. |
| `mention` | 41048 | Body with a __kIMMentionConfirmedMention range on the name Priya. |
| `multiline_body` | 40458 | Body that contains line breaks. |
| `multipart` | 40677, 40945, 41232, 41428 | Message with more than one part. Each part has its own __kIMMessagePartAttributeName index. |
| `nfc_text` | 41070 | NFC text with a precomposed é. |
| `nfd_text` | 41069 | NFD text, an e followed by a combining acute accent. A search for café should still find it. |
| `non_latin_accents` | 40545 | Spanish text with accents and inverted punctuation. |
| `non_latin_devanagari` | 41204 | Hindi text in Devanagari. |
| `non_latin_hangul` | 41002 | Korean text in Hangul. |
| `non_latin_vietnamese` | 40941 | Vietnamese text with stacked diacritics. |
| `nsattributedstring_class` | 40008, 40010, 40014, 40020, 40025, 40026, 40030, 40031 and 205 more | Bodies archived as NSAttributedString instead of NSMutableAttributedString. Real databases contain both. |
| `offloaded_photo` | 40051, 40231 | Photo offloaded to iCloud. The row has transfer_state 0 and ck_sync_state 1, and no file exists under Attachments/. |
| `offloaded_photo_scripted` | 40051 | The scripted offloaded photo from Mom on 2025-09-20. |
| `pdf_with_caption` | 40677 | PDF attachment and a caption in one message. |
| `photo_generic` | 40354, 40369, 40479, 40533, 40588, 40591, 40691, 40755 and 7 more | Photos with a tiny HEIC file on disk. |
| `photo_heic` | 40785 | A single HEIC photo with its file on disk. |
| `photo_with_caption` | 41428 | Photo and caption in one message. Part 0 is the photo and part 1 is the text. |
| `placed_sticker` | 41436 | Sticker placed on the thread root. associated_message_type is 1000. |
| `rcs_tapback` | 41001 | Tapback inside the RCS chat. |
| `read_receipt_on_my_message` | 40003, 40007, 40018, 40045, 40047, 40056, 40059, 40061 and 212 more | Outgoing rows with date_read set, in chats that send read receipts. |
| `recently_deleted` | 41502 | Row in Recently Deleted. It has chat_recoverable_message_join and recoverable_message_part rows but no chat_message_join row. |
| `reply_to_mom_target` | 41556 | The newest message from Mom. It is the target for the reply task. |
| `rowid_gap` | 40004, 40146, 40161, 40166, 40225, 40227, 40252, 40293 and 16 more | ROWIDs that no longer exist. Messages deleted them for good, and their guids are in deleted_messages. |
| `self_echo_assumed` | 40002, 40043, 40108, 40272, 40277, 40324, 40367, 40402 and 9 more | In the self-chat, an is_from_me 0 copy of a note with handle_id 1 and the same text. S2 found no such copy for sends made from the Mac itself on macOS 26.2 (research/spikes/S2.md). It stays as a defensive dedupe case. |
| `self_echo_original` | 40001, 40042, 40107, 40271, 40276, 40323, 40366, 40401 and 9 more | The is_from_me 1 row that has an echo copy. |
| `sender_not_in_contacts` | 40474 | Riley is not in contacts.json, so readers must fall back to the phone number. |
| `sent_not_delivered` | 41558 | Outgoing iMessage with is_sent 1, is_delivered 0 and date_delivered 0. |
| `sms_fallback_in_imessage_chat` | 40258, 40259, 40260 | SMS rows inside Mom's iMessage chat. They use Mom's SMS handle, ROWID 8, and service SMS. |
| `sms_outgoing_no_delivery_date` | 40020 | Outgoing SMS. SMS rows never get date_delivered. |
| `sticker` | 40528 | Sticker sent as its own message. The attachment has is_sticker 1. |
| `tapback_2000` | 40078, 40115, 40140, 40217, 40219, 40332, 40466, 40540 and 22 more | Love tapback added, associated_message_type 2000. |
| `tapback_2001` | 40089, 40095, 40331, 40394, 40424, 40521, 41031, 41057 and 8 more | Like tapback added, associated_message_type 2001. |
| `tapback_2002` | 40341, 41467 | Dislike tapback added, associated_message_type 2002. |
| `tapback_2003` | 40068, 40069, 40083, 40120, 40162, 40295, 40393, 40539 and 14 more | Laugh tapback added, associated_message_type 2003. |
| `tapback_2004` | 40126, 40390, 41242, 41426, 41431, 41479 | Emphasize tapback added, associated_message_type 2004. |
| `tapback_2005` | 40724, 41313, 41466 | Question tapback added, associated_message_type 2005. |
| `tapback_2006` | 41472, 41474, 41475 | Emoji tapback added, associated_message_type 2006. |
| `tapback_3000` | 41480 | Love tapback removed, associated_message_type 3000. |
| `tapback_3001` | 41424 | Like tapback removed, associated_message_type 3001. |
| `tapback_3002` | 41469 | Dislike tapback removed, associated_message_type 3002. |
| `tapback_3003` | 41481 | Laugh tapback removed, associated_message_type 3003. |
| `tapback_3004` | 41482 | Emphasize tapback removed, associated_message_type 3004. |
| `tapback_3005` | 41468 | Question tapback removed, associated_message_type 3005. |
| `tapback_3006` | 41473 | Emoji tapback removed, associated_message_type 3006. |
| `tapback_bp_prefix` | 41435 | Tapback on a URL balloon. associated_message_guid uses the bp: prefix. |
| `tapback_emoji` | 41472, 41473, 41474, 41475 | Emoji tapbacks, types 2006 and 3006, with associated_message_emoji set. |
| `tapback_on_attachment` | 40786 | Love tapback on a photo. The quote is "Loved an image". |
| `tapback_on_my_message` | 41548 | Dad liked one of your messages. |
| `tapback_part_0` | 41429 | Tapback on part 0 of a two-part message, the photo. It uses p:0/ and range 0,1. |
| `tapback_part_1` | 41430, 41431 | Tapback on part 1 of a two-part message, the caption. It uses p:1/ and range 1,n. |
| `tapback_remove` | 41424, 41468, 41469, 41473, 41480, 41481, 41482 | Remove rows, types 3000 to 3006. |
| `tapback_target_a` | 41418 | Target with adds and a remove from several people. See the net state table. |
| `tapback_target_b` | 41465 | Target where two reactions were removed and one added. See the net state table. |
| `tapback_target_c` | 41471 | Target with emoji tapbacks, including a removed emoji. See the net state table. |
| `tapback_target_d` | 41476 | Target where every reaction was later removed. Its net state is empty. |
| `tapback_target_multipart` | 41428 | Two-part target with reactions on different parts. See the net state table. |
| `text_column_populated` | 40012, 40020, 40021, 40022, 40023, 40053, 40058, 40067 and 94 more | Rows where message.text is set as well as attributedBody. Most rows leave text NULL. |
| `thread_reply` | 40889, 41419, 41423, 41425 | Reply in a thread. thread_originator_guid points at the root and thread_originator_part is part:location:length. |
| `thread_reply_any` | 40033, 40067, 40138, 40233, 40507, 40742, 40793, 40838 and 12 more | Every row with thread_originator_guid set, including generic replies. |
| `thread_reply_to_part_1` | 41432 | Thread reply to part 1 of a two-part message, so thread_originator_part is 1:1:n. |
| `thread_root` | 41417 | Root message of a thread with three replies. |
| `two_photos_one_message` | 40945 | Two photos in one message. The body is two U+FFFC characters. |
| `unread` | 41549, 41550, 41552, 41553, 41554, 41555, 41556, 41557 | Incoming rows with is_read 0. They answer the unread summary task. |
| `unsent_legacy` | 40908 | Unsend in the older shape. date_retracted holds the time and the body is cleared. |
| `unsent_modern_incoming` | 41483 | Incoming unsend in the macOS 15 and 26 shape. text and attributedBody are NULL, date_retracted is 0, date_edited holds the unsend time and message_summary_info lists the part under rp. |
| `unsent_modern_outgoing` | 40978 | Your own unsend in the macOS 15 and 26 shape. text and attributedBody are NULL, date_retracted is 0, date_edited holds the unsend time and message_summary_info lists the part under rp. |
| `unsent_partial` | 41232 | One part of a two-part message was unsent. The photo stays, the caption is gone and rp is [1]. |
| `voice_with_transcript` | 40580 | Voice message in CAF with is_audio_message 1. The transcript is in attachment.user_info under audio-transcription and in the IMAudioTranscription attribute. |

## Tapback net state

Replaying every add and remove in ROWID order leaves these reactions.

| Key | Target ROWID | Part | Reactions |
| --- | --- | --- | --- |
| `tapback_target_a` | 41418 | 0 | ❤️ Mom, 😂 Priya, ‼️ You |
| `tapback_target_b` | 41465 | 0 | 👍 Mom |
| `tapback_target_c` | 41471 | 0 | 🪔 Priya, 🎉 You |
| `tapback_target_d` | 41476 | 0 | none |
| `tapback_target_multipart` | 41428 | 0 | ❤️ Mom |
| `tapback_target_multipart` | 41428 | 1 | 😂 Arjun, ‼️ Dad |

## Benchmark task answers

1. Summarize unread messages. The unread rows are chat 7: 41555, 41556; chat 12: 41552, 41553, 41554; chat 19: 41557; chat 31: 41550; chat 56: 41549.
2. Reply to Mom. Mom's chat is ROWID 7 and her newest message is ROWID 41556.
3. Find the address Dad sent last month. ROWID 41381 has 2219 Juniper Hollow Rd, Santa Rosa, CA 95404. ROWID 40850 is an older address from June.
4. React to the last message. The newest row is ROWID 41558, which you sent. The newest incoming message is ROWID 41557 in chat 19.
5. Send a photo to a group. Family 🏡 is chat 12. `Attachments/76/09/CBF6F44C-5BD1-4B89-9C7E-1D3801BC9BAD/IMG_4420.HEIC` is a photo you can send.

## Attachments

| ROWID | Message | Kind | Name | Claimed size | File |
| --- | --- | --- | --- | --- | --- |
| 9001 | 40051 | photo | IMG_2291.HEIC | 2431882 | offloaded, no file |
| 9002 | 40231 | photo | IMG_7661.HEIC | 3291612 | offloaded, no file |
| 9003 | 40354 | photo | IMG_2439.HEIC | 2451103 | `Attachments/49/08/4C65644D-297F-4373-9EB1-3DE53FF3C98D/IMG_2439.HEIC` |
| 9004 | 40369 | photo | IMG_2126.HEIC | 2468588 | `Attachments/95/14/6065608C-2BE0-42DF-B262-C25A2078403E/IMG_2126.HEIC` |
| 9005 | 40479 | photo | IMG_2215.HEIC | 1108370 | `Attachments/f0/09/EAF5AF65-3516-45EF-AD44-465A0307CCF7/IMG_2215.HEIC` |
| 9006 | 40528 | sticker | sticker.heic | 61442 | `Attachments/ea/00/9A50A312-3A99-4DEA-A9F9-C3A07C10828C/sticker.heic` |
| 9007 | 40533 | photo | IMG_7824.HEIC | 1180291 | `Attachments/3a/15/CCB92034-AE49-4EE5-81BB-3036F80929AC/IMG_7824.HEIC` |
| 9008 | 40580 | voice | Audio Message.caf | 11734 | `Attachments/2a/03/969E87CD-4086-4AF4-AAF1-8D8598F10AE1/Audio Message.caf` |
| 9009 | 40588 | photo | IMG_3819.HEIC | 3182315 | `Attachments/9c/03/9BBDB17A-8FF3-460F-8543-5068CDB898EF/IMG_3819.HEIC` |
| 9010 | 40591 | photo | IMG_4250.HEIC | 1268610 | `Attachments/fd/05/E0E335D1-D214-45F5-A241-1AC4295D26A9/IMG_4250.HEIC` |
| 9011 | 40677 | pdf | Insurance_Renewal_2026.pdf | 348211 | `Attachments/f8/01/4CFD9F41-6467-441F-91C0-52B068179B02/Insurance_Renewal_2026.pdf` |
| 9012 | 40691 | photo | IMG_6321.HEIC | 1170022 | `Attachments/c2/15/BA435180-7CDE-4600-A640-75439A3C2846/IMG_6321.HEIC` |
| 9013 | 40755 | photo | IMG_7040.HEIC | 3291814 | `Attachments/fe/01/9D1F2EEA-D5E4-43DC-83FE-BE83825FF717/IMG_7040.HEIC` |
| 9014 | 40785 | photo | IMG_4420.HEIC | 2204318 | `Attachments/76/09/CBF6F44C-5BD1-4B89-9C7E-1D3801BC9BAD/IMG_4420.HEIC` |
| 9015 | 40937 | photo | IMG_2259.HEIC | 1957029 | `Attachments/94/04/0F0F690E-E05A-4F44-9C73-10B023731F94/IMG_2259.HEIC` |
| 9016 | 40945 | photo | IMG_5101.HEIC | 1987004 | `Attachments/57/07/60AC738E-DB9F-47DC-90D1-9E57C6E824E3/IMG_5101.HEIC` |
| 9017 | 40945 | photo | IMG_5102.HEIC | 2310771 | `Attachments/05/06/5B9F34AA-0DBE-4D00-8381-F39A22C01604/IMG_5102.HEIC` |
| 9018 | 40965 | photo | IMG_7188.HEIC | 2018773 | `Attachments/6e/12/15E79008-B7AA-4A15-AEF2-BD96266CC904/IMG_7188.HEIC` |
| 9019 | 41124 | photo | IMG_2142.HEIC | 1738251 | `Attachments/9f/09/AE3DA206-9E21-4752-8A5D-2F6D97776E8D/IMG_2142.HEIC` |
| 9020 | 41232 | photo | IMG_6230.HEIC | 1640093 | `Attachments/06/07/7C59F4E5-36D1-48A3-A73A-96B31EB466BD/IMG_6230.HEIC` |
| 9021 | 41244 | photo | IMG_7295.HEIC | 3194774 | `Attachments/ad/05/25FD6C46-013E-49A5-92FC-10EB6A6A3312/IMG_7295.HEIC` |
| 9022 | 41310 | photo | IMG_4480.HEIC | 1481847 | `Attachments/9e/00/EE7A9C77-EC88-4181-AAF1-C36F71B7BB34/IMG_4480.HEIC` |
| 9023 | 41428 | photo | IMG_7781.HEIC | 2288960 | `Attachments/9d/10/D4A94D7C-4092-47BC-8B2B-FC1B5E7D3C97/IMG_7781.HEIC` |
| 9024 | 41436 | sticker | sticker-placed.heic | 58120 | `Attachments/a4/06/F497E56E-8363-455F-80A1-A96CA9456753/sticker-placed.heic` |
| 9025 | 41499 | photo | IMG_2588.HEIC | 1449789 | `Attachments/f9/07/EDDA7013-D723-4701-B791-ACCF9B36AC4A/IMG_2588.HEIC` |
| 9026 | 41540 | photo | IMG_9201.HEIC | 1117427 | `Attachments/4f/08/5B8CF60D-1313-4583-81ED-F412F0B5060F/IMG_9201.HEIC` |

`total_bytes` holds a realistic original size. The files on disk are tiny but valid HEIC, PDF and CAF files, so conversion code can open them.
