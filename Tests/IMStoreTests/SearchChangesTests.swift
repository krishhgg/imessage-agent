import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist items 12 to 15: search, ci_contains, changes, and skipping the bridge's own sends.
final class SearchChangesTests: XCTestCase {
    private var reader: ReadService!
    private let second: Int64 = 1_000_000_000
    private let day: Int64 = 86_400_000_000_000

    override func setUpWithError() throws {
        reader = try TestStore.reader()
    }

    private func hits(_ text: String, inWho: String? = nil, sinceNs: Int64? = nil, limit: Int = 50) throws -> [Int64] {
        try reader.search(SearchArgs(text: text, inWho: inWho, sinceNs: sinceNs, limit: limit)).hits.map(\.message.rowid)
    }

    // MARK: Item 12, search

    func testSearchFindsAttributedBodyRowsNewestFirst() throws {
        let page = try reader.search(SearchArgs(text: "Juniper Hollow", limit: 20))
        XCTAssertEqual(page.hits.first?.message.rowid, 41381)
        XCTAssertEqual(page.hits.first?.chat.rowid, 9)
        XCTAssertEqual(page.hits.first?.chat.label, "Dad")
        XCTAssertFalse(page.hits.map(\.message.rowid).contains(Manifest.first("address_decoy_june")))
        let dates = page.hits.map(\.message.dateNs)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertEqual(try hits("library books"), [41333, 40998, 40919, 40735])
    }

    func testSearchFindsTextColumnRowsThroughLike() throws {
        let rows = Manifest.edge("text_column_populated")
        XCTAssertTrue(try hits("package for you was left", sinceNs: 0).contains(rows[0]))
        XCTAssertTrue(try hits("THIS IS MARCO", sinceNs: 0).contains(rows[2]))
    }

    func testSearchConfirmsOnTheDecodedBody() throws {
        XCTAssertEqual(try hits("NSAttributedString", sinceNs: 0), [])
        XCTAssertEqual(try hits("__kIMMessagePartAttributeName", sinceNs: 0), [])
        XCTAssertEqual(try hits("streamtyped", sinceNs: 0), [])
    }

    func testSearchSkipsTapbacksEventsAndHiddenRows() throws {
        let found = try hits("Loved", sinceNs: 0, limit: 200)
        let tapbacks = Set(try fixtureRowIDs("SELECT ROWID FROM message WHERE associated_message_type BETWEEN 2000 "
                                             + "AND 3999 LIMIT ?"))
        XCTAssertTrue(Set(found).isDisjoint(with: tapbacks))
        let echoes = Set(Manifest.edge("self_echo_assumed"))
        XCTAssertTrue(Set(try hits("Cabin check-in", sinceNs: 0)).isDisjoint(with: echoes))
        XCTAssertFalse(try hits("Fam", sinceNs: 0, limit: 200).contains(40016))
    }

    func testSearchWindowIsOneYear() throws {
        XCTAssertEqual(Limits.searchWindowDays, 365)
        let page = try reader.search(SearchArgs(text: "lockbox", limit: 20))
        XCTAssertEqual(page.windowStartNs, Fixture.nowNs - 365 * day)
        XCTAssertEqual(page.hits.map(\.message.rowid), [40909, 40832])
        XCTAssertEqual(page.scannedBackToNs, page.windowStartNs)
        XCTAssertNil(page.nextCursor)
        XCTAssertFalse(page.budgetExhausted)
        XCTAssertEqual(try hits("lockbox", sinceNs: 0), [40909, 40832, 40001])
        let narrow = try reader.search(SearchArgs(text: "lockbox", sinceNs: 801_293_133_008_085_000, limit: 20))
        XCTAssertEqual(narrow.hits.map(\.message.rowid), [40909, 40832])
        XCTAssertEqual(try hits("lockbox", sinceNs: 801_293_133_008_085_001), [40909])
    }

    func testWindowLengthFollowsTheConfiguration() throws {
        let db = try TestStore.database(TestStore.configuration(windowDays: 30))
        let page = try ReadService(db: db).search(SearchArgs(text: "dentist", limit: 20))
        XCTAssertEqual(page.windowStartNs, Fixture.nowNs - 30 * day)
        XCTAssertTrue(page.hits.allSatisfy { $0.message.dateNs >= page.windowStartNs })
    }

    func testCursorContinuesWithoutGapsOrRepeats() throws {
        let all = try hits("dinner", sinceNs: 0, limit: 200)
        XCTAssertGreaterThan(all.count, 4)
        var seen: [Int64] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try reader.search(SearchArgs(text: "dinner", sinceNs: 0, cursor: cursor, limit: 2))
            seen += page.hits.map(\.message.rowid)
            if let last = page.hits.last { XCTAssertLessThanOrEqual(page.scannedBackToNs, last.message.dateNs) }
            XCTAssertGreaterThanOrEqual(page.scannedBackToNs, page.windowStartNs)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 100
        XCTAssertEqual(seen, all)
    }

    func testCursorTextCarriesTheWindowStart() throws {
        let page = try reader.search(SearchArgs(text: "dinner", limit: 1))
        let cursor = try XCTUnwrap(page.nextCursor)
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false).map { Int64($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[2], page.windowStartNs)
        XCTAssertEqual(parts[0], page.hits[0].message.dateNs)
        XCTAssertEqual(parts[1], page.hits[0].message.rowid)
    }

    func testCursorWrittenAfterAnyHitResumesRightAfterIt() throws {
        let all = try reader.search(SearchArgs(text: "dinner", sinceNs: 0, limit: 200))
        XCTAssertGreaterThan(all.hits.count, 3)
        let hit = all.hits[2].message
        let cursor = SearchCursor(dateNs: hit.dateNs, rowid: hit.rowid, windowStartNs: all.windowStartNs).text
        let rest = try reader.search(SearchArgs(text: "dinner", cursor: cursor, limit: 200))
        XCTAssertEqual(rest.hits.map(\.message.rowid), all.hits.dropFirst(3).map(\.message.rowid))
        XCTAssertEqual(rest.windowStartNs, 0)
    }

    func testHitsCarryTheJoinDateTheCursorPagesOn() throws {
        let copy = try FixtureCopy()
        let first = try XCTUnwrap(try reader.search(SearchArgs(text: "dinner", sinceNs: 0, limit: 200)).hits.first)
        try copy.exec("""
            UPDATE chat_message_join SET message_date = message_date - \(5 * second)
            WHERE message_id = \(first.message.rowid)
            """)
        let page = try ReadService(db: try copy.database()).search(SearchArgs(text: "dinner", sinceNs: 0, limit: 200))
        let hit = try XCTUnwrap(page.hits.first { $0.message.rowid == first.message.rowid })
        XCTAssertEqual(hit.cursorNs, hit.message.dateNs - 5 * second)
        let rest = try ReadService(db: try copy.database()).search(SearchArgs(
            text: "dinner", cursor: SearchCursor(dateNs: try XCTUnwrap(hit.cursorNs), rowid: hit.message.rowid,
                                                 windowStartNs: page.windowStartNs).text, limit: 200))
        let index = try XCTUnwrap(page.hits.firstIndex(of: hit))
        XCTAssertEqual(rest.hits.map(\.message.rowid), page.hits.dropFirst(index + 1).map(\.message.rowid))
    }

    func testContinuedSearchKeepsItsWindowWhenTheClockMoves() throws {
        let clock = FakeClock()
        let r = ReadService(db: try TestStore.database(clock: clock))
        let first = try r.search(SearchArgs(text: "lockbox", limit: 1))
        XCTAssertEqual(first.hits.map(\.message.rowid), [40909])
        clock.advance(400 * 86_400)
        let rest = try r.search(SearchArgs(text: "lockbox", cursor: first.nextCursor, limit: 20))
        XCTAssertEqual(rest.windowStartNs, first.windowStartNs)
        XCTAssertEqual(rest.hits.map(\.message.rowid), [40832])
        XCTAssertNil(rest.nextCursor)
        let below = SearchCursor(dateNs: first.windowStartNs - 1, rowid: 0, windowStartNs: first.windowStartNs).text
        let empty = try r.search(SearchArgs(text: "lockbox", cursor: below, limit: 20))
        XCTAssertEqual(empty.hits, [])
        XCTAssertNil(empty.nextCursor)
    }

    func testSearchInOneConversation() throws {
        let page = try reader.search(SearchArgs(text: "dinner", inWho: "Mom", sinceNs: 0, limit: 50))
        XCTAssertEqual(page.inChat?.rowid, 7)
        XCTAssertFalse(page.hits.isEmpty)
        XCTAssertTrue(page.hits.allSatisfy { $0.chat.rowid == 7 && $0.message.chatRowID == 7 })
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 90, guid: "SMS;-;+14155550101", identifier: "+14155550101", service: "SMS", handles: [8])
        try copy.insertMessage(rowid: 41600, guid: "MOM-SMS", chat: 90, handle: 8, text: "dinner by sms", fromMe: false,
                               date: Fixture.nowNs - 60 * second, service: "SMS")
        let merged = try ReadService(db: try copy.database())
            .search(SearchArgs(text: "dinner", inWho: "Mom", sinceNs: 0, limit: 50))
        XCTAssertEqual(merged.hits.first?.message.rowid, 41600)
        XCTAssertEqual(Set(merged.hits.map(\.message.chatRowID)), [7, 90])
    }

    func testBadSearchArgumentsThrow() {
        for text in ["", "   "] {
            XCTAssertThrowsError(try reader.search(SearchArgs(text: text))) { error in
                guard case StoreError.decode = error else { return XCTFail("\(error)") }
            }
        }
        for cursor in ["x", "1", "1:2", "1:2:3:4", "::", "a:b:c", "1:2:", ":2:3", "1.5:2:3"] {
            XCTAssertThrowsError(try reader.search(SearchArgs(text: "dinner", cursor: cursor)), cursor)
        }
        XCTAssertThrowsError(try reader.search(SearchArgs(text: "dinner", inWho: "Nobody")))
    }

    func testSearchTextOver500CharactersIsRefusedBeforeAnyRead() throws {
        let over = String(repeating: "d", count: Limits.searchQueryMaxChars + 1)
        XCTAssertThrowsError(try reader.search(SearchArgs(text: over, sinceNs: 0))) { error in
            XCTAssertEqual(error as? WireError,
                           .message("search text is over 500 characters", fix: "search a shorter phrase"))
        }
        let longest = String(repeating: "\u{1F600}", count: Limits.searchQueryMaxChars)
        XCTAssertEqual(try reader.search(SearchArgs(text: longest, sinceNs: 0)).hits.count, 0)
    }

    func testLikeWildcardsAreLiteral() throws {
        XCTAssertEqual(SearchQuery.escapeLike("50%_off\\"), "50\\%\\_off\\\\")
        let percent = try hits("%", sinceNs: 0, limit: 200)
        XCTAssertLessThan(percent.count, 20)
        let underscore = try hits("_", sinceNs: 0, limit: 200)
        XCTAssertLessThan(underscore.count, 20)
    }

    func testSearchLeavesTheDatabaseUntouched() throws {
        let copy = try FixtureCopy()
        let before = try Data(contentsOf: URL(fileURLWithPath: copy.path))
        let r = ReadService(db: try copy.database())
        _ = try r.search(SearchArgs(text: "dinner", sinceNs: 0, limit: 50))
        _ = try r.search(SearchArgs(text: "café", sinceNs: 0, limit: 50))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy.path)), before)
        let files = try FileManager.default.contentsOfDirectory(atPath: copy.dir.path)
        XCTAssertEqual(files, ["chat.db"])
    }

    func testBudgetExhaustionReportsHowFarItGotAndTheCursorFinishesTheWindow() throws {
        let copy = try FixtureCopy()
        try copy.exec("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 150000)
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read)
            SELECT 100000 + i, 'FILL-' || i, 'filler row ' || i, 3, 'iMessage', \(Fixture.nowNs) - i * 200000000000, 0, 1
            FROM n;
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            SELECT 7, ROWID, date FROM message WHERE ROWID > 100000;
            """)
        let db = try copy.database(searchBudget: 0.05)
        let r = ReadService(db: db)
        var page = try r.search(SearchArgs(text: "lockbox", sinceNs: 0, limit: 20))
        XCTAssertTrue(page.budgetExhausted)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertGreaterThan(page.scannedBackToNs, page.windowStartNs)
        var found = page.hits.map(\.message.rowid)
        var calls = 1
        var last = page.scannedBackToNs
        while let cursor = page.nextCursor, calls < 500 {
            let incoming = try XCTUnwrap(SearchCursor(text: cursor))
            page = try r.search(SearchArgs(text: "lockbox", sinceNs: 0, cursor: cursor, limit: 20))
            XCTAssertLessThan(page.scannedBackToNs, last, "call \(calls)")
            if page.budgetExhausted, let next = page.nextCursor.flatMap(SearchCursor.init(text:)) {
                XCTAssertTrue((next.dateNs, next.rowid) < (incoming.dateNs, incoming.rowid), "call \(calls)")
            }
            last = page.scannedBackToNs
            found += page.hits.map(\.message.rowid)
            calls += 1
        }
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.scannedBackToNs, page.windowStartNs)
        XCTAssertEqual(found, [40909, 40832, 40001])
        XCTAssertGreaterThan(calls, 1)
    }

    func testSearchSlicesStartAtOneHourAndDoubleUpToSevenDays() {
        let hour: Int64 = 3_600 * second
        XCTAssertEqual((0...9).map { ReadService.searchSliceSpan(completed: $0) / hour },
                       [1, 2, 4, 8, 16, 32, 64, 128, 168, 168])
        XCTAssertEqual(ReadService.searchSliceSpan(completed: -1), hour)
        XCTAssertEqual(ReadService.searchSliceSpan(completed: 61), 7 * day)
        XCTAssertEqual(ReadService.searchSliceSpan(completed: 62), 7 * day)
        XCTAssertEqual(ReadService.searchSliceSpan(completed: Int.max), 7 * day)
    }

    /// Rows too many to scan in one call start 2 hours below the cursor. A call that runs out of budget has
    /// finished its first, 1-hour slice, so every exhausted page hands back a cursor older than the one it got,
    /// and paging still finds every hit.
    func testExhaustedSearchStillMovesTheCursor() throws {
        let copy = try FixtureCopy()
        let hour: Int64 = 3_600 * second
        let top = Fixture.nowNs
        try copy.exec("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 239999)
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read)
            SELECT 100000 + i, 'DENSE-' || i, 'filler row ' || i, 3, 'iMessage', \(top - 2 * hour) - i * \(3 * second),
                0, 1
            FROM n;
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            SELECT 7, ROWID, date FROM message WHERE ROWID >= 100000;
            """)
        let r = ReadService(db: try copy.database(searchBudget: 0.05))
        var cursor = SearchCursor(dateNs: top, rowid: Int64.max, windowStartNs: 0).text
        var page = try r.search(SearchArgs(text: "lockbox", cursor: cursor, limit: 20))
        XCTAssertTrue(page.budgetExhausted)
        let first = try XCTUnwrap(page.nextCursor.flatMap(SearchCursor.init(text:)))
        XCTAssertLessThanOrEqual(first.dateNs, top - hour)
        XCTAssertGreaterThan(first.dateNs, page.windowStartNs)
        var found = page.hits.map(\.message.rowid)
        var exhausted = 1
        var calls = 1
        while let next = page.nextCursor, calls < 300 {
            let incoming = try XCTUnwrap(SearchCursor(text: cursor))
            let returned = try XCTUnwrap(SearchCursor(text: next))
            if page.budgetExhausted {
                let moved = (returned.dateNs, returned.rowid) < (incoming.dateNs, incoming.rowid)
                XCTAssertTrue(moved, "call \(calls)")
                if !moved { break }
            }
            cursor = next
            page = try r.search(SearchArgs(text: "lockbox", cursor: cursor, limit: 20))
            if page.budgetExhausted { exhausted += 1 }
            found += page.hits.map(\.message.rowid)
            calls += 1
        }
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(found, [40909, 40832, 40001])
        XCTAssertGreaterThanOrEqual(exhausted, 1)
    }

    /// The first hit's visibility check loads the conversation index, and 20,000 extra chats make that load take
    /// far longer than the 50 ms scan budget. The call runs out of budget inside the check, so its cursor must
    /// still cover the hit, and a continued search finds it.
    func testBudgetRunningOutInTheVisibilityCheckKeepsTheRow() throws {
        let copy = try FixtureCopy()
        try copy.exec("""
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < 19999)
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name)
            SELECT 500000 + i, 'any;-;+1650555' || (100000 + i), 45, '+1650555' || (100000 + i), 'iMessage', ''
            FROM n;
            """)
        let short = ReadService(db: try copy.database(searchBudget: 0.0625))
        let page = try short.search(SearchArgs(text: "lockbox", sinceNs: 0, limit: 20))
        XCTAssertTrue(page.budgetExhausted)
        XCTAssertEqual(page.hits.map(\.message.rowid), [])
        let cursor = try XCTUnwrap(page.nextCursor)
        let long = ReadService(db: try copy.database(searchBudget: 60))
        let rest = try long.search(SearchArgs(text: "lockbox", sinceNs: 0, cursor: cursor, limit: 20))
        XCTAssertFalse(rest.budgetExhausted)
        XCTAssertNil(rest.nextCursor)
        XCTAssertEqual(rest.hits.map(\.message.rowid), [40909, 40832, 40001])
    }

    // MARK: Item 13, ci_contains

    func testCIContainsFoldsASCIICaseOnly() {
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("Hello World".utf8), needle: "wORLD"))
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("ABC".utf8), needle: "abc"))
        XCTAssertFalse(CaseInsensitiveContains.matches(haystack: Data("Hello".utf8), needle: "world"))
        XCTAssertFalse(CaseInsensitiveContains.matches(haystack: Data("CAFÉ".utf8), needle: "café"))
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("CAFÉ".utf8), needle: "cafÉ"))
        XCTAssertFalse(CaseInsensitiveContains.matches(haystack: Data(), needle: "a"))
        XCTAssertFalse(CaseInsensitiveContains.matches(haystack: Data("ab".utf8), needle: "abc"))
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("xxabc".utf8), needle: "ABC"))
        XCTAssertFalse(CaseInsensitiveContains.matches(haystack: Data("@[".utf8), needle: "`{"))
    }

    func testCIContainsChecksNFCAndNFD() {
        let nfc = "caf\u{E9}"
        let nfd = "cafe\u{301}"
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("the \(nfd) on 5th".utf8), needle: nfc))
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("the \(nfc) on 5th".utf8), needle: nfd))
        XCTAssertTrue(CaseInsensitiveContains.matches(haystack: Data("THE \(nfd)".utf8), needle: "the " + nfc))
    }

    func testCIContainsRunsInSQLAndTreatsNullAsNoMatch() throws {
        let db = try TestStore.database()
        func run(_ hay: SQLiteValue, _ needle: SQLiteValue) throws -> Int64 {
            var v: Int64 = -1
            try db.connection.query("SELECT ci_contains(?, ?) LIMIT ?", [hay, needle, .int(1)]) { v = $0.int(0) }
            return v
        }
        XCTAssertEqual(try run(.blob(Data("Hello World".utf8)), .text("WORLD")), 1)
        XCTAssertEqual(try run(.text("Hello"), .text("world")), 0)
        XCTAssertEqual(try run(.null, .text("x")), 0)
        XCTAssertEqual(try run(.blob(Data("x".utf8)), .null), 0)
        XCTAssertThrowsError(try db.connection.query("SELECT ci_contains(?) LIMIT ?", [.text("x"), .int(1)]) { _ in })
    }

    func testSearchMatchesNFCAndNFDBodies() throws {
        let nfc = Manifest.first("nfc_text")
        let nfd = Manifest.first("nfd_text")
        for needle in ["caf\u{E9}", "cafe\u{301}", "CAF\u{E9}"] {
            let found = try hits(needle, sinceNs: 0, limit: 200)
            XCTAssertTrue(found.contains(nfc), needle)
            XCTAssertTrue(found.contains(nfd), needle)
        }
    }

    // MARK: Item 14, changes

    private func cursor(_ rowid: Int64, _ time: Int64) -> String { ChangeCursor(rowid: rowid, timeNs: time).text }

    func testNoSinceReturnsTheCurrentCursorOnly() throws {
        let page = try reader.changes(ChangesArgs())
        XCTAssertEqual(page.cursor, "41558:\(Fixture.nowNs)")
        XCTAssertTrue(page.changes.isEmpty)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(ChangeCursor(text: page.cursor), ChangeCursor(rowid: 41558, timeNs: Fixture.nowNs))
    }

    func testNewRowsAboveTheCursorInRowIDOrder() throws {
        let page = try reader.changes(ChangesArgs(since: cursor(41550, Fixture.nowNs)))
        XCTAssertEqual(page.changes.map(\.message.rowid), Array(41551...41558))
        XCTAssertTrue(page.changes.allSatisfy { $0.kind == .new })
        XCTAssertEqual(page.changes.first?.chat.label, "Family 🏡")
        XCTAssertEqual(page.cursor, "41558:\(Fixture.nowNs)")
        XCTAssertFalse(page.truncated)
        XCTAssertTrue(try reader.changes(ChangesArgs(since: page.cursor)).changes.isEmpty)
    }

    func testTapbackRowsAreNotChanges() throws {
        let page = try reader.changes(ChangesArgs(since: cursor(41547, Fixture.nowNs)))
        XCTAssertFalse(page.changes.contains { $0.message.rowid == 41548 })
        XCTAssertEqual(page.changes.first?.message.rowid, 41549)
    }

    func testEditReadDeliveredAndUnsendInsideTheWindow() throws {
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        try copy.exec("""
            UPDATE message SET date_delivered = \(now - 30 * second) WHERE ROWID = 41558;
            UPDATE message SET date_read = \(now - 20 * second) WHERE ROWID = 41541;
            UPDATE message SET date_edited = \(now - 10 * second) WHERE ROWID = 41427;
            UPDATE message SET date_edited = \(now - 5 * second) WHERE ROWID = 41483;
            UPDATE message SET date_read = \(now + 5 * second) WHERE ROWID = 41537;
            UPDATE message SET date_read = \(now - 60 * second) WHERE ROWID = 41536;
            """)
        let page = try ReadService(db: try copy.database()).changes(ChangesArgs(since: cursor(41558, now - 60 * second)))
        XCTAssertEqual(page.changes.map(\.message.rowid), [41558, 41541, 41427, 41483])
        XCTAssertEqual(page.changes.map(\.kind), [.delivered, .read, .edited, .unsent])
        XCTAssertEqual(page.changes.map(\.eventNs), [now - 30 * second, now - 20 * second, now - 10 * second,
                                                     now - 5 * second])
        XCTAssertEqual(page.cursor, "41558:\(now)")
        XCTAssertFalse(page.truncated)
    }

    /// Row 40908 is an unsend with only date_retracted set, the shape older macOS versions write.
    func testRetractOnlyUnsendCarriesItsRetractTime() throws {
        let retracted: Int64 = 803_541_775_426_938_000
        let page = try reader.changes(ChangesArgs(since: cursor(41558, retracted - second)))
        let unsend = try XCTUnwrap(page.changes.first { $0.message.rowid == 40908 })
        XCTAssertEqual(unsend.kind, .unsent)
        XCTAssertEqual(unsend.message.dateEditedNs, 0)
        XCTAssertEqual(unsend.eventNs, retracted)
    }

    /// DESIGN 5 defines `changes` by update time with no age limit: a message over a year old that is read or
    /// edited inside the window is reported.
    func testChangesReportUpdatesToMessagesOfAnyAge() throws {
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        try copy.exec("""
            UPDATE message SET date_read = \(now - 10 * second) WHERE ROWID = 40003;
            UPDATE message SET date_edited = \(now - 10 * second) WHERE ROWID IN (40913, 41427);
            """)
        let since = now - 60 * second
        let page = try ReadService(db: try copy.database()).changes(ChangesArgs(since: cursor(41558, since)))
        XCTAssertEqual(page.changes.map(\.message.rowid), [40003, 40913, 41427])
        XCTAssertEqual(page.changes.map(\.kind), [.read, .edited, .edited])
        XCTAssertFalse(page.truncated)
        XCTAssertLessThan(try reader.message(MessageArgs(rowid: 40003)).message.dateNs, since - 365 * day)
        XCTAssertLessThan(try reader.message(MessageArgs(rowid: 40913)).message.dateNs, since - 90 * day)
    }

    func testChangedTapbacksAreSkipped() throws {
        let copy = try FixtureCopy()
        try copy.exec("UPDATE message SET date_read = \(Fixture.nowNs - 10 * second) WHERE ROWID = 41548")
        let page = try ReadService(db: try copy.database()).changes(ChangesArgs(since: cursor(41558, Fixture.nowNs - 60 * second)))
        XCTAssertTrue(page.changes.isEmpty)
    }

    func testNewRowsAreCappedAt200AndTheCursorResumes() throws {
        let expected = try fixtureRowIDs("SELECT DISTINCT m.ROWID FROM message m JOIN chat_message_join j "
                                         + "ON j.message_id = m.ROWID WHERE m.ROWID > 41000 AND "
                                         + "ifnull(m.associated_message_type, 0) NOT BETWEEN 1000 AND 3999 "
                                         + "ORDER BY m.ROWID LIMIT ?")
        let shown = Set(try reader.allVisible("7").map(\.rowid) + reader.allVisible("2").map(\.rowid)
            + reader.allVisible("9").map(\.rowid) + reader.allVisible("12").map(\.rowid)
            + reader.allVisible("19").map(\.rowid) + reader.allVisible("23").map(\.rowid)
            + reader.allVisible("31").map(\.rowid) + reader.allVisible("56").map(\.rowid))
        let visible = expected.filter(shown.contains)
        XCTAssertGreaterThan(visible.count, 400)
        var seen: [Int64] = []
        var next = cursor(41000, Fixture.nowNs)
        var pages: [ChangesPage] = []
        repeat {
            let page = try reader.changes(ChangesArgs(since: next))
            pages.append(page)
            seen += page.changes.map(\.message.rowid)
            next = page.cursor
        } while pages.last!.truncated && pages.count < 10
        XCTAssertEqual(pages.first?.changes.count, 200)
        XCTAssertTrue(pages.first!.truncated)
        XCTAssertEqual(pages.first?.cursor, "\(pages.first!.changes.last!.message.rowid):\(Fixture.nowNs)")
        XCTAssertFalse(pages.last!.truncated)
        XCTAssertEqual(seen, visible)
    }

    func testChangedRowsAreCappedAt200WithTiesKept() throws {
        let copy = try FixtureCopy()
        let base = Fixture.nowNs - 1_000 * second
        try copy.exec("""
            UPDATE message SET date_read = \(base) + (ROWID - 41000) * \(second)
            WHERE ROWID BETWEEN 41001 AND 41300 AND ifnull(associated_message_type, 0) = 0;
            """)
        let r = ReadService(db: try copy.database())
        let since = cursor(41558, base)
        let first = try r.changes(ChangesArgs(since: since))
        XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.changes.count, 200)
        let lastTime = first.changes.last!.message.dateReadNs
        XCTAssertEqual(first.cursor, "41558:\(lastTime)")
        let rest = try r.changes(ChangesArgs(since: first.cursor))
        XCTAssertFalse(rest.truncated)
        let all = first.changes.map(\.message.rowid) + rest.changes.map(\.message.rowid)
        XCTAssertEqual(all.count, Set(all).count)
        XCTAssertTrue(all.allSatisfy { (41001...41300).contains($0) })
        XCTAssertEqual(rest.cursor, "41558:\(Fixture.nowNs)")

        let ties = try FixtureCopy()
        try ties.exec("""
            UPDATE message SET date_read = \(base + second)
            WHERE ROWID BETWEEN 41001 AND 41300 AND ifnull(associated_message_type, 0) = 0;
            """)
        let tied = try ReadService(db: try ties.database()).changes(ChangesArgs(since: since))
        XCTAssertTrue(tied.truncated)
        XCTAssertGreaterThan(tied.changes.count, 200)
        XCTAssertEqual(tied.cursor, "41558:\(base + second)")
    }

    /// Messages writes a message row before its chat_message_join row. A recent unjoined row holds the cursor
    /// below it, and the rows above it are reported once, after the join row lands.
    func testRecentUnjoinedRowHoldsTheCursor() throws {
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        try insertUnjoined(copy, rowid: 41600, date: now - 2 * second)
        try copy.insertMessage(rowid: 41601, guid: "ON-TIME", chat: 7, handle: 3, text: "on time", fromMe: false,
                               date: now - second)
        let first = try ReadService(db: try copy.database()).changes(ChangesArgs(since: cursor(41558, now)))
        XCTAssertTrue(first.changes.isEmpty)
        XCTAssertEqual(first.cursor, "41599:\(now)")
        XCTAssertFalse(first.truncated)
        try copy.exec("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (7, 41600, \(now - 2 * second))")
        let joined = ReadService(db: try copy.database())
        let later = try joined.changes(ChangesArgs(since: first.cursor))
        XCTAssertEqual(later.changes.map(\.message.rowid), [41600, 41601])
        XCTAssertEqual(later.changes.map(\.kind), [.new, .new])
        XCTAssertEqual(later.cursor, "41601:\(now)")
        XCTAssertTrue(try joined.changes(ChangesArgs(since: later.cursor)).changes.isEmpty)
    }

    /// An unjoined row older than the join lag (a Recently Deleted row) never holds the cursor.
    func testOldUnjoinedRowDoesNotHoldTheCursor() throws {
        XCTAssertEqual(ReadService.changesJoinLagNs, 10 * second)
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        try insertUnjoined(copy, rowid: 41600, date: now - 11 * second)
        try copy.insertMessage(rowid: 41601, guid: "ON-TIME", chat: 7, handle: 3, text: "on time", fromMe: false,
                               date: now - second)
        let page = try ReadService(db: try copy.database()).changes(ChangesArgs(since: cursor(41558, now)))
        XCTAssertEqual(page.changes.map(\.message.rowid), [41601])
        XCTAssertEqual(page.cursor, "41601:\(now)")
    }

    private func insertUnjoined(_ copy: FixtureCopy, rowid: Int64, date: Int64) throws {
        try copy.exec("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, item_type)
            VALUES (\(rowid), 'UNJOINED-\(rowid)', 'joined late', 3, 'iMessage', \(date), 0, 1, 0);
            """)
    }

    func testBadChangesCursorThrows() {
        for text in ["", "abc", "1:", ":1", "1:2:", "1:2:x", "1:2:3:4"] {
            XCTAssertThrowsError(try reader.changes(ChangesArgs(since: text)), text)
        }
    }

    // MARK: Item 15, wait and changes skip the bridge's sends and their echoes

    private func agentCopy(fillers: Int) throws -> FixtureCopy {
        let copy = try FixtureCopy()
        var t = Fixture.nowNs - 3_600 * second
        try copy.insertMessage(rowid: 41600, guid: "AGENT-1", chat: 2, handle: 1, text: "agent hello", fromMe: true, date: t)
        for i in 0..<fillers {
            t += second
            try copy.insertMessage(rowid: 41601 + Int64(i), guid: "FILL-\(i)", chat: 2, handle: 1, text: "note \(i)",
                                   fromMe: true, date: t)
        }
        t += second
        try copy.insertMessage(rowid: 41700, guid: "ECHO-1", chat: 2, handle: 1, text: "agent hello", fromMe: false, date: t)
        return copy
    }

    func testWaitAndChangesSkipAgentRowsAndTheirEchoes() throws {
        let copy = try agentCopy(fillers: 1)
        let db = try copy.database()
        let r = ReadService(db: db)
        XCTAssertEqual(try r.nextInbound(afterRowID: 41558, in: nil)?.1.rowid, 41700)
        XCTAssertEqual(try r.changes(ChangesArgs(since: cursor(41558, Fixture.nowNs))).changes.map(\.message.rowid),
                       [41600, 41601, 41700])
        db.addAgentSentGUIDs(["AGENT-1"])
        XCTAssertNil(try r.nextInbound(afterRowID: 41558, in: nil))
        XCTAssertEqual(try r.changes(ChangesArgs(since: cursor(41558, Fixture.nowNs))).changes.map(\.message.rowid),
                       [41601])
        let message = try r.message(MessageArgs(rowid: 41600)).message
        XCTAssertTrue(message.agentSent)
    }

    /// DESIGN 3.5: a send that returned `submitted` learns of its delivery through `changes`. The echo's own
    /// read time never shows.
    func testChangesReportLaterDeliveriesOfAgentSends() throws {
        let copy = try agentCopy(fillers: 1)
        let now = Fixture.nowNs
        try copy.exec("""
            UPDATE message SET date_delivered = \(now - 20 * second) WHERE ROWID = 41600;
            UPDATE message SET date_read = \(now - 10 * second) WHERE ROWID = 41700;
            """)
        let db = try copy.database()
        db.addAgentSentGUIDs(["AGENT-1"])
        let page = try ReadService(db: db).changes(ChangesArgs(since: cursor(41700, now - 60 * second)))
        XCTAssertEqual(page.changes.map(\.message.rowid), [41600])
        XCTAssertEqual(page.changes.map(\.kind), [.delivered])
        XCTAssertTrue(page.changes[0].message.agentSent)
    }

    /// A bridge send made after the cursor is never new, but its delivery is a change, reported once.
    func testChangesReportDeliveriesOfAgentSendsAboveTheCursor() throws {
        let copy = try agentCopy(fillers: 0)
        let now = Fixture.nowNs
        try copy.exec("UPDATE message SET is_delivered = 1, date_delivered = \(now - 20 * second) WHERE ROWID = 41600")
        let db = try copy.database()
        db.addAgentSentGUIDs(["AGENT-1"])
        let r = ReadService(db: db)
        let page = try r.changes(ChangesArgs(since: cursor(41558, now - 60 * second)))
        XCTAssertEqual(page.changes.map(\.message.rowid), [41600])
        XCTAssertEqual(page.changes.map(\.kind), [.delivered])
        XCTAssertEqual(page.changes.first?.message.agentSent, true)
        XCTAssertEqual(page.changes.first?.eventNs, now - 20 * second, "a bridge send above the cursor has its time too")
        XCTAssertEqual(page.cursor, "41700:\(now)")
        XCTAssertTrue(try r.changes(ChangesArgs(since: page.cursor)).changes.isEmpty)
        XCTAssertTrue(try r.changes(ChangesArgs(since: cursor(41558, now - 10 * second))).changes.isEmpty)
    }

    /// A bridge send above a held cursor is reported on the call that sees its delivery, and only then.
    func testAgentDeliveryAboveAHeldCursorIsReportedOnce() throws {
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        try insertUnjoined(copy, rowid: 41600, date: now - 2 * second)
        try copy.insertMessage(rowid: 41601, guid: "AGENT-9", chat: 7, handle: 3, text: "on my way", fromMe: true,
                               date: now - 5 * second)
        try copy.exec("UPDATE message SET is_delivered = 1, date_delivered = \(now - second) WHERE ROWID = 41601")
        let db = try copy.database()
        db.addAgentSentGUIDs(["AGENT-9"])
        let first = try ReadService(db: db).changes(ChangesArgs(since: cursor(41558, now - 60 * second)))
        XCTAssertEqual(first.changes.map(\.message.rowid), [41601])
        XCTAssertEqual(first.changes.map(\.kind), [.delivered])
        XCTAssertEqual(first.cursor, "41599:\(now)")
        try copy.exec("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (7, 41600, \(now - 2 * second))")
        let joined = try copy.database()
        joined.addAgentSentGUIDs(["AGENT-9"])
        let later = try ReadService(db: joined).changes(ChangesArgs(since: first.cursor))
        XCTAssertEqual(later.changes.map(\.message.rowid), [41600])
        XCTAssertEqual(later.changes.map(\.kind), [.new])
        XCTAssertEqual(later.cursor, "41601:\(now)")
    }

    /// Follows `changes` cursors from `start` until a page isn't truncated, at most 10 pages.
    private func allChanges(_ r: ReadService, from start: String) throws -> (seen: [(ChangeKind, Int64)], pages: Int) {
        var seen: [(ChangeKind, Int64)] = []
        var next = start
        var pages = 0
        while pages < 10 {
            let page = try r.changes(ChangesArgs(since: next))
            seen += page.changes.map { ($0.kind, $0.message.rowid) }
            next = page.cursor
            pages += 1
            if !page.truncated { break }
        }
        return (seen, pages)
    }

    /// A bridge send above the new rows that fill a page: its delivery is still reported, once.
    func testNewRowsFillingThePageKeepAnAgentDeliveryAboveThem() throws {
        let copy = try FixtureCopy()
        let now = Fixture.nowNs
        var t = now - 3_000 * second
        for i in 0..<250 {
            t += second
            try copy.insertMessage(rowid: 41600 + Int64(i), guid: "IN-\(i)", chat: 7, handle: 3, text: "in \(i)",
                                   fromMe: false, date: t)
        }
        try copy.insertMessage(rowid: 41900, guid: "AGENT-D", chat: 7, handle: 3, text: "agent note", fromMe: true,
                               date: t + second)
        try copy.exec("UPDATE message SET is_delivered = 1, date_delivered = \(now - 10 * second) WHERE ROWID = 41900")
        let db = try copy.database()
        db.addAgentSentGUIDs(["AGENT-D"])
        let (seen, pages) = try allChanges(ReadService(db: db), from: cursor(41558, now - 60 * second))
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(seen.filter { $0.1 == 41900 }.map(\.0), [.delivered])
        XCTAssertEqual(seen.filter { $0.0 == .new }.map(\.1), (0..<250).map { 41600 + Int64($0) })
    }

    /// A bridge send above the cursor whose delivery is older than the last of 200 changed rows: still reported,
    /// once.
    func testChangedRowsFillingThePageKeepAnAgentDeliveryAboveTheCursor() throws {
        let copy = try FixtureCopy()
        let base = Fixture.nowNs - 1_000 * second
        try copy.exec("""
            UPDATE message SET date_read = \(base) + (ROWID - 41000) * \(second)
            WHERE ROWID BETWEEN 41001 AND 41300 AND ifnull(associated_message_type, 0) = 0;
            """)
        try copy.insertMessage(rowid: 41600, guid: "AGENT-E", chat: 7, handle: 3, text: "agent note", fromMe: true,
                               date: base)
        try copy.exec("UPDATE message SET is_delivered = 1, date_delivered = \(base + 5 * second) WHERE ROWID = 41600")
        let db = try copy.database()
        db.addAgentSentGUIDs(["AGENT-E"])
        let (seen, pages) = try allChanges(ReadService(db: db), from: cursor(41558, base))
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(seen.filter { $0.1 == 41600 }.map(\.0), [.delivered])
        XCTAssertEqual(seen.count, Set(seen.map(\.1)).count)
    }

    /// A changes query that fills the row cap may have stopped inside its last time: the page ends before that
    /// time and the cursor brings it back, so no change past the cap is lost.
    func testChangesQueryThatFillsTheRowCapResumesAtItsLastTime() throws {
        let copy = try FixtureCopy()
        let base = Fixture.nowNs - 1_000 * second
        try copy.exec("""
            UPDATE message SET date_read = \(base) + ((ROWID - 41000) / 2) * \(second)
            WHERE ROWID BETWEEN 41001 AND 41300 AND ifnull(associated_message_type, 0) = 0;
            """)
        let expected = try fixtureRowIDs("SELECT DISTINCT m.ROWID FROM message m JOIN chat_message_join j "
                                         + "ON j.message_id = m.ROWID WHERE m.ROWID BETWEEN 41001 AND 41300 AND "
                                         + "ifnull(m.associated_message_type, 0) = 0 ORDER BY m.ROWID LIMIT ?")
        let r = ReadService(db: try copy.database(rowCap: 25))
        var seen: [Int64] = []
        var next = cursor(41558, base)
        for _ in 0..<100 {
            let page = try r.changes(ChangesArgs(since: next))
            XCTAssertLessThanOrEqual(page.changes.count, 25)
            seen += page.changes.map(\.message.rowid)
            next = page.cursor
            if !page.truncated { break }
        }
        let visible = Set(try allChanges(ReadService(db: try copy.database()), from: cursor(41558, base)).seen.map(\.1))
        XCTAssertGreaterThan(visible.count, 100)
        XCTAssertTrue(visible.isSubset(of: Set(expected)))
        XCTAssertEqual(Set(seen), visible)
    }

    /// Sets one date_read on every plain row from 41001 to 41300, as a bulk mark-read can.
    private func oneReadTime(_ time: Int64) throws -> FixtureCopy {
        let copy = try FixtureCopy()
        try copy.exec("""
            UPDATE message SET date_read = \(time)
            WHERE ROWID BETWEEN 41001 AND 41300 AND ifnull(associated_message_type, 0) = 0;
            """)
        return copy
    }

    /// More rows share one event time than a rendered page shows. Each text and NDJSON footer resumes inside that
    /// time, so following the footers shows every row and never gives the same cursor twice.
    func testRenderedFootersPageThroughOneTimeLargerThanAPage() throws {
        let base = Fixture.nowNs - 1_000 * second
        let r = ReadService(db: try oneReadTime(base + second).database())
        let start = cursor(41558, base)
        let visible = Set(try r.changes(ChangesArgs(since: start)).changes.map(\.message.rowid))
        XCTAssertGreaterThan(visible.count, 200)

        // Each render returns how many changes it showed and the cursor its footer gives, nil once it says `cursor`.
        let text: (ChangesPage) -> (Int, String?) = { page in
            let lines = Format.changes(page, Golden.context).split(separator: "\n").map(String.init)
            let shown = Int(lines[0].split(separator: " ")[2]) ?? -1
            let more = "more: imessage changes --since "
            return (shown, lines.last!.hasPrefix(more) ? String(lines.last!.dropFirst(more.count)) : nil)
        }
        let ndjson: (ChangesPage) -> (Int, String?) = { page in
            let records = Format.ndjson(.changes(page)).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let shown = records.filter { $0["type"] as? String == "change" }.count
            let more = records.contains { $0["type"] as? String == "more" }
            return (shown, more ? records.first?["cursor"] as? String : nil)
        }
        for (name, render) in [("text", text), ("ndjson", ndjson)] {
            var seen = Set<Int64>()
            var cursors = [start]
            while cursors.count < 20 {
                let page = try r.changes(ChangesArgs(since: cursors.last!))
                let (shown, next) = render(page)
                XCTAssertGreaterThan(shown, 0, name)
                seen.formUnion(page.changes.prefix(shown).map(\.message.rowid))
                guard let next else { break }
                guard !cursors.contains(next) else { XCTFail("\(name) footer repeats \(next)"); break }
                cursors.append(next)
            }
            XCTAssertLessThan(cursors.count, 20, name)
            XCTAssertGreaterThan(cursors.count, 1, "\(name): the time takes more than one page")
            XCTAssertEqual(seen.count, visible.count, name)
            XCTAssertTrue(seen == visible, name)
        }
    }

    /// More rows share one event time than the changes query's row cap holds: the cursor resumes inside that time
    /// from the last ROWID fetched, so the rows past the cap come on the next call. With a cap of 250 the page
    /// also passes 200 changes.
    func testOneTimeLargerThanTheRowCapResumesInsideThatTime() throws {
        let base = Fixture.nowNs - 1_000 * second
        let copy = try oneReadTime(base + second)
        let visible = Set(try allChanges(ReadService(db: try copy.database()), from: cursor(41558, base)).seen.map(\.1))
        XCTAssertGreaterThan(visible.count, 250)
        for rowCap in [25, 250] {
            let r = ReadService(db: try copy.database(rowCap: rowCap))
            var seen: [Int64] = []
            var next = cursor(41558, base)
            for _ in 0..<100 {
                let page = try r.changes(ChangesArgs(since: next))
                XCTAssertLessThanOrEqual(page.changes.count, rowCap)
                seen += page.changes.map(\.message.rowid)
                XCTAssertNotEqual(page.cursor, next, "the cursor moves")
                next = page.cursor
                if !page.truncated { break }
            }
            XCTAssertEqual(seen.count, Set(seen).count, "no row comes twice, cap \(rowCap)")
            XCTAssertEqual(Set(seen).count, visible.count, "cap \(rowCap)")
            XCTAssertTrue(Set(seen) == visible, "cap \(rowCap)")
        }
    }

    func testEchoMatchLooksBackTwentyOutgoingRows() throws {
        for (fillers, skipped) in [(19, true), (20, false)] {
            let db = try agentCopy(fillers: fillers).database()
            db.agentSentGUIDs = ["AGENT-1"]
            let next = try ReadService(db: db).nextInbound(afterRowID: 41558, in: nil)
            XCTAssertEqual(next == nil, skipped, "fillers \(fillers)")
        }
    }

    func testRepliesInOtherChatsStillCount() throws {
        let copy = try FixtureCopy()
        let t = Fixture.nowNs - 60 * second
        try copy.insertMessage(rowid: 41600, guid: "AGENT-2", chat: 7, handle: 3, text: "ok", fromMe: true, date: t)
        try copy.insertMessage(rowid: 41601, guid: "MOM-OK", chat: 7, handle: 3, text: "ok", fromMe: false, date: t + second)
        let db = try copy.database()
        db.agentSentGUIDs = ["AGENT-2"]
        let r = ReadService(db: db)
        XCTAssertEqual(try r.nextInbound(afterRowID: 41558, in: nil)?.1.rowid, 41601)
        XCTAssertEqual(try r.changes(ChangesArgs(since: cursor(41558, Fixture.nowNs))).changes.map(\.message.rowid), [41601])
    }

    func testNextInboundPicksTheFirstIncomingVisibleRow() throws {
        let next = try XCTUnwrap(try reader.nextInbound(afterRowID: 41556, in: nil))
        XCTAssertEqual(next.1.rowid, 41557)
        XCTAssertEqual(next.0.rowid, 19)
        XCTAssertNil(try reader.nextInbound(afterRowID: 41557, in: nil))
        let db = try TestStore.database()
        let mom = try db.resolve("Mom")
        XCTAssertEqual(try ReadService(db: db).nextInbound(afterRowID: 41547, in: mom)?.1.rowid, 41555)
        XCTAssertEqual(try reader.nextInbound(afterRowID: 41547, in: nil)?.1.rowid, 41549)
        XCTAssertEqual(try reader.maxMessageRowID(), 41558)
    }

    func testAgentSentGUIDsAreThreadSafe() throws {
        let db = try TestStore.database()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            db.addAgentSentGUIDs(["G\(i)"])
            _ = db.agentSentGUIDs.count
        }
        XCTAssertEqual(db.agentSentGUIDs.count, 200)
        db.agentSentGUIDs = []
        XCTAssertTrue(db.agentSentGUIDs.isEmpty)
    }
}
