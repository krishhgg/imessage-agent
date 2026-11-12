import FixtureKit
import Foundation

// make-fixture [--seed N] [--out DIR] [--schema FILE]
//
// Writes chat.db, Attachments/, manifest.json, contacts.json and README.md into DIR.
// Defaults: seed 20261106, DIR is Tests/Fixtures, FILE is research/chatdb-schema.sql.

let fixturesDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoDir = fixturesDir.deletingLastPathComponent().deletingLastPathComponent()

var seed: UInt64 = 20_261_106
var outDir = fixturesDir
var schemaURL = repoDir.appendingPathComponent("research/chatdb-schema.sql")

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
  switch a {
  case "--seed": seed = UInt64(args.next() ?? "") ?? seed
  case "--out": outDir = URL(fileURLWithPath: args.next() ?? outDir.path)
  case "--schema": schemaURL = URL(fileURLWithPath: args.next() ?? schemaURL.path)
  default:
    FileHandle.standardError.write(Data("usage: make-fixture [--seed N] [--out DIR] [--schema FILE]\n".utf8))
    exit(2)
  }
}

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("make-fixture: \(msg)\n".utf8))
  exit(1)
}

let fm = FileManager.default
let schemaText: String
do {
  schemaText = try String(contentsOf: schemaURL, encoding: .utf8)
} catch {
  fail("cannot read schema at \(schemaURL.path)")
}
let schemaSHA = sha256Hex(Data(schemaText.utf8))

try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
// Remove only files this tool writes.
for name in ["chat.db", "chat.db-journal", "chat.db-wal", "chat.db-shm", "Attachments", "manifest.json", "contacts.json"] {
  try? fm.removeItem(at: outDir.appendingPathComponent(name))
}

let plan = Planner(seed: seed)
plan.buildAll()

let dbURL = outDir.appendingPathComponent("chat.db")
do {
  let writer: Writer
  do {
    let db = try Database(path: dbURL.path)
    writer = Writer(plan: plan, db: db, seed: seed)
    try writer.loadSchema(schemaText)
    writer.assignRowids()
    try writer.write()
  }

  for a in plan.atts where a.onDisk {
    guard let data = a.fileData else { fail("attachment \(a.transferName) has no file data") }
    let url = outDir.appendingPathComponent(a.fixtureRelativePath)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  let dbSHA = sha256Hex(try Data(contentsOf: dbURL))
  let readDB = try Database(path: dbURL.path, readOnly: true)
  let report = Report(plan: plan, writer: writer, db: readDB, seed: seed, schemaSHA: schemaSHA)
  try report.write(to: outDir, dbSHA: dbSHA)

  let rows = try readDB.scalarInt("SELECT COUNT(*) FROM message")
  print("make-fixture: wrote \(dbURL.path)")
  print("make-fixture: \(rows) message rows, \(plan.atts.count) attachments, \(plan.chats.count) chats, seed \(seed)")
  print("make-fixture: skipped \(writer.summary.skippedStatements.count) reserved-table statements, kept \(writer.summary.triggerNames.count) triggers")
} catch {
  fail("\(error)")
}
