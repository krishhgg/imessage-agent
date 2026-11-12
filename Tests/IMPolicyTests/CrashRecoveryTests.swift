import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 3 item 2, after a crash: what each open state becomes, and the foreground flag.
final class CrashRecoveryTests: XCTestCase {
    private var dir: TempDir!
    private var clock: FakeClock!
    private var journal: Journal!
    private var reconciler: ScriptedReconciler!

    override func setUp() {
        dir = TempDir()
        clock = FakeClock()
        journal = try! Journal(directory: dir.url, clock: clock)
        reconciler = ScriptedReconciler()
    }

    override func tearDown() {
        journal = nil
        dir = nil
    }

    private func entry(at state: JournalState, text: String = "On my way", action: MutationKind = .send,
                       foreground: Bool = false) throws -> JournalEntry {
        let e = try journal.begin(key: T.sendKey(text: text), action: action, chat: T.mom,
                                  binding: T.sendBinding(T.mom, text: text))
        if foreground { try journal.markForeground(e.id, true) }
        if state >= .approved { try journal.advance(e.id, to: .approved, approvalID: "a\(e.id)") }
        if state >= .invoking { try journal.advance(e.id, to: .invoking, facts: InvocationFacts(snapshotRowID: 900)) }
        if state >= .invoked { try journal.advance(e.id, to: .invoked) }
        if state == .final {
            try journal.finish(e.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))
        }
        return try XCTUnwrap(journal.entry(e.id))
    }

    /// The journal as the restarted bridge opens it.
    private func restart() throws -> Journal { try Journal(directory: dir.url, clock: clock) }

    func testReceivedAndApprovedBecomeBridgeRestartedAndDontHoldTheKey() throws {
        let received = try entry(at: .received, text: "one")
        let approved = try entry(at: .approved, text: "two")
        let journal = try restart()
        XCTAssertFalse(try journal.recoverAfterCrash(using: reconciler))

        let failed = ActionResult(.failed(.bridgeRestarted))
        for (e, text) in [(received, "one"), (approved, "two")] {
            let recovered = try XCTUnwrap(journal.entry(e.id))
            XCTAssertEqual(recovered.state, .final)
            XCTAssertEqual(recovered.result, failed)
            XCTAssertEqual(recovered.response, .failure(WireError(result: failed)))
            XCTAssertEqual(journal.lookup(T.sendKey(text: text), again: false), .fresh)
        }
        XCTAssertEqual(failed.rendered, "failed: bridge restarted")
        XCTAssertTrue(reconciler.seen.isEmpty)
    }

    func testInvokingAndInvokedAreReconciledAndHoldTheKey() throws {
        let invoking = try entry(at: .invoking, text: "one")
        let invoked = try entry(at: .invoked, text: "two")
        reconciler.results[invoking.id] = ActionResult(.delivered)
        reconciler.results[invoked.id] = ActionResult(.submitted, notes: [.chatUnconfirmed])
        let journal = try restart()
        XCTAssertFalse(try journal.recoverAfterCrash(using: reconciler))

        XCTAssertEqual(journal.entry(invoking.id)?.result, ActionResult(.delivered))
        XCTAssertEqual(journal.entry(invoked.id)?.result, ActionResult(.submitted, notes: [.chatUnconfirmed]))
        for text in ["one", "two"] {
            guard case .replay(.failure(let error)) = journal.lookup(T.sendKey(text: text), again: false) else {
                XCTFail("\(text) should replay")
                continue
            }
            XCTAssertTrue(error.result.holdsIdempotencyKey)
        }
    }

    func testReconciledRowGUIDsAreKeptForAgentSentGUIDsAndTheRateLimits() throws {
        let sent = try entry(at: .invoking, text: "one")
        let lost = try entry(at: .invoked, text: "two")
        reconciler.results[sent.id] = ActionResult(.delivered)
        reconciler.guids[sent.id] = ["G-RECONCILED"]
        _ = try restart().recoverAfterCrash(using: reconciler)

        let journal = try restart()
        XCTAssertEqual(journal.entry(sent.id)?.sentGUIDs, ["G-RECONCILED"])
        XCTAssertNil(journal.entry(lost.id)?.sentGUIDs, "nothing matched, so no GUID")
        XCTAssertEqual(journal.agentSentGUIDs(), ["G-RECONCILED"])
        XCTAssertEqual(journal.sendEvent(for: sent.id)?.guid, "G-RECONCILED")
        XCTAssertNil(journal.sendEvent(for: lost.id)?.guid)
    }

    func testNothingFoundGivesMayHaveCompleted() throws {
        let e = try entry(at: .invoking)
        let journal = try restart()
        _ = try journal.recoverAfterCrash(using: reconciler)
        XCTAssertEqual(journal.entry(e.id)?.result, ActionResult(.mayHaveCompleted))
        XCTAssertEqual(journal.entry(e.id)?.result?.rendered, "may_have_completed")
        XCTAssertNotEqual(journal.lookup(T.sendKey(), again: false), .fresh)
    }

    func testReconciledResultThatWouldFreeTheKeyBecomesMayHaveCompleted() throws {
        let a = try entry(at: .invoking, text: "one")
        let b = try entry(at: .invoked, text: "two")
        reconciler.results[a.id] = ActionResult(.timeout)
        reconciler.results[b.id] = ActionResult(.failed(.bridgeRestarted))
        let journal = try restart()
        _ = try journal.recoverAfterCrash(using: reconciler)
        XCTAssertEqual(journal.entry(a.id)?.result, ActionResult(.mayHaveCompleted))
        XCTAssertEqual(journal.entry(b.id)?.result, ActionResult(.mayHaveCompleted))
        XCTAssertEqual(journal.lookup(T.sendKey(text: "one"), again: false),
                       .replay(.failure(WireError(result: ActionResult(.mayHaveCompleted)))))
    }

    func testReconcilerGetsTheBindingTheFactsAndATenSecondDeadline() throws {
        let e = try entry(at: .invoked)
        let journal = try restart()
        _ = try journal.recoverAfterCrash(using: reconciler)
        XCTAssertEqual(reconciler.seen.count, 1)
        let seen = try XCTUnwrap(reconciler.seen.first)
        XCTAssertEqual(seen.entry.id, e.id)
        XCTAssertEqual(seen.entry.binding, T.sendBinding(T.mom))
        XCTAssertEqual(seen.entry.facts, InvocationFacts(snapshotRowID: 900))
        XCTAssertEqual(seen.deadline, clock.uptime + Limits.reconcileTimeout)
    }

    func testFinalEntriesAreLeftAlone() throws {
        let e = try entry(at: .final)
        let journal = try restart()
        _ = try journal.recoverAfterCrash(using: reconciler)
        XCTAssertEqual(journal.entry(e.id), e)
        XCTAssertTrue(reconciler.seen.isEmpty)
    }

    func testRecoveryIsOnDisk() throws {
        let a = try entry(at: .received, text: "one")
        let b = try entry(at: .invoking, text: "two")
        _ = try restart().recoverAfterCrash(using: reconciler)
        let again = try restart()
        XCTAssertEqual(again.entry(a.id)?.state, .final)
        XCTAssertEqual(again.entry(b.id)?.state, .final)
        XCTAssertFalse(try again.recoverAfterCrash(using: reconciler))
        XCTAssertEqual(reconciler.seen.count, 1)
    }

    func testRecoveryThatCantWriteThrows() throws {
        let open = try entry(at: .invoking)
        let journal = try restart()
        chmod(journal.fileURL.path, 0o400)
        defer { chmod(journal.fileURL.path, 0o600) }
        XCTAssertThrowsError(try journal.recoverAfterCrash(using: reconciler))
        // Unlike `finish`, recovery doesn't mark the entry final in memory, so the bridge keeps refusing mutations.
        XCTAssertEqual(journal.entry(open.id)?.state, .invoking)
        XCTAssertEqual(journal.lookup(open.key, again: false), .mayHaveCompleted)
    }

    // MARK: The foreground flag

    func testForegroundFlagBeforeTheFirstPressTurnsForegroundModeOff() throws {
        // Activated, crashed before any press: the entry is still at approved.
        let e = try entry(at: .approved, action: .edit, foreground: true)
        let journal = try restart()
        XCTAssertTrue(try journal.recoverAfterCrash(using: reconciler))
        XCTAssertEqual(journal.entry(e.id)?.result, ActionResult(.failed(.bridgeRestarted)))
        XCTAssertEqual(journal.entry(e.id)?.foreground, false)
    }

    func testForegroundFlagAtAnyOpenStateCounts() throws {
        for state in [JournalState.received, .approved, .invoking, .invoked] {
            let dir = TempDir()
            journal = try Journal(directory: dir.url, clock: clock)
            _ = try entry(at: state, action: .threadedReply, foreground: true)
            let restarted = try Journal(directory: dir.url, clock: clock)
            XCTAssertTrue(try restarted.recoverAfterCrash(using: reconciler), "\(state)")
        }
    }

    func testFinishClearsTheForegroundFlag() throws {
        let e = try entry(at: .invoking, action: .edit, foreground: true)
        try journal.finish(e.id, result: ActionResult(.ok), response: T.uiOutcome(ActionResult(.ok)))
        XCTAssertEqual(journal.entry(e.id)?.foreground, false)
        XCTAssertFalse(try restart().recoverAfterCrash(using: reconciler))
    }

    func testFlagSetBackToFalseDoesntCount() throws {
        let e = try entry(at: .invoking, action: .edit, foreground: true)
        try journal.markForeground(e.id, false)
        XCTAssertFalse(try restart().recoverAfterCrash(using: reconciler))
    }

    func testNoForegroundEntryReturnsFalse() throws {
        _ = try entry(at: .invoking)
        _ = try entry(at: .approved, text: "two")
        XCTAssertFalse(try restart().recoverAfterCrash(using: reconciler))
    }

    func testForegroundCrashTurnsForegroundModeOffInTheStore() throws {
        let store = PolicyStore(fileURL: dir.file("policy.json"), keychain: InMemoryKeychain())
        try store.setForegroundMode(true)
        _ = try entry(at: .approved, action: .edit, foreground: true)
        if try restart().recoverAfterCrash(using: reconciler) {
            store.turnForegroundOff(reason: "bridge restarted during a foreground action")
        }
        XCTAssertFalse(store.isForegroundModeOn)
    }
}
