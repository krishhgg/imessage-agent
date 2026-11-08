import Foundation
import SQLite3

public enum SQLValue {
  case null
  case int(Int64)
  case double(Double)
  case text(String)
  case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Database {
  public let handle: OpaquePointer

  public init(path: String, readOnly: Bool = false) throws {
    var db: OpaquePointer?
    let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    let uri = readOnly ? "file:\(path)?mode=ro" : path
    let openFlags = readOnly ? (flags | SQLITE_OPEN_URI) : flags
    guard sqlite3_open_v2(uri, &db, openFlags, nil) == SQLITE_OK, let db else {
      throw SQLiteError(message: "cannot open \(path)")
    }
    handle = db
  }

  deinit { sqlite3_close_v2(handle) }

  public var lastError: String { String(cString: sqlite3_errmsg(handle)) }

  public func exec(_ sql: String) throws {
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
      let msg = err.map { String(cString: $0) } ?? lastError
      sqlite3_free(err)
      throw SQLiteError(message: "\(msg) in: \(sql.prefix(160))")
    }
  }

  public func prepare(_ sql: String) throws -> Statement {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw SQLiteError(message: "\(lastError) in: \(sql.prefix(160))")
    }
    return Statement(stmt: stmt, db: self)
  }

  /// Runs one statement with bound values and no result rows.
  public func run(_ sql: String, _ values: [SQLValue] = []) throws {
    let st = try prepare(sql)
    try st.bind(values)
    while try st.step() {}
  }

  /// Returns every row as an array of column values.
  public func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
    let st = try prepare(sql)
    try st.bind(values)
    var out: [[SQLValue]] = []
    while try st.step() { out.append(st.row()) }
    return out
  }

  public func scalarInt(_ sql: String, _ values: [SQLValue] = []) throws -> Int64 {
    guard let first = try rows(sql, values).first?.first, case .int(let v) = first else { return 0 }
    return v
  }

  /// Registers no-op versions of the SQL functions that only exist inside Messages, so that
  /// the schema's triggers can stay exactly as Apple wrote them. `is_mic_enabled` returns 0,
  /// every other stub returns NULL.
  public func registerMessagesFunctionStubs() {
    let nullStubs: [(String, Int32)] = [
      ("verify_chat", 1),
      ("delete_attachment_path", 1),
      ("before_delete_attachment_path", 2),
      ("after_delete_message_plugin", 2),
      ("delete_chat_background_before_deleting_chat", 2),
      ("guid_for_chat", 3),
    ]
    for (name, n) in nullStubs {
      sqlite3_create_function_v2(
        handle, name, n, SQLITE_UTF8, nil,
        { ctx, _, _ in sqlite3_result_null(ctx) }, nil, nil, nil)
    }
    sqlite3_create_function_v2(
      handle, "is_mic_enabled", 0, SQLITE_UTF8, nil,
      { ctx, _, _ in sqlite3_result_int(ctx, 0) }, nil, nil, nil)
  }

  public static let stubbedFunctionNames = [
    "verify_chat", "delete_attachment_path", "before_delete_attachment_path",
    "after_delete_message_plugin", "delete_chat_background_before_deleting_chat",
    "guid_for_chat", "is_mic_enabled",
  ]
}

public final class Statement {
  let stmt: OpaquePointer
  unowned let db: Database

  init(stmt: OpaquePointer, db: Database) {
    self.stmt = stmt
    self.db = db
  }

  deinit { sqlite3_finalize(stmt) }

  public func bind(_ values: [SQLValue]) throws {
    sqlite3_reset(stmt)
    sqlite3_clear_bindings(stmt)
    for (i, v) in values.enumerated() {
      let idx = Int32(i + 1)
      let rc: Int32
      switch v {
      case .null: rc = sqlite3_bind_null(stmt, idx)
      case .int(let x): rc = sqlite3_bind_int64(stmt, idx, x)
      case .double(let x): rc = sqlite3_bind_double(stmt, idx, x)
      case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
      case .blob(let d):
        rc = d.withUnsafeBytes { raw in
          sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(d.count), transient)
        }
      }
      if rc != SQLITE_OK { throw SQLiteError(message: "bind \(idx): \(db.lastError)") }
    }
  }

  /// Returns true while a row is available.
  public func step() throws -> Bool {
    let rc = sqlite3_step(stmt)
    if rc == SQLITE_ROW { return true }
    if rc == SQLITE_DONE { return false }
    throw SQLiteError(message: "step: \(db.lastError)")
  }

  public func row() -> [SQLValue] {
    (0..<sqlite3_column_count(stmt)).map { i in
      switch sqlite3_column_type(stmt, i) {
      case SQLITE_INTEGER: return .int(sqlite3_column_int64(stmt, i))
      case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, i))
      case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(stmt, i)))
      case SQLITE_BLOB:
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .blob(Data()) }
        return .blob(Data(bytes: p, count: n))
      default: return .null
      }
    }
  }
}

extension SQLValue {
  public var int: Int64? { if case .int(let v) = self { return v } else { return nil } }
  public var text: String? { if case .text(let v) = self { return v } else { return nil } }
  public var blob: Data? { if case .blob(let v) = self { return v } else { return nil } }
  public var isNull: Bool { if case .null = self { return true } else { return false } }
}

/// Splits a schema dump into complete SQL statements with sqlite3_complete, which
/// understands CREATE TRIGGER bodies that contain inner semicolons.
public func splitSQLStatements(_ script: String) -> [String] {
  var out: [String] = []
  var current = ""
  for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
    if current.isEmpty && line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    current += current.isEmpty ? String(line) : "\n" + line
    if sqlite3_complete(current) != 0 {
      out.append(current)
      current = ""
    }
  }
  if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
  return out
}
