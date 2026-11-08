import XCTest
@testable import IMBridge
import IMCore
import IMStore

/// A chat.db timeout's fix names only flags the verb takes.
final class WireErrorsTests: XCTestCase {
    private func timeout(_ op: Op) -> WireError { WireErrors.map(StoreError.timeout, op: op) }

    func testASearchTimeoutSuggestsNarrowingTheSearch() {
        XCTAssertEqual(timeout(.search).result.code, .error(.message("chat.db read timed out")))
        XCTAssertEqual(timeout(.search).result.fix, "retry, or narrow the search with --in or --since")
    }

    func testAnUnreadTimeoutSuggestsReadingOneChat() {
        XCTAssertEqual(timeout(.unread).result.code, .error(.message("chat.db read timed out")))
        XCTAssertEqual(timeout(.unread).result.fix, "retry, or read one chat with imessage read <chat>")
    }

    /// An old cursor that times out on every retry would leave the agent stuck, so the fix also offers a new one.
    func testAChangesTimeoutOffersAFreshCursor() {
        XCTAssertEqual(timeout(.changes).result.code, .error(.message("chat.db read timed out")))
        XCTAssertEqual(timeout(.changes).result.fix, "retry, or run imessage changes with no --since for a fresh cursor")
    }

    func testEveryOtherTimeoutSaysRetry() {
        for op in Op.allCases where op != .search && op != .unread && op != .changes {
            XCTAssertEqual(timeout(op).result.code, .error(.message("chat.db read timed out")), "\(op)")
            XCTAssertEqual(timeout(op).result.fix, "retry", "\(op)")
        }
    }

    /// `--since` belongs to search and changes, `--in` to search alone.
    func testOnlySearchAndChangesMentionFlags() {
        for op in Op.allCases where op != .search {
            XCTAssertFalse(timeout(op).result.fix?.contains("--in") ?? false, "\(op)")
            if op != .changes { XCTAssertFalse(timeout(op).result.fix?.contains("--") ?? false, "\(op)") }
        }
    }
}
