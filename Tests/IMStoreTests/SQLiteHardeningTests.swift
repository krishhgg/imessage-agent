import Foundation
import SQLite3
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist items 1 to 5: read-only URIs, attach and extension limits, the authorizer, fixed SQL with a row cap,
/// and the 2 s and 5 s budgets.
final class SQLiteHardeningTests: XCTestCase {
    // MARK: Item 1, read-only URIs at fixed paths

    func testURIIsReadOnlyAndPercentEncodesEverythingElse() {
        let uri = SQLiteConnection.readOnlyURI(for: "/tmp/a b?mode=rw&vfs=x#frag%")
        XCTAssertEqual(uri, "file:/tmp/a%20b%3Fmode%3Drw%26vfs%3Dx%23frag%25?mode=ro")
        XCTAssertEqual(uri.filter { $0 == "?" }.count, 1, "only the mode parameter may follow the path")
        XCTAssertTrue(uri.hasSuffix("?mode=ro"))
    }

    func testURIEncodesNonASCIIBytes() {
        XCTAssertEqual(SQLiteConnection.readOnlyURI(for: "/tmp/é"), "file:/tmp/%C3%A9?mode=ro")
    }

    func testOpenedConnectionIsReadOnly() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertTrue(conn.isReadOnly)
    }

    func testPathWithQueryCharactersOpensThatFileOnly() throws {
        let dir = TempDir.make()
        let odd = dir.appendingPathComponent("chat?mode=rwc.db").path
        try FileManager.default.copyItem(atPath: Fixture.chatDB.path, toPath: odd)
        let conn = try SQLiteConnection(readOnlyPath: odd)
        defer { conn.close() }
        XCTAssertTrue(conn.isReadOnly)
        var count: Int64 = 0
        try conn.query("SELECT count(*) FROM message LIMIT ?", [.int(1)]) { count = $0.int(0) }
        XCTAssertEqual(count, 1534)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("chat").path))
    }

    func testMissingDatabaseThrowsNotFoundAndCreatesNothing() {
        let path = TempDir.make().appendingPathComponent("absent.db").path
        XCTAssertThrowsError(try SQLiteConnection(readOnlyPath: path)) { error in
            XCTAssertEqual(error as? StoreError, .notFound(path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(ChatDatabase.probe(path: path), .missing)
    }

    func testUnreadableDatabaseIsNotPermitted() throws {
        let copy = try FixtureCopy()
        XCTAssertEqual(chmod(copy.path, 0), 0)
        defer { chmod(copy.path, 0o644) }
        XCTAssertEqual(ChatDatabase.probe(path: copy.path), .notPermitted)
        XCTAssertThrowsError(try SQLiteConnection(readOnlyPath: copy.path)) { error in
            XCTAssertEqual(error as? StoreError, .notPermitted)
        }
    }

    func testProbeCountsMessages() {
        XCTAssertEqual(ChatDatabase.probe(path: Fixture.chatDB.path), .ok(messageRows: 1534))
    }

    func testLiveConfigurationUsesFixedPaths() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let paths = Paths(home: home)
        let config = StoreConfiguration.live(paths: paths)
        XCTAssertEqual(config.chatDBPath, paths.chatDB.path)
        XCTAssertEqual(config.attachmentsRoot, paths.messagesAttachmentsDir)
        XCTAssertEqual(config.attachmentCacheDir, paths.attachmentCacheDir)
    }

    func testEveryStatementIsFixedTextWithATrailingLimit() {
        let all = SQLText.shared.all
        XCTAssertGreaterThan(all.count, 30)
        for (name, sql) in all {
            XCTAssertFalse(sql.contains("'"), "\(name) has a quote")
            XCTAssertFalse(sql.contains("\""), "\(name) has a double quote")
            XCTAssertFalse(sql.contains(";"), "\(name) has a statement separator")
            XCTAssertTrue(sql.hasSuffix("LIMIT ?"), "\(name) has no trailing LIMIT ?")
        }
    }

    func testEveryChatStatementRunsUnderTheAuthorizer() throws {
        let db = try TestStore.database()
        for (name, sql) in SQLText.shared.all where !name.hasPrefix("addressBook") {
            let params = Array(repeating: SQLiteValue.int(0), count: sql.filter { $0 == "?" }.count)
            XCTAssertNoThrow(try db.connection.query(sql, params) { _ in }, name)
        }
    }

    func testEveryAddressBookStatementRunsUnderTheAuthorizer() throws {
        let path = try AddressBookFixture.make(in: TempDir.make()).path
        let conn = try SQLiteConnection(readOnlyPath: path)
        defer { conn.close() }
        for (name, sql) in SQLText.shared.all where name.hasPrefix("addressBook") {
            XCTAssertNoThrow(try conn.query(sql, [.int(0)]) { _ in }, name)
        }
    }

    func testHostileArgumentsStayData() throws {
        let db = try TestStore.database()
        let reader = ReadService(db: db)
        for who in ["7; DROP TABLE message", "x' OR '1'='1", "../../etc/passwd", "file:/etc/passwd?mode=rw",
                    "Mom\u{0}", "chat.db"] {
            XCTAssertThrowsError(try reader.messages(MessagesArgs(who: who, limit: 5)), who)
        }
        let page = try reader.search(SearchArgs(text: "%' OR 1=1 --", inWho: nil, sinceNs: 0, cursor: nil, limit: 20))
        XCTAssertTrue(page.hits.isEmpty)
        XCTAssertEqual(ChatDatabase.probe(path: Fixture.chatDB.path), .ok(messageRows: 1534))
    }

    func testOnlyOneStatementIsAccepted() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertThrowsError(try conn.query("SELECT 1 LIMIT ?; SELECT 2", [.int(1)]) { _ in })
    }

    /// A bridged NSString holding UTF-16 has no UTF-8 buffer, so `withCString` passes SQLite a temporary copy that
    /// is freed when the closure returns. The second-statement check reads SQLite's tail pointer into that copy, so
    /// it must run inside the closure. When it ran after the closure, a debug build missed the second statement and
    /// `--sanitize=address` reported a heap-use-after-free.
    func testOnlyOneStatementIsAcceptedFromSQLWithNoUTF8Buffer() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        func bridged(_ s: String) -> String {
            let units = Array(s.utf16)
            return NSString(characters: units, length: units.count) as String
        }
        let two = bridged("SELECT 'é' LIMIT ?; SELECT 2")
        XCTAssertNil(two.utf8.withContiguousStorageIfAvailable { _ in true }, "withCString must make a temporary copy")
        XCTAssertThrowsError(try conn.query(two, [.int(1)]) { _ in }) { error in
            XCTAssertEqual(error as? StoreError, .sqlite(code: SQLITE_MISUSE, message: "one statement per query"))
        }
        var rows = 0
        try conn.query(bridged("SELECT 'é' LIMIT ?; \n "), [.int(1)]) { _ in rows += 1 }
        XCTAssertEqual(rows, 1, "a trailing semicolon and whitespace are not a second statement")
    }

    func testParameterCountMustMatch() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertThrowsError(try conn.query("SELECT ROWID FROM message LIMIT ?", []) { _ in })
        XCTAssertThrowsError(try conn.query("SELECT ROWID FROM message LIMIT ?", [.int(1), .int(2)]) { _ in })
    }

    // MARK: Item 2, no attached databases and no extensions

    func testAttachedLimitIsZero() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertEqual(conn.attachedLimit, 0)
    }

    func testExtensionLoadingIsOff() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertTrue(conn.extensionLoadingDisabled)
        XCTAssertThrowsError(try conn.query("SELECT load_extension(?) LIMIT ?", [.text("/tmp/x.dylib"), .int(1)]) { _ in })
    }

    func testAttachFails() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let other = try FixtureCopy().path
        XCTAssertThrowsError(try conn.query("ATTACH DATABASE ? AS other", [.text(other)]) { _ in })
    }

    // MARK: Item 3, the authorizer

    func testAuthorizerAllowsOnlySelectReadAndListedFunctions() {
        XCTAssertEqual(SQLiteConnection.authorize(action: SQLITE_SELECT, arg1: nil, arg2: nil), SQLITE_OK)
        XCTAssertEqual(SQLiteConnection.authorize(action: SQLITE_READ, arg1: "message", arg2: "text"), SQLITE_OK)
        for name in SQLiteConnection.allowedFunctions {
            XCTAssertEqual(SQLiteConnection.authorize(action: SQLITE_FUNCTION, arg1: nil, arg2: name), SQLITE_OK, name)
        }
        XCTAssertEqual(SQLiteConnection.authorize(action: SQLITE_FUNCTION, arg1: nil, arg2: "CI_CONTAINS"), SQLITE_OK)
        for name in ["load_extension", "readfile", "writefile", "fts3_tokenizer", "sqlite_version", "random", nil] {
            XCTAssertEqual(SQLiteConnection.authorize(action: SQLITE_FUNCTION, arg1: nil, arg2: name), SQLITE_DENY,
                           name ?? "nil")
        }
        let denied: [Int32] = [SQLITE_ATTACH, SQLITE_DETACH, SQLITE_PRAGMA, SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE,
                               SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_INDEX, SQLITE_DROP_TABLE,
                               SQLITE_TRANSACTION, SQLITE_SAVEPOINT, SQLITE_RECURSIVE, SQLITE_ALTER_TABLE,
                               SQLITE_CREATE_VTABLE, SQLITE_ANALYZE, SQLITE_REINDEX]
        for action in denied {
            XCTAssertEqual(SQLiteConnection.authorize(action: action, arg1: "x", arg2: "y"), SQLITE_DENY, "\(action)")
        }
    }

    func testAllowedFunctionsAreExactlyTheReadOnlySet() {
        XCTAssertEqual(SQLiteConnection.allowedFunctions,
                       ["ci_contains", "count", "max", "min", "ifnull", "coalesce", "length", "substr", "instr",
                        "lower", "like", "abs", "typeof", "nullif"])
    }

    func testPragmaWritesAndUnlistedFunctionsFailOnALiveConnection() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        XCTAssertThrowsError(try conn.query("PRAGMA user_version", []) { _ in })
        XCTAssertThrowsError(try conn.query("PRAGMA writable_schema = 1", []) { _ in })
        XCTAssertThrowsError(try conn.query("SELECT sqlite_version() LIMIT ?", [.int(1)]) { _ in })
        XCTAssertThrowsError(try conn.query("INSERT INTO handle (id) VALUES (?)", [.text("x")]) { _ in })
        XCTAssertThrowsError(try conn.query("DELETE FROM message", []) { _ in })
        XCTAssertThrowsError(try conn.query("CREATE TEMP TABLE t (x)", []) { _ in })
        XCTAssertThrowsError(try conn.query("BEGIN", []) { _ in })
        var count: Int64 = 0
        try conn.query("SELECT count(*) FROM message LIMIT ?", [.int(1)]) { count = $0.int(0) }
        XCTAssertEqual(count, 1534)
    }

    // MARK: Item 4, fixed SQL with bound parameters and a row cap

    func testRowCapAllowsExactlyTheCapAndFailsOneAbove() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let sql = "SELECT ROWID FROM message ORDER BY ROWID LIMIT ?"
        var seen = 0
        try conn.withBudget(seconds: 2, rowCap: 10) {
            try conn.query(sql, [.int(10)]) { _ in seen += 1 }
        }
        XCTAssertEqual(seen, 10)
        XCTAssertThrowsError(try conn.withBudget(seconds: 2, rowCap: 10) {
            try conn.query(sql, [.int(11)]) { _ in }
        }) { XCTAssertEqual($0 as? StoreError, .rowCapExceeded) }
    }

    func testNestedBudgetsCountRowsAgainstEveryCap() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let sql = "SELECT ROWID FROM message ORDER BY ROWID LIMIT ?"
        XCTAssertThrowsError(try conn.withBudget(seconds: 2, rowCap: 15) {
            try conn.withBudget(seconds: 2, rowCap: 10) { try conn.query(sql, [.int(8)]) { _ in } }
            try conn.withBudget(seconds: 2, rowCap: 10) { try conn.query(sql, [.int(8)]) { _ in } }
        }) { XCTAssertEqual($0 as? StoreError, .rowCapExceeded) }
    }

    func testDefaultRowCapAppliesWithoutABudget() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        conn.defaultRowCap = 3
        XCTAssertThrowsError(try conn.query("SELECT ROWID FROM message LIMIT ?", [.int(4)]) { _ in }) {
            XCTAssertEqual($0 as? StoreError, .rowCapExceeded)
        }
        var n = 0
        try conn.query("SELECT ROWID FROM message LIMIT ?", [.int(3)]) { _ in n += 1 }
        XCTAssertEqual(n, 3)
    }

    func testSessionBindsTheLimitAtTheRowCap() throws {
        let db = try TestStore.database(TestStore.configuration(rowCap: 7))
        let rows = try db.interactive { s in
            try s.rows(SQLText.shared.rowsInRange, [.int(0), .int(Int64.max)], limit: 1_000)
        }
        XCTAssertEqual(rows.count, 7)
    }

    func testReadsStillWorkWithASmallRowCap() throws {
        let db = try TestStore.database(TestStore.configuration(rowCap: 50))
        let page = try ReadService(db: db).messages(MessagesArgs(who: "Mom", limit: 30))
        XCTAssertEqual(page.messages.count, 30)
    }

    /// Past the row cap, unread keeps the newest rows, not the oldest. The chat list has its own cap, so a small
    /// row cap still loads every chat.
    func testRowCapKeepsTheNewestUnreadRowsAndEveryChat() throws {
        let db = try TestStore.database(TestStore.configuration(rowCap: 3))
        let (unread, chats) = try db.interactive { s in
            (try s.unreadRows().map(\.rowid), try s.index().chats.keys.sorted())
        }
        XCTAssertEqual(unread, [41555, 41556, 41557])
        XCTAssertEqual(chats, try fixtureRowIDs("SELECT ROWID FROM chat ORDER BY ROWID LIMIT ?"))
    }

    /// The chat list and member loads bind their cap plus one and fail past it, so no call works from an index
    /// with chats or members cut off. The fixture has 8 chats and 13 member rows. The account handles read the
    /// chat list when the database opens, so a chat list past the cap fails there.
    func testIndexLoadsFailPastTheirOwnCap() throws {
        XCTAssertEqual(StoreConfiguration.defaultIndexRowCap, 200_000)
        XCTAssertEqual(TestStore.configuration().indexRowCap, 200_000)
        XCTAssertEqual(try fixtureRowIDs("SELECT count(*) FROM chat LIMIT ?"), [8])
        XCTAssertEqual(try fixtureRowIDs("SELECT count(*) FROM chat_handle_join LIMIT ?"), [13])
        func configuration(_ cap: Int) -> StoreConfiguration {
            var c = TestStore.configuration()
            c.indexRowCap = cap
            return c
        }
        XCTAssertThrowsError(try TestStore.database(configuration(7))) { error in
            XCTAssertEqual(error as? StoreError, .rowCapExceeded)
        }
        for cap in [8, 12] {
            let db = try TestStore.database(configuration(cap))
            XCTAssertThrowsError(try db.resolve("Mom"), "cap \(cap)") { error in
                XCTAssertEqual(error as? StoreError, .rowCapExceeded, "cap \(cap)")
            }
            XCTAssertThrowsError(try ReadService(db: db).chats(ChatsArgs()), "cap \(cap)")
        }
        let db = try TestStore.database(configuration(13))
        XCTAssertEqual(try db.resolve("Mom").chatRowIDs, [7])
        XCTAssertEqual(try ReadService(db: db).chats(ChatsArgs(limit: 50)).chats.count, 8)
    }

    // MARK: Item 5, 2 s interactive timeout and 5 s search budget

    func testDefaultBudgetsAreTwoAndFiveSeconds() throws {
        XCTAssertEqual(Limits.interactiveReadTimeout, 2)
        XCTAssertEqual(Limits.searchBudget, 5)
        XCTAssertEqual(SQLiteConnection.busyTimeoutMs, 2_000)
        let db = try TestStore.database()
        XCTAssertEqual(db.configuration.interactiveTimeout, 2)
        XCTAssertEqual(db.configuration.searchBudget, 5)
        XCTAssertEqual(db.connection.defaultTimeout, 2)
        XCTAssertEqual(db.searchConnection.defaultTimeout, 5)
    }

    func testSlowQueryIsInterruptedAtTheDeadlineAndTheConnectionRecovers() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let started = Date()
        XCTAssertThrowsError(try conn.withBudget(seconds: 0.1, rowCap: 10) {
            try conn.query("SELECT count(*) FROM message a, message b, message c LIMIT ?", [.int(1)]) { _ in }
        }) { XCTAssertEqual($0 as? StoreError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        var count: Int64 = 0
        try conn.query("SELECT count(*) FROM message LIMIT ?", [.int(1)]) { count = $0.int(0) }
        XCTAssertEqual(count, 1534)
    }

    /// SQLite runs no progress handler while it waits for a lock, so the busy handler is what stops at the
    /// deadline. A plain 2 s busy timeout would run past a 0.3 s budget.
    func testLockedDatabaseTimesOutAtTheDeadlineNotTheBusyTimeout() throws {
        let copy = try FixtureCopy()
        let conn = try SQLiteConnection(readOnlyPath: copy.path)
        defer { conn.close() }
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(copy.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let started = Date()
        XCTAssertThrowsError(try conn.withBudget(seconds: 0.3, rowCap: 10) {
            try conn.query("SELECT count(*) FROM message LIMIT ?", [.int(1)]) { _ in }
        }) { XCTAssertEqual($0 as? StoreError, .timeout) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        var count: Int64 = 0
        try conn.query("SELECT count(*) FROM message LIMIT ?", [.int(1)]) { count = $0.int(0) }
        XCTAssertEqual(count, 1534)
    }

    func testInnerBudgetCannotExtendTheOuterDeadline() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let started = Date()
        XCTAssertThrowsError(try conn.withBudget(seconds: 0.1, rowCap: 10) {
            try conn.withBudget(seconds: 30, rowCap: 10) {
                try conn.query("SELECT count(*) FROM message a, message b, message c LIMIT ?", [.int(1)]) { _ in }
            }
        }) { XCTAssertEqual($0 as? StoreError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testWaitingForTheConnectionCountsTowardTheDeadline() throws {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? conn.withBudget(seconds: 5, rowCap: 1) {
                holding.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            done.signal()
        }
        holding.wait()
        let started = Date()
        XCTAssertThrowsError(try conn.withBudget(seconds: 0.1, rowCap: 1) {}) {
            XCTAssertEqual($0 as? StoreError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        release.signal()
        done.wait()
    }

    func testInteractiveCallTimesOutBehindAHeldConnection() throws {
        let db = try TestStore.database(TestStore.configuration(timeout: 0.2))
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? db.interactive { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 10)
            }
            done.signal()
        }
        holding.wait()
        let started = Date()
        XCTAssertThrowsError(try ReadService(db: db).chats(ChatsArgs(limit: 5, unreadOnly: false))) {
            XCTAssertEqual($0 as? StoreError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
        release.signal()
        done.wait()
    }

    func testSearchRunsOnItsOwnConnection() throws {
        let db = try TestStore.database()
        XCTAssertFalse(db.connection === db.searchConnection)
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? db.interactive { _ in
                holding.signal()
                release.wait()
            }
            done.signal()
        }
        holding.wait()
        let page = try ReadService(db: db).search(SearchArgs(text: "juniper", inWho: nil, sinceNs: nil, cursor: nil,
                                                             limit: 5))
        XCTAssertFalse(page.hits.isEmpty)
        release.signal()
        done.wait()
    }
}
