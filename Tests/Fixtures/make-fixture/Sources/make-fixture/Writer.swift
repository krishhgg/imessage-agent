import FixtureKit
import Foundation

/// The moment the fixture pretends it was copied off the Mac. Read times never pass it.
let fixtureNow: Int64 = Planner.nsLocal(2026, 11, 6, 0, 30, 0)

struct WriteSummary {
  var schemaStatements = 0
  var skippedStatements: [String] = []
  var tableNames: [String] = []
  var indexNames: [String] = []
  var triggerNames: [String] = []
  var deletedGapRowids: [Int64] = []
  var recentlyDeletedRowids: [Int64] = []
  var failedRowids: [Int64] = []
}

/// Writes the planned timeline into a fresh database built from the real schema.
final class Writer {
  let plan: Planner
  let db: Database
  var rng: Rng
  var summary = WriteSummary()
  let imAccountGUID: String
  let smsAccountGUID: String
  let rcsAccountGUID: String
  /// Message indices in ROWID order.
  private(set) var order: [Int] = []

  init(plan: Planner, db: Database, seed: UInt64) {
    self.plan = plan
    self.db = db
    var r = Rng(seed: seed ^ 0x5752_4954_4552_0001)
    imAccountGUID = r.uuid()
    smsAccountGUID = r.uuid()
    rcsAccountGUID = r.uuid()
    rng = r
  }

  // MARK: schema

  /// The schema dump has two CREATE statements for tables SQLite reserves for itself.
  /// sqlite_sequence appears on its own with the first AUTOINCREMENT table, and
  /// sqlite_stat1 appears when ANALYZE runs at the end.
  static let reservedTables = ["sqlite_sequence", "sqlite_stat1"]

  func loadSchema(_ script: String) throws {
    db.registerMessagesFunctionStubs()
    try db.exec("PRAGMA journal_mode = DELETE")
    try db.exec("PRAGMA page_size = 4096")
    for stmt in splitSQLStatements(script) {
      let s = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      summary.schemaStatements += 1
      if Writer.reservedTables.contains(where: { s.hasPrefix("CREATE TABLE \($0)") }) {
        summary.skippedStatements.append(s)
        continue
      }
      try db.exec(s)
    }
    func names(_ type: String) throws -> [String] {
      try db.rows("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name",
                  [.text(type)]).compactMap { $0[0].text }
    }
    summary.tableNames = try names("table")
    summary.indexNames = try names("index")
    summary.triggerNames = try names("trigger")
  }

  // MARK: ROWIDs

  func assignRowids() {
    order = plan.msgs.indices.sorted { a, b in
      let x = plan.msgs[a].dateNs, y = plan.msgs[b].dateNs
      return x != y ? x < y : a < b
    }
    var next: Int64 = 40001
    var lastGUID: [String: String] = [:]
    for i in order {
      plan.msgs[i].rowid = next
      next += 1
      let chat = plan.msgs[i].chat
      plan.msgs[i].replyToGUID = lastGUID[chat]
      if !plan.msgs[i].gapFiller { lastGUID[chat] = plan.msgs[i].guid }
    }
    var attRow: Int64 = 9001
    for i in order {
      for p in plan.msgs[i].parts {
        if let a = p.attachment {
          plan.atts[a].rowid = attRow
          attRow += 1
        }
      }
    }
    precondition(plan.atts.allSatisfy { $0.rowid != 0 && $0.messageIndex >= 0 }, "attachment without a message")
  }

  // MARK: helpers

  private func handleRowid(_ key: String) -> Int64 { Cast.handle(key).rowid }

  private func plistData(_ obj: NSDictionary) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
  }

  private func accountGUID(_ s: Service) -> String {
    switch s {
    case .iMessage: return imAccountGUID
    case .SMS: return smsAccountGUID
    case .RCS: return rcsAccountGUID
    }
  }

  private func accountLogin(_ s: Service) -> String {
    s == .iMessage ? "E:\(Cast.myEmail)" : "P:\(Cast.myPhone)"
  }

  /// UTF-16 location and length of part `part` inside a message body.
  func partRange(_ m: Msg, _ part: Int) -> (Int, Int) {
    if case .linkBalloon(let url, _, _, _) = m.kind { return (0, Bodies.utf16Length(url)) }
    let p = min(part, m.parts.count - 1)
    let loc = m.parts[..<p].reduce(0) { $0 + Bodies.utf16Length($1.bodyString) }
    return (loc, Bodies.utf16Length(m.parts[p].bodyString))
  }

  private func isBalloon(_ m: Msg) -> Bool {
    if case .linkBalloon = m.kind { return true } else { return false }
  }

  /// The archived body of a row, or nil when the row stores no attributedBody.
  func bodyData(_ m: Msg) -> Data? {
    guard m.bodyString != nil else { return nil }
    var ps = m.parts.enumerated().map { (index: $0.offset, part: $0.element) }
    if case .partial(_, let gone) = m.unsend { ps.removeAll { gone.contains($0.index) } }
    return Bodies.archive(Bodies.attributed(ps, atts: plan.atts), immutable: m.immutableArchive)
  }

  // MARK: rows

  func write() throws {
    try db.exec("BEGIN")
    try insertHandles()
    try insertChats()
    try insertAttachments()
    for i in order { try insertMessage(plan.msgs[i]) }
    try insertAttachmentJoins()
    try postProcess()
    try db.exec("COMMIT")
    try db.exec("ANALYZE")
    try db.exec("VACUUM")
  }

  private func insertHandles() throws {
    for (_, h) in Cast.handles {
      try db.run(
        "INSERT INTO handle (ROWID, id, country, service, uncanonicalized_id, person_centric_id) VALUES (?, ?, ?, ?, ?, NULL)",
        [.int(h.rowid), .text(h.id), h.country.map { .text($0) } ?? .null, .text(h.service.rawValue),
         h.uncanonicalized.map { .text($0) } ?? .null])
    }
  }

  private func insertChats() throws {
    for c in plan.chats {
      let props = NSMutableDictionary()
      props["shouldForceToSMS"] = NSNumber(value: false)
      if c.readReceipts {
        props["EnableReadReceiptForChat"] = NSNumber(value: true)
        props["EnableReadReceiptForChatVersionID"] = NSNumber(value: 1)
      }
      try db.run(
        """
        INSERT INTO chat (ROWID, guid, style, state, account_id, properties, chat_identifier, service_name, room_name,
          account_login, is_archived, last_addressed_handle, display_name, group_id, is_filtered, successful_query,
          ck_sync_state, original_group_id, last_read_message_timestamp)
        VALUES (?, ?, ?, 3, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 0, 1, 1, ?, 0)
        """,
        [.int(c.rowid), .text(c.guid), .int(Int64(c.style)), .text(accountGUID(c.service)), .blob(plistData(props)),
         .text(c.identifier), .text(c.service.rawValue), c.roomName.map { .text($0) } ?? .null,
         .text(c.callerID.contains("@") ? "E:\(c.callerID)" : accountLogin(c.service)), .text(c.callerID),
         .text(c.displayName), .text(c.groupID), .text(c.groupID)])
      for key in c.currentMembers {
        try db.run("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
                   [.int(c.rowid), .int(handleRowid(key))])
      }
    }
  }

  private func insertAttachments() throws {
    for a in plan.atts.sorted(by: { $0.rowid < $1.rowid }) {
      let m = plan.msgs[a.messageIndex]
      let created = m.dateNs / 1_000_000_000
      let userInfo: SQLValue = a.transcript.map { .blob(Bodies.audioUserInfo(transcript: $0)) } ?? .null
      try db.run(
        """
        INSERT INTO attachment (ROWID, guid, created_date, start_date, filename, uti, mime_type, transfer_state,
          is_outgoing, user_info, transfer_name, total_bytes, is_sticker, hide_attachment, ck_sync_state, original_guid,
          preview_generation_state)
        VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?)
        """,
        [.int(a.rowid), .text(a.guid), .int(created), .text(a.dbPath), .text(a.uti), .text(a.mime),
         .int(a.onDisk ? 5 : 0), .int(a.isOutgoing ? 1 : 0), userInfo, .text(a.transferName),
         .int(Int64(a.totalBytes)), .int(a.isSticker ? 1 : 0), .text(a.guid), .int(a.onDisk ? 1 : 0)])
    }
  }

  private func insertMessage(_ m: Msg) throws {
    let c = plan.chat(m.chat)
    let svc = m.service ?? c.service
    let fromMe = m.who == .me && !m.echo
    var cols: [(String, SQLValue)] = []
    func set(_ k: String, _ v: SQLValue) { cols.append((k, v)) }
    func setInt(_ k: String, _ v: Int64) { cols.append((k, .int(v))) }

    set("ROWID", .int(m.rowid))
    set("guid", .text(m.guid))

    let body = bodyData(m)
    if let body {
      set("attributedBody", .blob(body))
      if m.textColumn, let s = m.bodyString { set("text", .text(s)) }
    }

    let handle: Int64
    if m.echo {
      handle = handleRowid("me")
    } else if case .person(let p) = m.who {
      handle = handleRowid(m.handleKey ?? p)
    } else if c.isGroup {
      handle = 0
    } else if c.key == "self" {
      handle = handleRowid("me")
    } else {
      handle = handleRowid(m.handleKey ?? c.currentMembers[0])
    }
    setInt("handle_id", handle)
    setInt("version", 10)
    set("service", .text(svc.rawValue))
    set("account", .text(svc == .iMessage ? "E:\(Cast.myEmail)" : "P:\(Cast.myPhone)"))
    set("account_guid", .text(accountGUID(svc)))
    set("destination_caller_id", .text(svc == .iMessage ? c.callerID : Cast.myPhone))
    setInt("date", m.dateNs)

    // Delivery and read state.
    let delivered = fromMe && !m.failed && !m.notDelivered
    var dateDelivered: Int64 = 0
    var dateRead: Int64 = 0
    var isRead: Int64 = 0
    if fromMe {
      if delivered && svc != .SMS {
        dateDelivered = m.dateNs + Int64(rng.int(400, 4000)) * 1_000_000
      }
      if delivered && svc != .SMS && c.readReceipts && !m.isTapback {
        let r = dateDelivered + Planner.sec(rng.int(15, 5400))
        if r < fixtureNow {
          dateRead = r
          isRead = 1
        }
      }
    } else if !m.unread {
      isRead = 1
      if m.echo {
        dateRead = m.dateNs
      } else {
        dateRead = min(m.dateNs + Planner.sec(rng.int(4, 3 * 3600)), fixtureNow - Planner.sec(60))
      }
    }
    setInt("date_read", dateRead)
    setInt("date_delivered", dateDelivered)
    setInt("is_delivered", fromMe ? (delivered ? 1 : 0) : 1)
    setInt("is_finished", 1)
    setInt("is_from_me", fromMe ? 1 : 0)
    setInt("is_read", isRead)
    setInt("is_sent", fromMe && !m.failed ? 1 : 0)
    setInt("is_prepared", fromMe ? 1 : 0)
    setInt("has_dd_results", m.dataDetected ? 1 : 0)
    setInt("was_data_detected", body != nil ? 1 : 0)
    setInt("ck_sync_state", 1)
    setInt("sort_id", 0)
    setInt("part_count", m.isEvent ? 0 : Int64(m.parts.count))

    if m.isAudio {
      setInt("is_audio_message", 1)
      setInt("is_played", m.played ? 1 : 0)
      if m.played { setInt("date_played", m.dateNs + Planner.sec(rng.int(60, 900))) }
    }
    if let e = m.effect { set("expressive_send_style_id", .text(e)) }

    switch m.kind {
    case .normal:
      break
    case .tapback(let type, let target, let part, let emoji):
      let t = plan.msgs[target]
      let (loc, len) = partRange(t, part)
      set("associated_message_guid", .text(isBalloon(t) ? "bp:\(t.guid)" : "p:\(part)/\(t.guid)"))
      setInt("associated_message_type", Int64(type))
      setInt("associated_message_range_location", Int64(loc))
      setInt("associated_message_range_length", Int64(len))
      if let emoji { set("associated_message_emoji", .text(emoji)) }
    case .placedSticker(let target, let part):
      let t = plan.msgs[target]
      let (loc, len) = partRange(t, part)
      set("associated_message_guid", .text("p:\(part)/\(t.guid)"))
      setInt("associated_message_type", 1000)
      setInt("associated_message_range_location", Int64(loc))
      setInt("associated_message_range_length", Int64(len))
    case .groupEvent(let itemType, let action, let other, let title):
      setInt("item_type", Int64(itemType))
      setInt("group_action_type", Int64(action))
      setInt("other_handle", other.map { handleRowid($0) } ?? 0)
      if let title { set("group_title", .text(title)) }
    case .linkBalloon(let url, let title, let summary, let site):
      set("balloon_bundle_id", .text("com.apple.messages.URLBalloonProvider"))
      set("payload_data", .blob(Bodies.linkPayload(url: url, title: title, summary: summary, site: site)))
    }

    if let r = m.replyToGUID { set("reply_to_guid", .text(r)) }
    if let (t, part) = m.threadTarget {
      let target = plan.msgs[t]
      let (loc, len) = partRange(target, part)
      set("thread_originator_guid", .text(target.guid))
      set("thread_originator_part", .text("\(part):\(loc):\(len)"))
    }

    // Edits and unsends.
    var dateEdited: Int64 = 0
    var dateRetracted: Int64 = 0
    var summaryInfo: Data?
    if !m.editHistory.isEmpty {
      dateEdited = m.editHistory[m.editHistory.count - 1].ns
      summaryInfo = Bodies.editSummary(history: m.editHistory)
    }
    let lengths = m.parts.map { Bodies.utf16Length($0.bodyString) }
    switch m.unsend {
    case .none: break
    case .modern(let at)?:
      dateEdited = at
      summaryInfo = Bodies.unsendSummary(partLengths: lengths, retracted: Array(m.parts.indices))
    case .legacy(let at)?:
      dateRetracted = at
      summaryInfo = Bodies.unsendSummary(partLengths: lengths, retracted: Array(m.parts.indices))
    case .partial(let at, let gone)?:
      dateEdited = at
      summaryInfo = Bodies.unsendSummary(partLengths: lengths, retracted: gone)
    }
    if let summaryInfo { set("message_summary_info", .blob(summaryInfo)) }
    setInt("date_edited", dateEdited)
    setInt("date_retracted", dateRetracted)

    let names = cols.map(\.0).joined(separator: ", ")
    let marks = Array(repeating: "?", count: cols.count).joined(separator: ", ")
    try db.run("INSERT INTO message (\(names)) VALUES (\(marks))", cols.map(\.1))
    try db.run("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)",
               [.int(c.rowid), .int(m.rowid), .int(m.dateNs)])
  }

  private func insertAttachmentJoins() throws {
    for i in order {
      for p in plan.msgs[i].parts {
        if let a = p.attachment {
          try db.run("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)",
                     [.int(plan.msgs[i].rowid), .int(plan.atts[a].rowid)])
        }
      }
    }
  }

  // MARK: after insert

  private func postProcess() throws {
    for i in order {
      let m = plan.msgs[i]
      let chatID = plan.chat(m.chat).rowid
      if m.failed {
        // Messages sets the error after the send attempt, which fires update_last_failed_message_date.
        try db.run("UPDATE message SET error = 4 WHERE ROWID = ?", [.int(m.rowid)])
        summary.failedRowids.append(m.rowid)
      }
      if m.recentlyDeleted {
        // Moves the row to Recently Deleted: the recoverable join keeps the message alive when
        // the chat_message_join row goes away.
        let deleted = m.dateNs + Planner.sec(300)
        try db.run("INSERT INTO chat_recoverable_message_join (chat_id, message_id, delete_date, ck_sync_state) VALUES (?, ?, ?, 0)",
                   [.int(chatID), .int(m.rowid), .int(deleted)])
        try db.run(
          "INSERT INTO recoverable_message_part (chat_id, message_id, part_index, delete_date, part_text, ck_sync_state) VALUES (?, ?, 0, ?, ?, 0)",
          [.int(chatID), .int(m.rowid), .int(deleted), .blob(Bodies.archiveText(m.bodyString ?? ""))])
        try db.run("DELETE FROM chat_message_join WHERE chat_id = ? AND message_id = ?", [.int(chatID), .int(m.rowid)])
        summary.recentlyDeletedRowids.append(m.rowid)
      }
      if m.gapFiller {
        // A permanent delete. The after_delete_on_chat_message_join trigger removes the message
        // row, which leaves a ROWID gap and adds the guid to deleted_messages.
        try db.run("DELETE FROM chat_message_join WHERE chat_id = ? AND message_id = ?", [.int(chatID), .int(m.rowid)])
        summary.deletedGapRowids.append(m.rowid)
      }
    }
    try db.exec(
      """
      UPDATE chat SET last_read_message_timestamp = COALESCE((
        SELECT MAX(m.date) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
        WHERE j.chat_id = chat.ROWID AND m.is_from_me = 0 AND m.is_read = 1), 0)
      """)
  }
}
