import Foundation
import IMCore
import SQLite3

/// Errors from the read side. IMBridge maps them to one-line `error: … fix: …` results.
public enum StoreError: Error, Equatable {
    /// open() gave EPERM or sqlite3_open_v2 gave SQLITE_AUTH: no Full Disk Access yet (S1).
    case notPermitted
    case notFound(String)
    /// A target matched more than one contact or conversation (section 5).
    case severalMatches([Candidate])
    case noMatch(String)
    /// An interactive read passed 2 s, or search passed its budget (section 1).
    case timeout
    case rowCapExceeded
    case sqlite(code: Int32, message: String)
    case decode(String)
}

/// SQLite hardening, DESIGN.md section 1 "SQLite hardening (defense in depth)". Owner: IMStore.
///
/// - Opens `file:<path>?mode=ro` with SQLITE_OPEN_READONLY | SQLITE_OPEN_URI. The path is percent-encoded, so a
///   `?` or `#` in it can never add URI parameters.
/// - `sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)`.
/// - Installs `Authorizer` with `sqlite3_set_authorizer`: SELECT, READ and `allowedFunctions` only.
///   ATTACH, PRAGMA writes and load_extension are denied (research/spikes/sqlite-authorizer.md).
/// - Extension loading is off. The system library is built with SQLITE_OMIT_LOAD_EXTENSION; on a build that has
///   it, `sqlite3_enable_load_extension(db, 0)` runs and the open fails if that call fails.
/// - A progress handler enforces the per-call deadline; a row counter enforces the row cap.
/// - A busy database is retried every 10 ms until the call's deadline, and for at most 2 s outside a budget.
///   A busy or locked database reads as `.timeout`.
///
/// Thread safety: one recursive lock guards the handle. `withBudget` holds it for the whole body, so a caller on
/// another thread waits, and that wait counts toward its own deadline.
public final class SQLiteConnection {
    /// Functions the authorizer allows (SQLITE_FUNCTION). Anything else is denied.
    public static let allowedFunctions: Set<String> = [
        "ci_contains", "count", "max", "min", "ifnull", "coalesce", "length", "substr", "instr", "lower", "like",
        "abs", "typeof", "nullif",
    ]

    /// Longest busy wait for every connection, in milliseconds. A budget's deadline can end the wait sooner.
    static let busyTimeoutMs: Int32 = 2_000
    /// Sleep between busy retries, in milliseconds.
    static let busyRetryMs: Int32 = 10

    /// Path the connection was opened with.
    public let path: String

    /// Budget for `query` calls made outside `withBudget`.
    public var defaultTimeout: TimeInterval = Limits.interactiveReadTimeout
    public var defaultRowCap: Int = Limits.defaultRowCap

    /// True once extension loading is known to be off for this handle.
    public private(set) var extensionLoadingDisabled = false

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var budgets: [Budget] = []
    private var statements: [String: OpaquePointer] = [:]
    private static let statementCacheLimit = 128

    private struct Budget {
        var deadline: UInt64
        var rowCap: Int
        var rows: Int
    }

    /// Opens a hardened read-only connection. The bridge passes only `Paths.chatDB` and AddressBook source paths;
    /// tests pass the fixture. No socket op carries a path (section 1, Named operations only).
    public init(readOnlyPath path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(SQLiteConnection.readOnlyURI(for: path), &handle, flags, nil)
        if rc != SQLITE_OK {
            let error = SQLiteConnection.openError(rc: rc, handle: handle, path: path)
            sqlite3_close_v2(handle)
            throw error
        }
        db = handle
        do {
            try harden()
            // Touch the schema now, so a missing grant or a file that isn't a database fails here and not on the
            // first read.
            try withBudget(seconds: defaultTimeout, rowCap: 1) {
                try query("SELECT count(*) FROM sqlite_master LIMIT ?", [.int(1)]) { _ in }
            }
        } catch {
            close()
            if case StoreError.sqlite(let code, _) = error,
               code & 0xFF == SQLITE_AUTH || code & 0xFF == SQLITE_PERM {
                throw StoreError.notPermitted
            }
            throw error
        }
    }

    deinit { close() }

    /// `file:` URI for a path, with every byte outside the unreserved set and `/` percent-encoded.
    static func readOnlyURI(for path: String) -> String {
        var out = "file:"
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "~"), UInt8(ascii: "/"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out + "?mode=ro"
    }

    private static func openError(rc: Int32, handle: OpaquePointer?, path: String) -> StoreError {
        let errno = handle.map { sqlite3_system_errno($0) } ?? 0
        if rc == SQLITE_AUTH || rc == SQLITE_PERM || errno == EPERM || errno == EACCES { return .notPermitted }
        if errno == ENOENT || (rc == SQLITE_CANTOPEN && !FileManager.default.fileExists(atPath: path)) {
            return .notFound(path)
        }
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(rc))
        return .sqlite(code: rc, message: message)
    }

    private func harden() throws {
        guard let db else { throw StoreError.sqlite(code: SQLITE_MISUSE, message: "closed") }
        // sqlite3_busy_timeout would sleep for its full span even past the deadline, because the progress
        // handler never runs while SQLite waits for a lock.
        sqlite3_busy_handler(db, sqliteBusyCallback, Unmanaged.passUnretained(self).toOpaque())

        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        guard sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, -1) == 0 else {
            throw StoreError.sqlite(code: SQLITE_MISUSE, message: "could not set SQLITE_LIMIT_ATTACHED to 0")
        }

        try disableExtensionLoading(db)

        guard sqlite3_set_authorizer(db, sqliteAuthorizerCallback, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: SQLITE_MISUSE, message: "could not install the authorizer")
        }
        sqlite3_progress_handler(db, 1_000, sqliteProgressCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private typealias EnableLoadExtension = @convention(c) (OpaquePointer?, Int32) -> Int32

    private func disableExtensionLoading(_ db: OpaquePointer) throws {
        if sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 1 {
            extensionLoadingDisabled = true
            return
        }
        // The SQL function load_extension() is off unless a caller turns it on, and the Swift module does not
        // export the C switch. Look it up so a library that does export it gets an explicit off, and fail closed
        // if that call fails.
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(defaultHandle, "sqlite3_enable_load_extension") {
            let enable = unsafeBitCast(symbol, to: EnableLoadExtension.self)
            guard enable(db, 0) == SQLITE_OK else {
                throw StoreError.sqlite(code: SQLITE_MISUSE, message: "could not turn off extension loading")
            }
        }
        extensionLoadingDisabled = true
    }

    /// The authorizer's decision for one action. SELECT and READ pass, functions pass only when listed in
    /// `allowedFunctions`, and everything else (ATTACH, PRAGMA, writes, transactions, recursive CTEs) is denied.
    static func authorize(action: Int32, arg1: String?, arg2: String?) -> Int32 {
        switch action {
        case SQLITE_SELECT, SQLITE_READ:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            guard let name = arg2?.lowercased(), allowedFunctions.contains(name) else { return SQLITE_DENY }
            return SQLITE_OK
        default:
            return SQLITE_DENY
        }
    }

    // MARK: Budgets

    private static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func deadline(after seconds: TimeInterval) -> UInt64 {
        let span = seconds.isFinite ? max(0, seconds) : 0
        return nowNanos() &+ UInt64(min(span, 86_400) * 1e9)
    }

    /// Runs `body` with a deadline and row cap. Deadline passing interrupts the statement and throws `.timeout`.
    /// Budgets nest: an inner budget can only tighten the deadline, and every row counts against every open cap.
    public func withBudget<T>(seconds: TimeInterval, rowCap: Int, _ body: () throws -> T) throws -> T {
        let deadline = SQLiteConnection.deadline(after: seconds)
        try enter(deadline: deadline, rowCap: rowCap)
        defer { leave() }
        return try body()
    }

    private func enter(deadline: UInt64, rowCap: Int) throws {
        let now = SQLiteConnection.nowNanos()
        let wait = deadline > now ? TimeInterval(deadline - now) / 1e9 : 0
        guard lock.lock(before: Date(timeIntervalSinceNow: wait)) else { throw StoreError.timeout }
        let outer = budgets.last?.deadline ?? UInt64.max
        budgets.append(Budget(deadline: min(deadline, outer), rowCap: max(0, rowCap), rows: 0))
    }

    private func leave() {
        budgets.removeLast()
        lock.unlock()
    }

    /// Effective deadline of the innermost budget. Read only while the lock is held.
    fileprivate var activeDeadline: UInt64? { budgets.last?.deadline }

    private func checkDeadline() throws {
        if let d = activeDeadline, SQLiteConnection.nowNanos() >= d { throw StoreError.timeout }
    }

    private func countRow() throws {
        for i in budgets.indices {
            budgets[i].rows += 1
            if budgets[i].rows > budgets[i].rowCap { throw StoreError.rowCapExceeded }
        }
    }

    // MARK: Queries

    /// Prepares fixed SQL, binds parameters by position and calls `row` for each result row.
    /// Only one statement is accepted, and the number of parameters must match the SQL.
    public func query(_ sql: String, _ params: [SQLiteValue], row: (SQLiteRow) throws -> Void) throws {
        let deadline = SQLiteConnection.deadline(after: defaultTimeout)
        let now = SQLiteConnection.nowNanos()
        let wait = deadline > now ? TimeInterval(deadline - now) / 1e9 : 0
        guard lock.lock(before: Date(timeIntervalSinceNow: wait)) else { throw StoreError.timeout }
        defer { lock.unlock() }
        if budgets.isEmpty {
            try enter(deadline: deadline, rowCap: defaultRowCap)
            defer { leave() }
            try run(sql, params, row: row)
        } else {
            try run(sql, params, row: row)
        }
    }

    private func run(_ sql: String, _ params: [SQLiteValue], row: (SQLiteRow) throws -> Void) throws {
        guard let db else { throw StoreError.sqlite(code: SQLITE_MISUSE, message: "closed") }
        try checkDeadline()
        let (stmt, cached) = try statement(for: sql, db: db)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            if !cached { sqlite3_finalize(stmt) }
        }
        try bind(params, to: stmt)
        while true {
            try checkDeadline()
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try countRow()
                try row(SQLiteRow(statement: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw stepError(rc, db: db)
            }
        }
    }

    private func stepError(_ rc: Int32, db: OpaquePointer) -> StoreError {
        let primary = rc & 0xFF
        if primary == SQLITE_INTERRUPT || primary == SQLITE_BUSY || primary == SQLITE_LOCKED { return .timeout }
        let errno = sqlite3_system_errno(db)
        if primary == SQLITE_PERM || errno == EPERM || errno == EACCES { return .notPermitted }
        return .sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    private func statement(for sql: String, db: OpaquePointer) throws -> (OpaquePointer, Bool) {
        if let s = statements[sql], sqlite3_stmt_busy(s) == 0 { return (s, true) }
        var stmt: OpaquePointer?
        var trailing = false
        // `tail` points into the C string, which is valid only inside this closure, so it is read here.
        let rc = sql.withCString { text -> Int32 in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v3(db, text, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, &tail)
            if let tail { trailing = !String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return rc
        }
        guard rc == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw StoreError.sqlite(code: rc, message: message)
        }
        if trailing {
            sqlite3_finalize(stmt)
            throw StoreError.sqlite(code: SQLITE_MISUSE, message: "one statement per query")
        }
        if statements[sql] == nil, statements.count < SQLiteConnection.statementCacheLimit {
            statements[sql] = stmt
            return (stmt, true)
        }
        return (stmt, false)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ params: [SQLiteValue], to stmt: OpaquePointer) throws {
        guard Int(sqlite3_bind_parameter_count(stmt)) == params.count else {
            throw StoreError.sqlite(code: SQLITE_RANGE, message: "expected \(sqlite3_bind_parameter_count(stmt)) "
                                    + "parameters, got \(params.count)")
        }
        for (i, value) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, index, v)
            case .text(let s):
                let length = Int32(clamping: s.utf8.count)
                rc = s.withCString { sqlite3_bind_text(stmt, index, $0, length, SQLiteConnection.transient) }
            case .blob(let d):
                if d.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count),
                                                               SQLiteConnection.transient) }
                }
            case .null:
                rc = sqlite3_bind_null(stmt, index)
            }
            guard rc == SQLITE_OK else { throw StoreError.sqlite(code: rc, message: "bind failed") }
        }
    }

    /// Registers `ci_contains(blob, needle)` (section 1, Search). Deterministic and direct-only, so the schema of
    /// the database being read can't call it from a view or trigger.
    public func registerSearchFunctions() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw StoreError.sqlite(code: SQLITE_MISUSE, message: "closed") }
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_DIRECTONLY
        let rc = sqlite3_create_function_v2(db, "ci_contains", 2, flags, nil, ciContainsFunction, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw StoreError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        for stmt in statements.values { sqlite3_finalize(stmt) }
        statements.removeAll()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: Test hooks

    /// Current SQLITE_LIMIT_ATTACHED, or -1 when closed.
    var attachedLimit: Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return -1 }
        return sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, -1)
    }

    /// True when SQLite reports the main database read-only.
    var isReadOnly: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return true }
        return sqlite3_db_readonly(db, "main") == 1
    }
}

private let sqliteAuthorizerCallback: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Int32 = { _, action, arg1, arg2, _, _ in
    SQLiteConnection.authorize(action: action, arg1: arg1.map { String(cString: $0) },
                               arg2: arg2.map { String(cString: $0) })
}

private let sqliteProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
    guard let context else { return 0 }
    let connection = Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue()
    guard let deadline = connection.activeDeadline else { return 0 }
    return DispatchTime.now().uptimeNanoseconds >= deadline ? 1 : 0
}

/// Keeps retrying a busy lock until the active deadline or `busyTimeoutMs`, whichever comes first.
private let sqliteBusyCallback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { context, count in
    guard let context else { return 0 }
    let connection = Unmanaged<SQLiteConnection>.fromOpaque(context).takeUnretainedValue()
    let step = UInt64(SQLiteConnection.busyRetryMs) * 1_000_000
    let waited = UInt64(max(0, count)) * step
    let cap = UInt64(SQLiteConnection.busyTimeoutMs) * 1_000_000
    guard waited < cap else { return 0 }
    var sleep = min(step, cap - waited)
    if let deadline = connection.activeDeadline {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        sleep = min(sleep, deadline - now)
    }
    usleep(useconds_t(max(1, sleep / 1_000)))
    return 1
}

private let releaseNeedle: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
    if let pointer { Unmanaged<NeedleForms>.fromOpaque(pointer).release() }
}

private let ciContainsFunction: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?)
    -> Void = { context, argc, argv in
    guard argc == 2, let argv, let hay = argv[0], let needleValue = argv[1],
          sqlite3_value_type(hay) != SQLITE_NULL, sqlite3_value_type(needleValue) != SQLITE_NULL else {
        sqlite3_result_int(context, 0)
        return
    }
    let forms: NeedleForms
    if let cached = sqlite3_get_auxdata(context, 1) {
        forms = Unmanaged<NeedleForms>.fromOpaque(cached).takeUnretainedValue()
    } else {
        let count = Int(sqlite3_value_bytes(needleValue))
        let text: String
        if let p = sqlite3_value_text(needleValue) {
            text = String(decoding: UnsafeBufferPointer(start: p, count: count), as: UTF8.self)
        } else {
            text = ""
        }
        forms = NeedleForms(text)
        sqlite3_set_auxdata(context, 1, Unmanaged.passRetained(forms).toOpaque(), releaseNeedle)
    }
    let pointer = sqlite3_value_blob(hay)
    let length = Int(sqlite3_value_bytes(hay))
    let matched = forms.matches(UnsafeRawBufferPointer(start: pointer, count: pointer == nil ? 0 : length))
    sqlite3_result_int(context, matched ? 1 : 0)
}

/// The needle of `ci_contains` in NFC and NFD, ASCII-lowercased, ready for a byte search.
final class NeedleForms {
    let forms: [[UInt8]]

    init(_ needle: String) {
        let nfc = Array(needle.precomposedStringWithCanonicalMapping.utf8).map(NeedleForms.foldASCII)
        let nfd = Array(needle.decomposedStringWithCanonicalMapping.utf8).map(NeedleForms.foldASCII)
        forms = nfc == nfd ? [nfc] : [nfc, nfd]
    }

    static func foldASCII(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b }

    func matches(_ hay: UnsafeRawBufferPointer) -> Bool {
        forms.contains { NeedleForms.contains(hay, $0) }
    }

    private static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        let m = needle.count
        if m == 0 { return true }
        let n = hay.count
        guard n >= m else { return false }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if foldASCII(hay[i]) == first {
                var j = 1
                while j < m && foldASCII(hay[i + j]) == needle[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }
}

/// A bound parameter.
public enum SQLiteValue: Hashable {
    case int(Int64)
    case text(String)
    case blob(Data)
    case null
}

/// Column access for one result row. Valid only inside the `query` callback.
public struct SQLiteRow {
    let statement: OpaquePointer

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    public func text(_ i: Int32) -> String? {
        guard sqlite3_column_type(statement, i) != SQLITE_NULL, let p = sqlite3_column_text(statement, i) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: count), as: UTF8.self)
    }
    public func blob(_ i: Int32) -> Data? {
        guard sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
        guard let p = sqlite3_column_blob(statement, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(statement, i)))
    }

    /// The column as Int, or nil when NULL.
    func optionalInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
}

/// Outcome of the Full Disk Access probe: a plain open() first, then sqlite (S1 saw errno 1 and rc 23).
public enum DatabaseProbe: Hashable, Sendable {
    case ok(messageRows: Int64)
    case notPermitted
    case missing
    case failed(String)
}
