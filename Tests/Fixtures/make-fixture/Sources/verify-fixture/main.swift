import FixtureKit
import Foundation
import LinkPresentation

// verify-fixture [--fixture DIR] [--show N]
//
// Opens DIR/chat.db read-only and checks it against DIR/manifest.json. Every attributedBody
// is decoded with NSUnarchiver, so a pass means each typedstream round-trips.

var fixtureDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var showSamples = 12
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
  switch a {
  case "--fixture": fixtureDir = URL(fileURLWithPath: argv.next() ?? fixtureDir.path)
  case "--show": showSamples = Int(argv.next() ?? "") ?? showSamples
  default:
    FileHandle.standardError.write(Data("usage: verify-fixture [--fixture DIR] [--show N]\n".utf8))
    exit(2)
  }
}

var failures: [String] = []
var checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
  checks += 1
  if !ok { failures.append(what()) }
}

let attachmentPrefix = "~/Library/Messages/Attachments/"

/// The decoded typedstream plus the attribute values verify needs.
struct Decoded {
  let string: String
  let className: String
  let transferGUIDs: [String]
  let transcripts: [String]
  let links: [String]
  let partIndices: Set<Int>
  let coveredByPart: Bool
}

func decode(_ data: Data) -> Decoded? {
  guard let obj = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString else { return nil }
  var guids: [String] = []
  var transcripts: [String] = []
  var links: [String] = []
  var parts = Set<Int>()
  var covered = true
  let full = NSRange(location: 0, length: obj.length)
  obj.enumerateAttributes(in: full) { attrs, _, _ in
    if let g = attrs[IMKey.fileTransfer] as? String { guids.append(g) }
    if let t = attrs[IMKey.audioTranscription] as? String { transcripts.append(t) }
    if let u = attrs[IMKey.link] as? URL { links.append(u.absoluteString) }
    if let p = attrs[IMKey.part] as? NSNumber { parts.insert(p.intValue) } else { covered = false }
  }
  return Decoded(string: obj.string, className: String(describing: type(of: obj)), transferGUIDs: guids,
                 transcripts: transcripts, links: links, partIndices: parts, coveredByPart: covered)
}

func plist(_ data: Data) -> NSDictionary? {
  try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
}

func bytesEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

do {
  let dbURL = fixtureDir.appendingPathComponent("chat.db")
  let manifestData = try Data(contentsOf: fixtureDir.appendingPathComponent("manifest.json"))
  let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
  let db = try Database(path: dbURL.path, readOnly: true)

  // Database-level checks.
  check(sha256Hex(try Data(contentsOf: dbURL)) == manifest["db_sha256"] as? String, "db_sha256 does not match manifest")
  check(try db.rows("PRAGMA integrity_check").first?.first?.text == "ok", "integrity_check failed")
  check(try db.rows("PRAGMA foreign_key_check").isEmpty, "foreign_key_check reported rows")
  let schema = manifest["schema"] as! [String: Any]
  let triggers = try db.rows("SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name").compactMap { $0[0].text }
  check(triggers == schema["triggers"] as! [String], "trigger list differs from manifest")
  check(triggers.count == 22, "expected 22 triggers, found \(triggers.count)")

  // Attachment joins and GUIDs per message.
  var joined: [Int64: [String]] = [:]
  for r in try db.rows(
    "SELECT j.message_id, a.guid FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id ORDER BY j.message_id, a.ROWID") {
    joined[r[0].int!, default: []].append(r[1].text!)
  }
  var userInfoTranscripts: [String: String] = [:]
  for r in try db.rows("SELECT guid, user_info FROM attachment WHERE user_info IS NOT NULL") {
    if let d = r[1].blob, let p = plist(d), let t = p["audio-transcription"] as? String { userInfoTranscripts[r[0].text!] = t }
  }

  // Decode every body.
  let rows = try db.rows("SELECT ROWID, text, attributedBody, message_summary_info, payload_data, balloon_bundle_id FROM message ORDER BY ROWID")
  var digest = Data()
  var decodedCount = 0
  var classes: [String: Int] = [:]
  var decodedByRow: [Int64: String] = [:]
  for r in rows {
    let rowid = r[0].int!
    let text = r[1].text
    guard let blob = r[2].blob else {
      check(text == nil, "row \(rowid) has text but no attributedBody")
      check(joined[rowid] == nil, "row \(rowid) has attachments but no body")
      continue
    }
    guard let d = decode(blob) else {
      failures.append("row \(rowid): NSUnarchiver could not decode attributedBody")
      continue
    }
    decodedCount += 1
    decodedByRow[rowid] = d.string
    classes[d.className, default: 0] += 1
    digest.append(contentsOf: Array("\(rowid)\t".utf8))
    digest.append(contentsOf: Array(d.string.utf8))
    digest.append(0x0A)
    check(blob.count > 12 && String(decoding: blob[2..<13], as: UTF8.self) == "streamtyped", "row \(rowid): missing streamtyped header")
    check(d.coveredByPart, "row \(rowid): a range lacks __kIMMessagePartAttributeName")
    if let text { check(bytesEqual(text, d.string), "row \(rowid): text column differs from attributedBody") }
    let placeholders = d.string.unicodeScalars.filter { $0 == "\u{FFFC}" }.count
    let guids = joined[rowid] ?? []
    check(placeholders == guids.count, "row \(rowid): \(placeholders) U+FFFC but \(guids.count) attachment joins")
    check(Set(d.transferGUIDs) == Set(guids), "row \(rowid): file transfer GUIDs differ from joined attachments")
    for g in guids where userInfoTranscripts[g] != nil {
      check(d.transcripts.contains(userInfoTranscripts[g]!), "row \(rowid): transcript attribute differs from user_info")
    }
    for link in d.links { check(d.string.contains(link), "row \(rowid): link attribute \(link) not in body") }

    // Summary info: edits carry typedstream versions, unsends carry rp.
    if let s = r[3].blob {
      guard let info = plist(s) else { failures.append("row \(rowid): message_summary_info is not a plist"); continue }
      if let ec = info["ec"] as? NSDictionary, let versions = ec["0"] as? [NSDictionary] {
        let texts = versions.compactMap { ($0["t"] as? Data).flatMap(decode)?.string }
        check(texts.count == versions.count && texts.count >= 2, "row \(rowid): edit history does not decode")
        check(texts.last.map { bytesEqual($0, d.string) } ?? false, "row \(rowid): last edit differs from body")
      }
    }
    if let p = r[4].blob, r[5].text == "com.apple.messages.URLBalloonProvider" {
      let un = try NSKeyedUnarchiver(forReadingFrom: p)
      un.requiresSecureCoding = false
      let root = un.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary
      let md = root?["richLinkMetadata"] as? LPLinkMetadata
      check(md?.url?.absoluteString == d.string, "row \(rowid): LPLinkMetadata URL differs from body")
    }
  }

  // Unsent rows: no body, rp present.
  let unsent = try db.rows("SELECT ROWID, message_summary_info, date_retracted, date_edited FROM message WHERE attributedBody IS NULL AND item_type = 0")
  for r in unsent {
    let info = r[1].blob.flatMap(plist)
    check(info?["rp"] != nil, "row \(r[0].int!): bodyless row without rp")
    check((r[2].int ?? 0) > 0 || (r[3].int ?? 0) > 0, "row \(r[0].int!): unsend without a date")
  }

  let bodies = manifest["bodies"] as! [String: Any]
  check(decodedCount == bodies["count"] as! Int, "decoded \(decodedCount) bodies, manifest says \(bodies["count"]!)")
  check(sha256Hex(digest) == bodies["sha256"] as? String, "body digest differs from manifest")

  let samples = manifest["samples"] as! [[String: Any]]
  for s in samples {
    let rowid = (s["rowid"] as! NSNumber).int64Value
    check(decodedByRow[rowid].map { bytesEqual($0, s["body"] as! String) } ?? false, "sample row \(rowid) differs")
  }

  // Files on disk.
  let atts = manifest["attachments"] as! [[String: Any]]
  for a in atts {
    let rowid = (a["rowid"] as! NSNumber).int64Value
    let dbRow = try db.rows("SELECT filename, transfer_state, ck_sync_state FROM attachment WHERE ROWID = ?", [.int(rowid)]).first
    guard let dbRow, let filename = dbRow[0].text, filename.hasPrefix(attachmentPrefix) else {
      failures.append("attachment \(rowid): missing or has an unexpected filename")
      continue
    }
    let local = fixtureDir.appendingPathComponent("Attachments").appendingPathComponent(String(filename.dropFirst(attachmentPrefix.count)))
    let onDisk = a["on_disk"] as! Bool
    let exists = FileManager.default.fileExists(atPath: local.path)
    check(exists == onDisk, "attachment \(rowid): file presence is \(exists), expected \(onDisk)")
    check(dbRow[1].int == (onDisk ? 5 : 0), "attachment \(rowid): wrong transfer_state")
    if onDisk, exists, let want = a["file_sha256"] as? String {
      check(sha256Hex(try Data(contentsOf: local)) == want, "attachment \(rowid): file hash differs")
    }
  }

  // Edge-case ROWIDs must exist, except the deliberate gaps and the recently deleted row's join.
  let edges = manifest["edge_cases"] as! [String: [NSNumber]]
  for (key, ids) in edges where key != "rowid_gap" {
    for id in ids {
      let n = try db.scalarInt("SELECT COUNT(*) FROM message WHERE ROWID = ?", [.int(id.int64Value)])
      check(n == 1, "edge \(key): ROWID \(id) missing")
    }
  }
  for id in edges["rowid_gap"] ?? [] {
    check(try db.scalarInt("SELECT COUNT(*) FROM message WHERE ROWID = ?", [.int(id.int64Value)]) == 0, "gap ROWID \(id) exists")
  }

  print("verify-fixture: decoded \(decodedCount) attributedBody blobs with NSUnarchiver (\(classes.keys.sorted().map { "\($0) \(classes[$0]!)" }.joined(separator: ", ")))")
  let showKeys = ["long_body", "photo_with_caption", "unsent_partial", "nfd_text", "emoji_zwj_flag", "non_latin_hangul",
                  "tapback_part_1", "voice_with_transcript", "link_preview_single_row", "mention", "edited_twice", "address_last_month"]
  for key in showKeys.prefix(showSamples) {
    guard let id = edges[key]?.first?.int64Value, let s = decodedByRow[id] else { continue }
    let shown = s.replacingOccurrences(of: "\u{FFFC}", with: "<U+FFFC>").replacingOccurrences(of: "\n", with: "\\n")
    print("  \(key) row \(id): \(shown.count > 90 ? String(shown.prefix(90)) + "..." : shown)")
  }
} catch {
  failures.append("\(error)")
}

if failures.isEmpty {
  print("verify-fixture: all \(checks) checks passed")
} else {
  for f in failures.prefix(40) { print("FAIL: \(f)") }
  print("verify-fixture: \(failures.count) of \(checks) checks failed")
  exit(1)
}
