import FixtureKit
import Foundation

/// Writes manifest.json, contacts.json and README.md from the plan and the finished database.
struct Report {
  let plan: Planner
  let writer: Writer
  let db: Database
  let seed: UInt64
  let schemaSHA: String

  // MARK: edge-case descriptions

  static let descriptions: [String: String] = [
    "address_decoy_june": "An older address from Dad in June 2026. It is a decoy for the address task.",
    "address_last_month": "The address Dad sent on 2026-10-14, which is last month relative to the fixture clock.",
    "bold_text": "Body with a __kIMTextBoldAttributeName range on the word Reminder.",
    "delivered_no_read_receipt": "Outgoing iMessage rows that were delivered in a chat without read receipts, so date_read is 0.",
    "duplicate_same_minute": "Two rows from the same sender with identical text inside one minute.",
    "duplicate_text_after_failure": "A failed send and its retry. Both rows have the same text.",
    "edited_once": "Edited one time. date_edited is set and message_summary_info holds both versions under ec.",
    "edited_twice": "Edited two times. message_summary_info holds three versions under ec, oldest first.",
    "emoji_zwj_flag": "Body made of a ZWJ family emoji, a heart and a flag.",
    "expressive_effect": "Message sent with the confetti effect in expressive_send_style_id.",
    "failed_send": "Outgoing row with error 4, is_sent 0 and is_delivered 0. The update fired update_last_failed_message_date, so kvtable holds lastFailedMessageDate.",
    "group_add": "item_type 1 with group_action_type 0. Jordan added Riley, so other_handle is Riley's handle.",
    "group_leave": "item_type 3 with group_action_type 0. Riley left the group.",
    "group_remove": "item_type 1 with group_action_type 1. You removed Chris, so handle_id is 0 and other_handle is Chris's handle.",
    "group_rename": "item_type 2 rows. group_title holds the new name.",
    "last_message_overall": "The newest row in the database.",
    "link_preview_single_row": "URL balloon in one row. The URL is the body and payload_data holds an LPLinkMetadata archive.",
    "link_preview_two_rows": "A text row that contains a URL, then a balloon row for the same URL one second later. Readers should show one message.",
    "link_without_preview": "A bare URL with no balloon. The body carries __kIMLinkAttributeName.",
    "long_body": "Body longer than 400 characters.",
    "long_body_over_8kb": "Self-note longer than 8 KB, more than one show call returns.",
    "mention": "Body with a __kIMMentionConfirmedMention range on the name Priya.",
    "multiline_body": "Body that contains line breaks.",
    "multipart": "Message with more than one part. Each part has its own __kIMMessagePartAttributeName index.",
    "nfc_text": "NFC text with a precomposed é.",
    "nfd_text": "NFD text, an e followed by a combining acute accent. A search for café should still find it.",
    "non_latin_accents": "Spanish text with accents and inverted punctuation.",
    "non_latin_devanagari": "Hindi text in Devanagari.",
    "non_latin_hangul": "Korean text in Hangul.",
    "non_latin_vietnamese": "Vietnamese text with stacked diacritics.",
    "nsattributedstring_class": "Bodies archived as NSAttributedString instead of NSMutableAttributedString. Real databases contain both.",
    "offloaded_photo": "Photo offloaded to iCloud. The row has transfer_state 0 and ck_sync_state 1, and no file exists under Attachments/.",
    "offloaded_photo_scripted": "The scripted offloaded photo from Mom on 2025-09-20.",
    "pdf_with_caption": "PDF attachment and a caption in one message.",
    "photo_generic": "Photos with a tiny HEIC file on disk.",
    "photo_heic": "A single HEIC photo with its file on disk.",
    "photo_with_caption": "Photo and caption in one message. Part 0 is the photo and part 1 is the text.",
    "placed_sticker": "Sticker placed on the thread root. associated_message_type is 1000.",
    "rcs_tapback": "Tapback inside the RCS chat.",
    "read_receipt_on_my_message": "Outgoing rows with date_read set, in chats that send read receipts.",
    "recently_deleted": "Row in Recently Deleted. It has chat_recoverable_message_join and recoverable_message_part rows but no chat_message_join row.",
    "reply_to_mom_target": "The newest message from Mom. It is the target for the reply task.",
    "rowid_gap": "ROWIDs that no longer exist. Messages deleted them for good, and their guids are in deleted_messages.",
    "self_echo_assumed": "In the self-chat, an is_from_me 0 copy of a note with handle_id 1 and the same text. S2 found no such copy for sends made from the Mac itself on macOS 26.2 (research/spikes/S2.md). It stays as a defensive dedupe case.",
    "self_echo_original": "The is_from_me 1 row that has an echo copy.",
    "sender_not_in_contacts": "Riley is not in contacts.json, so readers must fall back to the phone number.",
    "sent_not_delivered": "Outgoing iMessage with is_sent 1, is_delivered 0 and date_delivered 0.",
    "sms_fallback_in_imessage_chat": "SMS rows inside Mom's iMessage chat. They use Mom's SMS handle, ROWID 8, and service SMS.",
    "sms_outgoing_no_delivery_date": "Outgoing SMS. SMS rows never get date_delivered.",
    "sticker": "Sticker sent as its own message. The attachment has is_sticker 1.",
    "tapback_bp_prefix": "Tapback on a URL balloon. associated_message_guid uses the bp: prefix.",
    "tapback_emoji": "Emoji tapbacks, types 2006 and 3006, with associated_message_emoji set.",
    "tapback_on_attachment": "Love tapback on a photo. The quote is \"Loved an image\".",
    "tapback_on_my_message": "Dad liked one of your messages.",
    "tapback_part_0": "Tapback on part 0 of a two-part message, the photo. It uses p:0/ and range 0,1.",
    "tapback_part_1": "Tapback on part 1 of a two-part message, the caption. It uses p:1/ and range 1,n.",
    "tapback_remove": "Remove rows, types 3000 to 3006.",
    "tapback_target_a": "Target with adds and a remove from several people. See the net state table.",
    "tapback_target_b": "Target where two reactions were removed and one added. See the net state table.",
    "tapback_target_c": "Target with emoji tapbacks, including a removed emoji. See the net state table.",
    "tapback_target_d": "Target where every reaction was later removed. Its net state is empty.",
    "tapback_target_multipart": "Two-part target with reactions on different parts. See the net state table.",
    "text_column_populated": "Rows where message.text is set as well as attributedBody. Most rows leave text NULL.",
    "thread_reply": "Reply in a thread. thread_originator_guid points at the root and thread_originator_part is part:location:length.",
    "thread_reply_any": "Every row with thread_originator_guid set, including generic replies.",
    "thread_reply_to_part_1": "Thread reply to part 1 of a two-part message, so thread_originator_part is 1:1:n.",
    "thread_root": "Root message of a thread with three replies.",
    "two_photos_one_message": "Two photos in one message. The body is two U+FFFC characters.",
    "unread": "Incoming rows with is_read 0. They answer the unread summary task.",
    "unsent_legacy": "Unsend in the older shape. date_retracted holds the time and the body is cleared.",
    "unsent_modern_incoming": "Incoming unsend in the macOS 15 and 26 shape. text and attributedBody are NULL, date_retracted is 0, date_edited holds the unsend time and message_summary_info lists the part under rp.",
    "unsent_modern_outgoing": "Your own unsend in the macOS 15 and 26 shape. text and attributedBody are NULL, date_retracted is 0, date_edited holds the unsend time and message_summary_info lists the part under rp.",
    "unsent_partial": "One part of a two-part message was unsent. The photo stays, the caption is gone and rp is [1].",
    "voice_with_transcript": "Voice message in CAF with is_audio_message 1. The transcript is in attachment.user_info under audio-transcription and in the IMAudioTranscription attribute.",
  ]

  static let tapbackNames: [Int: String] = [
    2000: "love", 2001: "like", 2002: "dislike", 2003: "laugh", 2004: "emphasize", 2005: "question", 2006: "emoji",
  ]
  static let tapbackGlyphs: [Int: String] = [2000: "❤️", 2001: "👍", 2002: "👎", 2003: "😂", 2004: "‼️", 2005: "❓"]

  // MARK: data

  func label(_ who: Who) -> String {
    switch who {
    case .me: return "You"
    case .person(let k): return Cast.person(k).label
    }
  }

  /// Every edge key mapped to its ROWIDs, scripted keys plus keys derived from the rows.
  func edgeMap() throws -> [(key: String, rowids: [Int64])] {
    var map: [String: [Int64]] = [:]
    for i in writer.order {
      let m = plan.msgs[i]
      for k in m.edgeKeys { map[k, default: []].append(m.rowid) }
    }
    func q(_ key: String, _ sql: String) throws {
      let ids = try db.rows(sql).compactMap { $0[0].int }
      if !ids.isEmpty { map[key] = ids }
    }
    map["rowid_gap"] = writer.summary.deletedGapRowids
    try q("read_receipt_on_my_message",
          "SELECT ROWID FROM message WHERE is_from_me = 1 AND date_read > 0 ORDER BY ROWID")
    try q("delivered_no_read_receipt",
          """
          SELECT m.ROWID FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
          WHERE m.is_from_me = 1 AND m.is_delivered = 1 AND m.date_read = 0 AND m.service = 'iMessage'
            AND m.associated_message_type = 0 AND c.ROWID = 9 ORDER BY m.ROWID
          """)
    try q("text_column_populated", "SELECT ROWID FROM message WHERE text IS NOT NULL ORDER BY ROWID")
    try q("thread_reply_any", "SELECT ROWID FROM message WHERE thread_originator_guid IS NOT NULL ORDER BY ROWID")
    let immutable = writer.order.map { plan.msgs[$0] }
      .filter { $0.immutableArchive && !$0.gapFiller && $0.bodyString != nil }.map(\.rowid)
    map["nsattributedstring_class"] = immutable
    for t in [2000, 2001, 2002, 2003, 2004, 2005, 2006, 3000, 3001, 3002, 3003, 3004, 3005, 3006] {
      try q("tapback_\(t)", "SELECT ROWID FROM message WHERE associated_message_type = \(t) ORDER BY ROWID")
    }
    return map.keys.sorted().map { ($0, map[$0]!) }
  }

  func description(_ key: String) -> String {
    if key.hasPrefix("tapback_"), let t = Int(key.dropFirst(8)) {
      let name = Report.tapbackNames[t >= 3000 ? t - 1000 : t]!.capitalized
      return "\(name) tapback \(t >= 3000 ? "removed" : "added"), associated_message_type \(t)."
    }
    guard let d = Report.descriptions[key] else { fatalError("no description for edge key \(key)") }
    return d
  }

  /// Net reactions per part after replaying adds and removes in ROWID order.
  func netState(_ target: Int) -> [(part: Int, reactions: [String])] {
    var state: [[(who: String, type: Int, emoji: String?)]] = Array(repeating: [], count: plan.msgs[target].parts.count)
    for i in writer.order {
      let m = plan.msgs[i]
      guard case .tapback(let type, let t, let part, let emoji) = m.kind, t == target else { continue }
      let who = label(m.who)
      if type < 3000 {
        state[part].removeAll { $0.who == who }
        state[part].append((who, type, emoji))
      } else {
        state[part].removeAll { $0.who == who && $0.type == type - 1000 && $0.emoji == emoji }
      }
    }
    return state.enumerated().map { p, list in
      (p, list.map { "\($0.type == 2006 ? ($0.emoji ?? "") : Report.tapbackGlyphs[$0.type]!) \($0.who)" })
    }
  }

  /// Decoded body for every live row, the value verify-fixture must reproduce.
  func expectedBodies() -> [(rowid: Int64, body: String)] {
    writer.order.map { plan.msgs[$0] }.filter { !$0.gapFiller && $0.bodyString != nil }.map { ($0.rowid, $0.bodyString!) }
  }

  static func bodiesDigest(_ bodies: [(rowid: Int64, body: String)]) -> String {
    var d = Data()
    for (r, b) in bodies {
      d.append(contentsOf: Array("\(r)\t".utf8))
      d.append(contentsOf: Array(b.utf8))
      d.append(0x0A)
    }
    return sha256Hex(d)
  }

  func count(_ sql: String) throws -> Int64 { try db.scalarInt(sql) }

  /// (manifest key, README label, value)
  func counts() throws -> [(String, String, Int64)] {
    [
      ("message_rows", "Rows in message", try count("SELECT COUNT(*) FROM message")),
      ("chat_message_join_rows", "Rows in chat_message_join", try count("SELECT COUNT(*) FROM chat_message_join")),
      ("attributed_body_only", "Rows with text NULL and a body only in attributedBody",
       try count("SELECT COUNT(*) FROM message WHERE text IS NULL AND attributedBody IS NOT NULL")),
      ("text_and_attributed_body", "Rows with both text and attributedBody",
       try count("SELECT COUNT(*) FROM message WHERE text IS NOT NULL AND attributedBody IS NOT NULL")),
      ("no_body", "Rows with no body, which are group events and unsends",
       try count("SELECT COUNT(*) FROM message WHERE text IS NULL AND attributedBody IS NULL")),
      ("tapback_rows", "Tapback rows, types 2000 to 3006",
       try count("SELECT COUNT(*) FROM message WHERE associated_message_type BETWEEN 2000 AND 3006")),
      ("group_event_rows", "Group event rows", try count("SELECT COUNT(*) FROM message WHERE item_type != 0")),
      ("unread_incoming", "Unread incoming rows",
       try count("SELECT COUNT(*) FROM message WHERE is_read = 0 AND is_from_me = 0 AND item_type = 0")),
      ("chats", "Chats", try count("SELECT COUNT(*) FROM chat")),
      ("handles", "Handles", try count("SELECT COUNT(*) FROM handle")),
      ("attachments", "Attachments", try count("SELECT COUNT(*) FROM attachment")),
      ("attachments_on_disk", "Attachments with a file on disk", Int64(plan.atts.filter(\.onDisk).count)),
      ("attachments_offloaded", "Attachments offloaded to iCloud", Int64(plan.atts.filter { !$0.onDisk }.count)),
      ("deleted_messages_rows", "Permanently deleted messages, the ROWID gaps", try count("SELECT COUNT(*) FROM deleted_messages")),
      ("recently_deleted_rows", "Messages in Recently Deleted", try count("SELECT COUNT(*) FROM chat_recoverable_message_join")),
    ]
  }

  // MARK: files

  func write(to out: URL, dbSHA: String) throws {
    let edges = try edgeMap()
    let bodies = expectedBodies()
    let countList = try counts()
    let range = try db.rows("SELECT MIN(date), MAX(date) FROM message")[0]
    let first = range[0].int!, last = range[1].int!

    // Chats.
    var chatRows: [[String: Any]] = []
    for c in plan.chats {
      let n = try db.scalarInt("SELECT COUNT(*) FROM chat_message_join WHERE chat_id = ?", [.int(c.rowid)])
      chatRows.append([
        "rowid": c.rowid, "guid": c.guid, "label": c.label, "style": c.style, "service": c.service.rawValue,
        "display_name": c.displayName, "chat_identifier": c.identifier, "message_count": n,
        "members": c.currentMembers.map { Cast.handle($0).rowid }, "read_receipts": c.readReceipts,
      ])
    }

    var attRows: [[String: Any]] = []
    for a in plan.atts.sorted(by: { $0.rowid < $1.rowid }) {
      var r: [String: Any] = [
        "rowid": a.rowid, "guid": a.guid, "message_rowid": plan.msgs[a.messageIndex].rowid, "kind": a.kind.rawValue,
        "transfer_name": a.transferName, "filename": a.dbPath, "fixture_path": a.fixtureRelativePath,
        "on_disk": a.onDisk, "total_bytes": a.totalBytes, "mime_type": a.mime,
      ]
      if let d = a.fileData { r["file_sha256"] = sha256Hex(d); r["file_bytes"] = d.count }
      if let t = a.transcript { r["transcript"] = t }
      attRows.append(r)
    }

    var nets: [String: Any] = [:]
    for (key, target) in plan.netTargets {
      var parts: [String: Any] = [:]
      for (p, list) in netState(target) { parts["\(p)"] = list }
      nets[key] = ["rowid": plan.msgs[target].rowid, "parts": parts]
    }

    let unread = try db.rows(
      """
      SELECT j.chat_id, m.ROWID FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
      WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0 ORDER BY j.chat_id, m.ROWID
      """)
    var unreadByChat: [String: [Int64]] = [:]
    for r in unread { unreadByChat["\(r[0].int!)", default: []].append(r[1].int!) }
    let lastIncoming = try db.rows(
      """
      SELECT m.ROWID, j.chat_id FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
      WHERE m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0 ORDER BY m.date DESC LIMIT 1
      """)[0]
    let edgeDict = Dictionary(uniqueKeysWithValues: edges.map { ($0.key, $0.rowids) })
    let samplePhoto = plan.atts.first { $0.kind == .photo && $0.onDisk }!
    let tasks: [String: Any] = [
      "summarize_unread": ["unread_rowids_by_chat": unreadByChat],
      "reply_to_mom": ["chat_rowid": 7, "chat_guid": plan.chat("mom").guid, "handle": "+14155550101",
                       "latest_from_mom_rowid": edgeDict["reply_to_mom_target"]![0]],
      "find_dad_address_last_month": ["rowid": edgeDict["address_last_month"]![0],
                                      "answer": "2219 Juniper Hollow Rd, Santa Rosa, CA 95404",
                                      "decoy_rowid": edgeDict["address_decoy_june"]![0]],
      "react_to_last_message": ["last_message_rowid": edgeDict["last_message_overall"]![0],
                                "last_incoming_rowid": lastIncoming[0].int!, "last_incoming_chat_rowid": lastIncoming[1].int!],
      "send_photo_to_group": ["chat_rowid": 12, "chat_guid": plan.chat("family").guid, "display_name": "Family 🏡",
                              "sample_photo": samplePhoto.fixtureRelativePath],
    ]

    let samples: [[String: Any]] = writer.order.map { plan.msgs[$0] }
      .filter { !$0.edgeKeys.isEmpty && !$0.gapFiller && $0.bodyString != nil }
      .map { ["rowid": $0.rowid, "body": $0.bodyString!] }

    var handles: [[String: Any]] = []
    for (key, h) in Cast.handles {
      let p = Cast.person(h.person)
      handles.append(["rowid": h.rowid, "id": h.id, "service": h.service.rawValue, "key": key,
                      "person": p.label, "in_contacts": p.inContacts])
    }

    let manifest: [String: Any] = [
      "generator": "Tests/Fixtures/make-fixture",
      "seed": seed,
      "schema_source": "research/chatdb-schema.sql",
      "schema_sha256": schemaSHA,
      "db_sha256": dbSHA,
      "time_zone": fixtureTimeZone.identifier,
      "fixture_now_local": localStamp(fixtureNow),
      "fixture_now_ns": fixtureNow,
      "first_message_local": localStamp(first),
      "last_message_local": localStamp(last),
      "owner": ["phone": Cast.myPhone, "email": Cast.myEmail, "handle_rowid": 1],
      "counts": Dictionary(uniqueKeysWithValues: countList.map { ($0.0, $0.2) }),
      "chats": chatRows,
      "handles": handles,
      "attachments": attRows,
      "edge_cases": edgeDict,
      "tapback_net_state": nets,
      "tasks": tasks,
      "bodies": ["count": bodies.count, "sha256": Report.bodiesDigest(bodies),
                 "format": "sha256 over UTF-8 lines of ROWID, a tab, the decoded attributedBody string, and a newline, in ROWID order"],
      "samples": samples,
      "schema": [
        "statements": writer.summary.schemaStatements,
        "skipped_statements": writer.summary.skippedStatements,
        "tables": writer.summary.tableNames,
        "indexes": writer.summary.indexNames.count,
        "triggers": writer.summary.triggerNames,
        "triggers_dropped": [String](),
        "stubbed_functions": Database.stubbedFunctionNames,
      ],
    ]
    try json(manifest).write(to: out.appendingPathComponent("manifest.json"))
    try json(contacts()).write(to: out.appendingPathComponent("contacts.json"))
    let readme = renderReadme(edges: edges, counts: countList, chats: chatRows, first: first, last: last, nets: nets,
                              tasks: tasks, bodies: bodies.count, dbSHA: dbSHA)
    try Data(readme.utf8).write(to: out.appendingPathComponent("README.md"))
  }

  private func json(_ obj: Any) throws -> Data {
    var d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    d.append(0x0A)
    return d
  }

  /// The synthetic address book. Marco and Riley are left out on purpose.
  func contacts() -> [String: Any] {
    var people: [[String: Any]] = []
    for p in Cast.people where p.key != "me" && p.inContacts {
      var handles: [String] = []
      for (_, h) in Cast.handles where h.person == p.key && !handles.contains(h.id) { handles.append(h.id) }
      var row: [String: Any] = ["first": p.first, "handles": handles]
      if let l = p.last { row["last"] = l }
      if let n = p.nickname { row["nickname"] = n }
      people.append(row)
    }
    return [
      "note": "Synthetic contacts for the fixture. Every name, number and email is invented.",
      "owner": ["first": "Alex", "handles": [Cast.myPhone, Cast.myEmail]],
      "people": people,
    ]
  }

  // MARK: README

  private func renderReadme(edges: [(key: String, rowids: [Int64])], counts: [(String, String, Int64)], chats: [[String: Any]],
                            first: Int64, last: Int64, nets: [String: Any], tasks: [String: Any], bodies: Int,
                            dbSHA: String) -> String {
    var s = ""
    func line(_ t: String = "") { s += t + "\n" }
    func ids(_ r: [Int64], limit: Int = 8) -> String {
      let shown = r.prefix(limit).map(String.init).joined(separator: ", ")
      return r.count > limit ? "\(shown) and \(r.count - limit) more" : shown
    }
    let c = Dictionary(uniqueKeysWithValues: counts.map { ($0.0, $0.2) })

    line("# Synthetic chat.db fixture")
    line()
    line("This folder holds a Messages database built from the real macOS 26.2 schema in `research/chatdb-schema.sql`. Every person, number, address and message in it is invented. No real Messages or AddressBook data was read to make it.")
    line()
    line("Run `./build.sh` to rebuild it. The build regenerates every file listed below from seed \(seed), checks the result with `/usr/bin/sqlite3`, decodes every body with NSUnarchiver, and builds a second copy to confirm the bytes match. Do not edit the generated files by hand. Change `make-fixture/Sources` and rebuild.")
    line()
    line("## Files")
    line()
    line("- `chat.db` is the database, \(c["message_rows"]!) message rows. Its SHA-256 is `\(dbSHA)`.")
    line("- `Attachments/` holds tiny stand-in files at the paths the attachment rows name, with `~/Library/Messages/Attachments/` replaced by `Attachments/`.")
    line("- `contacts.json` is the synthetic address book. Readers should use it instead of AddressBook.")
    line("- `manifest.json` has the full edge-case map, every attachment, the expected body digest, decoded samples and the answers for the benchmark tasks.")
    line("- `make-fixture/` is the Swift package that writes all of the above. `verify-fixture` in the same package checks it.")
    line("- `build.sh` builds, generates, verifies and checks determinism.")
    line()
    line("## Time")
    line()
    line("Dates in `message` are Apple-epoch nanoseconds, counted from 2001-01-01 UTC. `attachment.created_date` is in seconds. Local times below are \(fixtureTimeZone.identifier). Messages run from \(localStamp(first)) to \(localStamp(last)). The fixture clock reads \(localStamp(fixtureNow)), so \"last month\" means October 2026 and no read time passes that moment.")
    line()
    line("## Chats")
    line()
    line("| ROWID | GUID | Kind | Service | Messages | Member handle ROWIDs |")
    line("| --- | --- | --- | --- | --- | --- |")
    for ch in chats {
      let members = (ch["members"] as! [Int64]).map(String.init).joined(separator: ", ")
      line("| \(ch["rowid"]!) | `\(ch["guid"]!)` | \(ch["label"]!) | \(ch["service"]!) | \(ch["message_count"]!) | \(members) |")
    }
    line()
    line("Chat 2 is the self-chat. Chat 7 also holds three SMS rows on Mom's SMS handle, ROWID 8. Chat 12 is named Family 🏡 and was renamed twice. Chat 19 has no name. Chris was removed from it and Riley joined and later left, so neither is in chat_handle_join. Chat 23 uses Jordan's email address and you reply from \(Cast.myEmail). Chat 31 is RCS. Chat 56 is SMS with a sender who is not in contacts.")
    line()
    line("## Handles")
    line()
    line("| ROWID | ID | Service | Person | In contacts |")
    line("| --- | --- | --- | --- | --- |")
    for (_, h) in Cast.handles {
      let p = Cast.person(h.person)
      line("| \(h.rowid) | \(h.id) | \(h.service.rawValue) | \(h.person == "me" ? "You" : p.label) | \(p.inContacts ? "yes" : "no") |")
    }
    line()
    line("You are \(Cast.myPhone) and \(Cast.myEmail). In group chats your rows have handle_id 0. In 1:1 chats they carry the other person's handle, the way Messages stores them.")
    line()
    line("## Counts")
    line()
    for (_, label, v) in counts { line("- \(label): \(v)") }
    line()
    line("## Bodies")
    line()
    line("Most rows leave `text` NULL and keep the body only in `attributedBody`. That column is an NSMutableAttributedString, or sometimes an NSAttributedString, archived with NSArchiver. That is the typedstream format, which starts with `streamtyped`. Every character carries `__kIMMessagePartAttributeName`. Attachment parts are one U+FFFC character with `__kIMFileTransferGUIDAttributeName` set to the attachment GUID. URLs carry `__kIMLinkAttributeName`. `verify-fixture` decodes all \(bodies) bodies and compares them with the digest in manifest.json.")
    line()
    line("Edits and unsends live in `message_summary_info`, a binary plist. `otr` holds the original part ranges, `ec` holds each edited version as its own typedstream, and `rp` lists the unsent parts. URL balloons keep an NSKeyedArchiver archive of LPLinkMetadata in `payload_data`.")
    line()
    line("## Schema notes")
    line()
    line("The generator runs every CREATE TABLE, CREATE INDEX and CREATE TRIGGER statement from the schema file as written. It skips two statements, `CREATE TABLE sqlite_sequence(name,seq)` and `CREATE TABLE sqlite_stat1(tbl,idx,stat)`, because SQLite reserves those names. SQLite creates sqlite_sequence on its own, and the final ANALYZE creates sqlite_stat1.")
    line()
    line("No triggers were dropped. All \(writer.summary.triggerNames.count) triggers are in the database. Some of them call SQL functions that exist only inside Messages: \(Database.stubbedFunctionNames.map { "`\($0)`" }.joined(separator: ", ")). make-fixture registers stubs for them with `sqlite3_create_function_v2` while it writes. `is_mic_enabled` returns 0 and the rest return NULL. Reading the file works in any SQLite client. A write that fires one of those triggers, such as inserting a chat, needs the same stubs.")
    line()
    line("The generator relies on real triggers in four places. `after_insert_on_chat_message_join` fills `cache_roomnames`, `chat_service_on_insert_chat_message_join` fills `chat_service`, and `after_insert_on_message_attachment_join` sets `cache_has_attachments`. Deleting from `chat_message_join` makes the delete triggers remove rows and log their guids in `deleted_messages`, and setting `error` on the failed send fills `kvtable`.")
    line()
    line("## Edge cases")
    line()
    line("manifest.json has the complete ROWID lists under `edge_cases`. Long lists are cut here.")
    line()
    line("| Key | ROWIDs | What it is |")
    line("| --- | --- | --- |")
    for (k, r) in edges { line("| `\(k)` | \(ids(r)) | \(description(k)) |") }
    line()
    line("## Tapback net state")
    line()
    line("Replaying every add and remove in ROWID order leaves these reactions.")
    line()
    line("| Key | Target ROWID | Part | Reactions |")
    line("| --- | --- | --- | --- |")
    for key in nets.keys.sorted() {
      let n = nets[key] as! [String: Any]
      let parts = n["parts"] as! [String: Any]
      for p in parts.keys.sorted() {
        let list = parts[p] as! [String]
        line("| `\(key)` | \(n["rowid"]!) | \(p) | \(list.isEmpty ? "none" : list.joined(separator: ", ")) |")
      }
    }
    line()
    line("## Benchmark task answers")
    line()
    let t = tasks
    let unread = (t["summarize_unread"] as! [String: Any])["unread_rowids_by_chat"] as! [String: [Int64]]
    let unreadText = unread.keys.sorted { Int($0)! < Int($1)! }.map { "chat \($0): \(ids(unread[$0]!))" }.joined(separator: "; ")
    let mom = t["reply_to_mom"] as! [String: Any]
    let addr = t["find_dad_address_last_month"] as! [String: Any]
    let react = t["react_to_last_message"] as! [String: Any]
    let photo = t["send_photo_to_group"] as! [String: Any]
    line("1. Summarize unread messages. The unread rows are \(unreadText).")
    line("2. Reply to Mom. Mom's chat is ROWID 7 and her newest message is ROWID \(mom["latest_from_mom_rowid"]!).")
    line("3. Find the address Dad sent last month. ROWID \(addr["rowid"]!) has \(addr["answer"]!). ROWID \(addr["decoy_rowid"]!) is an older address from June.")
    line("4. React to the last message. The newest row is ROWID \(react["last_message_rowid"]!), which you sent. The newest incoming message is ROWID \(react["last_incoming_rowid"]!) in chat \(react["last_incoming_chat_rowid"]!).")
    line("5. Send a photo to a group. Family 🏡 is chat 12. `\(photo["sample_photo"]!)` is a photo you can send.")
    line()
    line("## Attachments")
    line()
    line("| ROWID | Message | Kind | Name | Claimed size | File |")
    line("| --- | --- | --- | --- | --- | --- |")
    for a in plan.atts.sorted(by: { $0.rowid < $1.rowid }) {
      let file = a.onDisk ? "`\(a.fixtureRelativePath)`" : "offloaded, no file"
      line("| \(a.rowid) | \(plan.msgs[a.messageIndex].rowid) | \(a.kind.rawValue) | \(a.transferName) | \(a.totalBytes) | \(file) |")
    }
    line()
    line("`total_bytes` holds a realistic original size. The files on disk are tiny but valid HEIC, PDF and CAF files, so conversion code can open them.")
    return s
  }
}
