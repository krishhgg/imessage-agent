import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 2, Everything else: single use, 10-minute expiry, the binding, the 1 s button delay and the 120 s wait.
final class ApprovalBookTests: XCTestCase {
    private var clock: FakeClock!
    private var presenter: FakePresenter!
    private var book: ApprovalBook!
    private var t0: Date!

    override func setUp() {
        clock = FakeClock()
        presenter = FakePresenter()
        book = ApprovalBook(clock: clock, presenter: presenter)
        t0 = clock.now
    }

    /// Every binding field set, so each one can be changed in turn.
    private let full = ApprovalBinding(chat: T.mom, action: .send, textDigest: TextNorm.textDigest("On my way"),
                                       attachmentDigest: "attach-digest", targetGUID: "TARGET-GUID", targetPart: 0,
                                       parentGUID: "PARENT-GUID", tapback: .heart, remove: false, scope: .text)

    /// Opens an approval and presses `decision` once the allow buttons are enabled.
    private func decided(_ binding: ApprovalBinding, _ decision: ApprovalDecision = .allowOnce,
                         offersAlwaysAllow: Bool = true) -> String {
        let id = book.open(T.prompt(binding, offersAlwaysAllow: offersAlwaysAllow))
        clock.advance(Limits.approvalButtonDelay)
        presenter.answer(id, decision)
        return id
    }

    // MARK: Presenting

    func testOpenPresentsThePromptWithItsID() {
        let id = book.open(T.prompt(full, id: "abc12345"))
        XCTAssertEqual(id, "abc12345")
        XCTAssertEqual(presenter.prompts.map(\.id), ["abc12345"])
        XCTAssertEqual(presenter.prompts.first?.binding, full)
        XCTAssertEqual(book.status(id: id), .pending)
    }

    func testOpenPicksAFreshIDWhenEmptyOrTaken() {
        let first = book.open(T.prompt(full, id: "abc12345"))
        let second = book.open(T.prompt(full, id: "abc12345"))
        let third = book.open(T.prompt(full, id: ""))
        XCTAssertEqual(Set([first, second, third]).count, 3)
        for id in [second, third] {
            XCTAssertEqual(id.count, 8)
            XCTAssertTrue(id.allSatisfy(\.isHexDigit), id)
        }
    }

    // MARK: Single use and binding

    func testAllowIsConsumedExactlyOnce() {
        let id = decided(full)
        XCTAssertEqual(book.status(id: id), .decided(.allowOnce))
        XCTAssertTrue(book.consume(id: id, binding: full))
        XCTAssertFalse(book.consume(id: id, binding: full))
        XCTAssertEqual(book.status(id: id), .consumed)
    }

    func testConsumeFailsWhenAnyBoundFieldDiffers() {
        var variants: [(String, ApprovalBinding)] = []
        func variant(_ name: String, _ change: (inout ApprovalBinding) -> Void) {
            var b = full
            change(&b)
            variants.append((name, b))
        }
        variant("chat") { $0.chat = T.dad }
        variant("no chat") { $0.chat = nil }
        variant("action") { $0.action = .threadedReply }
        variant("text") { $0.textDigest = TextNorm.textDigest("On my way!") }
        variant("no text") { $0.textDigest = nil }
        variant("attachment") { $0.attachmentDigest = "other-digest" }
        variant("target guid") { $0.targetGUID = "OTHER-GUID" }
        variant("target part") { $0.targetPart = 1 }
        variant("parent guid") { $0.parentGUID = "OTHER-PARENT" }
        variant("tapback") { $0.tapback = .like }
        variant("remove") { $0.remove = true }
        variant("scope") { $0.scope = .files }

        let id = decided(full)
        for (name, binding) in variants {
            XCTAssertNotEqual(binding, full, name)
            XCTAssertFalse(book.consume(id: id, binding: binding), "consumed with a different \(name)")
        }
        // The failed attempts didn't use it up.
        XCTAssertTrue(book.consume(id: id, binding: full))
    }

    func testTextBindingUsesTextNormDigest() {
        let nfc = T.sendBinding(T.mom, text: "Caf\u{E9} at 6")
        let id = decided(nfc)
        let nfdTrimmed = T.sendBinding(T.mom, text: "  Cafe\u{301} at 6\n")
        XCTAssertEqual(nfdTrimmed, nfc)
        XCTAssertTrue(book.consume(id: id, binding: nfdTrimmed))

        let other = decided(nfc)
        XCTAssertFalse(book.consume(id: other, binding: T.sendBinding(T.mom, text: "Cafe at 6")))
        XCTAssertFalse(book.consume(id: other, binding: T.sendBinding(T.mom, text: "caf\u{E9} at 6")))
    }

    func testDenyCanNeverBeConsumed() {
        let id = decided(full, .deny)
        XCTAssertEqual(book.status(id: id), .decided(.deny))
        XCTAssertFalse(book.consume(id: id, binding: full))
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        XCTAssertEqual(book.status(id: id), .decided(.deny))
    }

    func testUnknownIDIsUnknownAndCantBeConsumed() {
        XCTAssertEqual(book.status(id: "nope"), .unknown)
        XCTAssertFalse(book.consume(id: "nope", binding: full))
    }

    func testPendingApprovalCantBeConsumed() {
        let id = book.open(T.prompt(full))
        XCTAssertFalse(book.consume(id: id, binding: full))
    }

    // MARK: Expiry

    func testAllowIsValidUntilJustBeforeTenMinutes() {
        let id = decided(full)
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry - 0.001)
        XCTAssertEqual(book.status(id: id), .decided(.allowOnce))
        XCTAssertTrue(book.consume(id: id, binding: full))
    }

    func testAllowExpiresAtExactlyTenMinutes() {
        let id = decided(full)
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        XCTAssertEqual(book.status(id: id), .expired)
        XCTAssertFalse(book.consume(id: id, binding: full))
    }

    func testUnansweredApprovalExpiresAndItsPanelIsWithdrawnOnce() {
        let id = book.open(T.prompt(full))
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry - 0.001)
        XCTAssertEqual(book.status(id: id), .pending)
        XCTAssertEqual(presenter.withdrawn, [])
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        XCTAssertEqual(book.status(id: id), .expired)
        XCTAssertEqual(book.status(id: id), .expired)
        XCTAssertEqual(presenter.withdrawn, [id])
    }

    func testDecisionAfterExpiryIsIgnored() {
        let id = book.open(T.prompt(full))
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        presenter.answer(id, .allowOnce)
        XCTAssertEqual(book.status(id: id), .expired)
        XCTAssertFalse(book.consume(id: id, binding: full))
    }

    func testExpireOldWithdrawsExpiredPanelsThenForgetsThem() {
        let open = book.open(T.prompt(full))
        let answered = decided(full)
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        book.expireOld()
        XCTAssertEqual(presenter.withdrawn, [open])
        XCTAssertEqual(book.status(id: open), .expired)
        XCTAssertEqual(book.status(id: answered), .expired)
        clock.now = t0.addingTimeInterval(2 * Limits.approvalExpiry)
        book.expireOld()
        XCTAssertEqual(book.status(id: open), .unknown)
        XCTAssertEqual(book.status(id: answered), .unknown)
        XCTAssertEqual(presenter.withdrawn, [open])
    }

    // MARK: Decisions the presenter reports

    func testAllowSoonerThanOneSecondCountsAsDeny() {
        let early = book.open(T.prompt(full))
        clock.advance(Limits.approvalButtonDelay - 0.001)
        presenter.answer(early, .allowOnce)
        XCTAssertEqual(book.status(id: early), .decided(.deny))
        XCTAssertFalse(book.consume(id: early, binding: full))

        let onTime = book.open(T.prompt(full))
        clock.advance(Limits.approvalButtonDelay)
        presenter.answer(onTime, .alwaysAllow)
        XCTAssertEqual(book.status(id: onTime), .decided(.alwaysAllow))
    }

    func testAllowArrivingWhileThePanelOpensCountsAsDeny() {
        // A Return or a click queued before the panel showed lands at once.
        presenter.immediate = .allowOnce
        let id = book.open(T.prompt(full))
        XCTAssertEqual(book.status(id: id), .decided(.deny))
    }

    func testDenyCountsAtOnce() {
        let id = book.open(T.prompt(full))
        presenter.answer(id, .deny)
        XCTAssertEqual(book.status(id: id), .decided(.deny))
    }

    func testAlwaysAllowOnAPromptWithoutItIsAllowOnce() {
        let id = decided(full, .alwaysAllow, offersAlwaysAllow: false)
        XCTAssertEqual(book.status(id: id), .decided(.allowOnce))
        let offered = decided(full, .alwaysAllow, offersAlwaysAllow: true)
        XCTAssertEqual(book.status(id: offered), .decided(.alwaysAllow))
    }

    func testOnlyTheFirstDecisionCounts() {
        let denied = decided(full, .deny)
        presenter.answer(denied, .allowOnce)
        XCTAssertEqual(book.status(id: denied), .decided(.deny))

        let allowed = decided(full, .allowOnce)
        presenter.answer(allowed, .deny)
        XCTAssertEqual(book.status(id: allowed), .decided(.allowOnce))
    }

    // MARK: The CLI's 120 s wait and pending <id>

    func testWaitReturnsPendingAfterExactly120Seconds() {
        let id = book.open(T.prompt(full))
        let start = clock.uptime
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .pending)
        XCTAssertEqual(clock.uptime - start, Limits.approvalWait, accuracy: 1e-6)
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 > 0 && $0 <= ApprovalBook.pollInterval + 1e-12 })
    }

    func testWaitReturnsTheDecisionWhenItArrives() {
        let scripted = ScriptedClock()
        let book = ApprovalBook(clock: scripted, presenter: presenter)
        let id = book.open(T.prompt(full))
        scripted.after(30) { self.presenter.answer(id, .allowOnce) }
        let start = scripted.uptime
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .decided(.allowOnce))
        XCTAssertEqual(scripted.uptime - start, 30, accuracy: ApprovalBook.pollInterval + 1e-6)
    }

    func testWaitReturnsAtOnceForADecidedApproval() {
        let id = decided(full, .deny)
        let sleeps = clock.sleeps.count
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .decided(.deny))
        XCTAssertEqual(clock.sleeps.count, sleeps)
    }

    func testPendingIDCollectsTheDecisionAfterTheWait() {
        let id = book.open(T.prompt(full))
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .pending)
        clock.advance(180)
        presenter.answer(id, .allowOnce)
        XCTAssertEqual(book.status(id: id), .decided(.allowOnce))
        XCTAssertTrue(book.consume(id: id, binding: full))
    }

    func testApprovalUnansweredForTenMinutesIsExpiredForPendingID() {
        let id = book.open(T.prompt(full))
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .pending)
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        XCTAssertEqual(book.wait(id: id, seconds: Limits.approvalWait), .expired)
        // IMBridge reports it as `denied: approval expired`, which doesn't hold the key, so a retry asks again.
        XCTAssertEqual(ActionResult(.denied(.approvalExpired)).rendered, "denied: approval expired")
        XCTAssertFalse(ActionResult(.denied(.approvalExpired)).holdsIdempotencyKey)
        XCTAssertTrue(ActionResult(.denied(.user)).holdsIdempotencyKey)
    }

    func testWaitWakesWhenAnotherThreadDecides() {
        let book = ApprovalBook(clock: SystemClock(), presenter: presenter)
        let id = book.open(T.prompt(full))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self.presenter.answer(id, .deny) }
        let started = Date()
        XCTAssertEqual(book.wait(id: id, seconds: 10), .decided(.deny))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Listing

    func testPendingItemsListOpenApprovalsOldestFirst() {
        let first = book.open(T.prompt(full, text: "On my way"))
        clock.advance(5)
        let long = String(repeating: "a", count: Limits.quoteChars + 5)
        let second = book.open(T.prompt(full, text: long))
        _ = decided(full)

        let items = book.pendingItems()
        XCTAssertEqual(items.map(\.id), [first, second])
        XCTAssertEqual(items[0].summary, "send to Mom \"On my way\"")
        XCTAssertEqual(items[1].summary, "send to Mom \"\(String(repeating: "a", count: Limits.quoteChars))…\"")
        XCTAssertEqual(items[0].createdAt, t0)
        XCTAssertEqual(items[0].expiresAt, t0.addingTimeInterval(Limits.approvalExpiry))

        clock.now = t0.addingTimeInterval(Limits.approvalExpiry)
        XCTAssertEqual(book.pendingItems().map(\.id), [second])
    }

    func testSummaryNamesTheFileWhenThereIsNoText() {
        var prompt = T.prompt(full, text: nil)
        prompt.title = "Send a file to Mom"
        prompt.attachmentName = "photo.jpg"
        XCTAssertEqual(ApprovalBook.summary(prompt), "send a file to Mom photo.jpg")
    }

    func testHasOpenApprovalsOnlyWhileAPanelWaits() {
        XCTAssertFalse(book.hasOpenApprovals)
        let id = book.open(T.prompt(full))
        XCTAssertTrue(book.hasOpenApprovals)
        clock.advance(Limits.approvalButtonDelay)
        presenter.answer(id, .allowOnce)
        XCTAssertFalse(book.hasOpenApprovals)
        _ = book.open(T.prompt(full))
        clock.now = t0.addingTimeInterval(Limits.approvalExpiry + 1)
        XCTAssertFalse(book.hasOpenApprovals)
    }

    // MARK: Thread safety

    func testConcurrentConsumeSucceedsExactlyOnce() {
        let id = decided(full)
        let lock = NSLock()
        var wins = 0
        concurrently(64) { _ in
            if self.book.consume(id: id, binding: self.full) {
                lock.lock(); wins += 1; lock.unlock()
            }
        }
        XCTAssertEqual(wins, 1)
    }

    func testConcurrentOpensGetDistinctIDs() {
        let lock = NSLock()
        var ids: [String] = []
        let book = ApprovalBook(clock: SystemClock(), presenter: presenter)
        concurrently(64) { _ in
            let id = book.open(T.prompt(self.full, id: "same0000"))
            lock.lock(); ids.append(id); lock.unlock()
        }
        XCTAssertEqual(Set(ids).count, 64)
        XCTAssertEqual(book.pendingItems().count, 64)
    }

    func testConcurrentDecisionsKeepTheFirstOne() {
        let id = book.open(T.prompt(full))
        clock.advance(Limits.approvalButtonDelay)
        concurrently(32) { i in self.presenter.answer(id, i % 2 == 0 ? .allowOnce : .deny) }
        let status = book.status(id: id)
        XCTAssertTrue(status == .decided(.allowOnce) || status == .decided(.deny), "\(status)")
        presenter.answer(id, status == .decided(.deny) ? .allowOnce : .deny)
        XCTAssertEqual(book.status(id: id), status)
    }
}
