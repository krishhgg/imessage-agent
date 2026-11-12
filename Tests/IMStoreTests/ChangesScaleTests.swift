import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport
import SQLite3

/// `changes` cost against cursor age. On the 1.11 million row chat.db of the 2026-11-06 live test, a cursor 1500
/// days old ran past the 2 s budget on every retry.
final class ChangesScaleTests: XCTestCase {
    private let second: Int64 = 1_000_000_000
    private let day: Int64 = 86_400_000_000_000

    /// Runs only when `IMSTORE_LARGE_CHATDB` names a large synthetic copy of the fixture (about 1.1 million rows,
    /// for example from the fixture copied 720 times with dates spread over 6 years, which
    /// `scripts/tests/make-large-chatdb.zsh` builds). Every cursor age must come
    /// back inside the 2 s interactive budget. The rows above the cursor are left to the last 50, as the live test
    /// on 2026-11-06 set them.
    func testCursorOfAnyAgeFitsTheBudgetOnALargeCopy() throws {
        guard let path = ProcessInfo.processInfo.environment["IMSTORE_LARGE_CHATDB"], !path.isEmpty else {
            throw XCTSkip("set IMSTORE_LARGE_CHATDB to a large synthetic chat.db copy")
        }
        let conn = try SQLiteConnection(readOnlyPath: path)
        var newest: Int64 = 0
        var maxRow: Int64 = 0
        try conn.query("SELECT max(date), max(ROWID) FROM message LIMIT ?", [.int(1)]) {
            newest = $0.int(0)
            maxRow = $0.int(1)
        }
        conn.close()
        let clock = FakeClock(now: AppleTime.date(fromNanos: newest + 60 * second))
        let db = try TestStore.database(TestStore.configuration(db: path), clock: clock)
        let reader = ReadService(db: db)
        let now = AppleTime.nanos(from: clock.now)
        var cursors: [(String, String)] = []
        for (name, age) in [("1 minute", 60 * second), ("1 hour", 3_600 * second), ("1 day", day), ("1 week", 7 * day),
                            ("30 days", 30 * day), ("90 days", 90 * day), ("365 days", 365 * day),
                            ("1500 days", 1_500 * day), ("2200 days", 2_200 * day)] {
            cursors.append((name, ChangeCursor(rowid: maxRow - 50, timeNs: now - age).text))
        }
        cursors.append(("1:0", "1:0"))
        for (name, cursor) in cursors {
            let start = Date()
            let page = try reader.changes(ChangesArgs(since: cursor))
            let elapsed = Date().timeIntervalSince(start)
            print("changes cursor \(name): \(String(format: "%.2f", elapsed)) s, \(page.changes.count) records")
            XCTAssertLessThan(elapsed, Limits.interactiveReadTimeout, name)
            XCTAssertFalse(page.changes.isEmpty, name)
        }
    }
}

/// The changes statement's work per row doesn't grow with the number of rows a cursor's window matches.
final class ChangesStatementCostTests: XCTestCase {
    /// On the fixture copied 20 times over (about 31,000 rows), a cursor at time 0 matches nearly every row and a
    /// cursor at now matches none. The statement may only give its columns and neighbor rows to the rows it keeps,
    /// so the old cursor costs about 2.2 times the SQLite steps of the current one, for the window test and the
    /// top-N sort. When every matching row got them before the sort, the old cursor cost about 4.8 times as much,
    /// and on the 1.11 million row chat.db it ran past the 2 s budget on every retry.
    func testOldCursorCostsAboutWhatACurrentOneDoes() throws {
        let copy = try FixtureCopy()
        var columns = ""
        try copy.query("SELECT group_concat(name, ', ') FROM pragma_table_info('message') "
                       + "WHERE name NOT IN ('ROWID', 'guid')") { columns = $0 }
        for k in 1..<20 {
            try copy.exec("""
                INSERT INTO message (ROWID, guid, \(columns)) SELECT ROWID + \(k * 2_000), guid || '-\(k)', \(columns)
                    FROM message WHERE ROWID BETWEEN 40001 AND 41558;
                INSERT INTO chat_message_join (chat_id, message_id, message_date)
                    SELECT chat_id, message_id + \(k * 2_000), message_date FROM chat_message_join
                    WHERE message_id BETWEEN 40001 AND 41558;
                """)
        }
        let old = try steps(copy.path, sinceNs: 0)
        let current = try steps(copy.path, sinceNs: Fixture.nowNs)
        XCTAssertEqual(old.rows, 200)
        XCTAssertEqual(current.rows, 0)
        XCTAssertGreaterThan(old.matching, 25_000)
        XCTAssertLessThan(Double(old.steps), 3 * Double(current.steps),
                          "old cursor \(old.steps) steps, current cursor \(current.steps) steps")
    }

    /// Runs `SQLText.changedRows` for a cursor at `sinceNs` with the clock at the fixture's now and a limit of 200,
    /// and counts SQLite virtual machine steps, rows returned and rows in the window.
    private func steps(_ path: String, sinceNs: Int64) throws -> (steps: Int32, rows: Int, matching: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 0, message: "open")
        }
        defer { sqlite3_close(db) }
        func run(_ sql: String, _ row: (OpaquePointer) -> Void) throws -> Int32 {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StoreError.sqlite(code: 1, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let window = [sinceNs, sinceNs, Int64.max, Fixture.nowNs]
            for i in 0..<sqlite3_bind_parameter_count(stmt) {
                let value: Int64 = i < 28 ? window[Int(i) % 4] : i == 28 ? Int64.max : 200
                sqlite3_bind_int64(stmt, i + 1, value)
            }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw StoreError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
                }
                row(stmt)
            }
            return sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 0)
        }
        var rows = 0
        let count = try run(SQLText.shared.changedRows) { _ in rows += 1 }
        var matching = 0
        let window = SQLText.changedIn("m.date_retracted") + " OR " + SQLText.changedIn("m.date_edited") + " OR "
            + SQLText.changedIn("m.date_read") + " OR " + SQLText.changedIn("m.date_delivered")
        _ = try run("SELECT count(*) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE "
                    + window) {
            matching = Int(sqlite3_column_int64($0, 0))
        }
        return (count, rows, matching)
    }
}
