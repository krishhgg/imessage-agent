import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 3 item 1: what a repeated key finds.
final class JournalLookupTests: XCTestCase {
    private var dir: TempDir!
    private var clock: FakeClock!
    private var journal: Journal!
    private var t0: Date!

    override func setUp() {
        dir = TempDir()
        clock = FakeClock()
        journal = try! Journal(directory: dir.url, clock: clock)
        t0 = clock.now
    }

    override func tearDown() {
        journal = nil
        dir = nil
    }

    private let key = T.sendKey()

    private func heart(remove: Bool = false, part: Int = 0, kind: TapbackKind = .heart) -> IdempotencyKey {
        .ui(action: .react, targetGUID: "TARGET", part: part, remove: remove, tapback: kind, newTextDigest: nil)
    }

    /// Runs an entry through every state to `final`.
    @discardableResult
    private func finished(_ key: IdempotencyKey? = nil, action: MutationKind = .send,
                          result: ActionResult = ActionResult(.delivered), response: ResponsePayload? = nil) throws
        -> JournalEntry {
        let key = key ?? self.key
        let entry = try journal.begin(key: key, action: action, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.advance(entry.id, to: .invoking, facts: InvocationFacts(snapshotRowID: 500))
        try journal.advance(entry.id, to: .invoked)
        let payload = response ?? (action == .send ? T.sendOutcome(result) : T.uiOutcome(result))
        try journal.finish(entry.id, result: result, response: payload)
        return try XCTUnwrap(journal.entry(entry.id))
    }

    // MARK: Replay

    func testHeldKeyReplaysTheFirstResponse() throws {
        try finished(response: T.sendOutcome(ActionResult(.delivered), guid: "ROW-1"))
        guard case .replay(.send(let outcome)) = journal.lookup(key, again: false) else {
            return XCTFail("expected a replay")
        }
        XCTAssertEqual(outcome.parts.first?.guid, "ROW-1")
        XCTAssertEqual(outcome.parts.first?.result, ActionResult(.delivered))
        XCTAssertNil(outcome.text)
    }

    func testWindowEndsTenMinutesAfterTheActionRan() throws {
        try finished()
        clock.now = t0.addingTimeInterval(Limits.idempotencyWindow - 0.001)
        XCTAssertNotEqual(journal.lookup(key, again: false), .fresh)
        clock.now = t0.addingTimeInterval(Limits.idempotencyWindow)
        XCTAssertEqual(journal.lookup(key, again: false), .fresh)
    }

    func testSendApprovedLateHoldsTheKeyForTenMinutesFromInvoking() throws {
        let entry = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.attachApproval(entry.id, approvalID: "a1b2c3d4")
        // The user answers the dialog 9 minutes after the request arrived.
        clock.now = t0.addingTimeInterval(9 * 60)
        try journal.advance(entry.id, to: .approved, approvalID: "a1b2c3d4")
        let invokedAt = t0.addingTimeInterval(9 * 60 + 30)
        clock.now = invokedAt
        try journal.advance(entry.id, to: .invoking, facts: InvocationFacts(snapshotRowID: 500))
        try journal.advance(entry.id, to: .invoked)
        clock.now = invokedAt.addingTimeInterval(10)
        try journal.finish(entry.id, result: ActionResult(.delivered),
                           response: T.sendOutcome(ActionResult(.delivered), guid: "LATE"))

        // 14.5 minutes after the request, 5 after the send: a repeat still replays and sends nothing.
        clock.now = invokedAt.addingTimeInterval(5 * 60)
        guard case .replay(.send(let outcome)) = journal.lookup(key, again: false) else {
            return XCTFail("a send delivered late should still hold its key")
        }
        XCTAssertEqual(outcome.parts.first?.guid, "LATE")
        clock.now = invokedAt.addingTimeInterval(Limits.idempotencyWindow - 0.001)
        XCTAssertNotEqual(journal.lookup(key, again: false), .fresh)
        clock.now = invokedAt.addingTimeInterval(Limits.idempotencyWindow)
        XCTAssertEqual(journal.lookup(key, again: false), .fresh)
    }

    func testDenialRecordedLateHoldsTheKeyForTenMinutesFromTheDenial() throws {
        let entry = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.attachApproval(entry.id, approvalID: "a1b2c3d4")
        let deniedAt = t0.addingTimeInterval(9 * 60)
        clock.now = deniedAt
        let denied = ActionResult(.denied(.user))
        try journal.finish(entry.id, result: denied, response: .failure(WireError(result: denied)))

        clock.now = deniedAt.addingTimeInterval(5 * 60)
        guard case .replay(.failure) = journal.lookup(key, again: false) else {
            return XCTFail("a late denial should still hold its key, so the dialog doesn't come back")
        }
        clock.now = deniedAt.addingTimeInterval(Limits.idempotencyWindow)
        XCTAssertEqual(journal.lookup(key, again: false), .fresh)
    }

    func testResultsThatDontHoldTheKeyRunAgain() throws {
        let notHeld: [ActionResult] = [
            ActionResult(.failed(.bridgeRestarted)), ActionResult(.denied(.approvalExpired)),
            ActionResult(.busy(.queue)), ActionResult(.aborted(.userTookOver)), ActionResult(.timeout),
            ActionResult(.error(.wrongChat)), ActionResult(.failed(.messagesNotReady)),
            ActionResult(.busy(.chatNotOpen), fix: "open Sam in Messages, hide it (⌘H), then retry"),
        ]
        for (i, result) in notHeld.enumerated() {
            let key = T.sendKey(text: "not held \(i)")
            try finished(key, result: result)
            XCTAssertEqual(journal.lookup(key, again: false), .fresh, result.rendered)
        }
    }

    func testResultsThatHoldTheKeyReplay() throws {
        let held: [ActionResult] = [
            ActionResult(.submitted), ActionResult(.delivered), ActionResult(.ghost), ActionResult(.mayHaveCompleted),
            ActionResult(.failed(.rowError(22))), ActionResult(.failed(.transferFailed)),
            ActionResult(.ambiguous(.twoRowsMatched)), ActionResult(.denied(.user)),
            ActionResult(.aborted(.userTookOver), notes: [.agentTextMayRemain]),
        ]
        for (i, result) in held.enumerated() {
            let key = T.sendKey(text: "held \(i)")
            try finished(key, result: result)
            guard case .replay = journal.lookup(key, again: false) else {
                XCTFail("\(result.rendered) should replay")
                continue
            }
        }
    }

    func testNewestFinalEntryIsReplayed() throws {
        try finished(result: ActionResult(.denied(.user)))
        clock.advance(5)
        try finished(response: T.sendOutcome(ActionResult(.delivered), guid: "SECOND"))
        guard case .replay(.send(let outcome)) = journal.lookup(key, again: false) else { return XCTFail() }
        XCTAssertEqual(outcome.parts.first?.guid, "SECOND")
    }

    func testAgainSkipsTheLookupForFinalReceivedAndApprovedEntries() throws {
        try finished()
        XCTAssertEqual(journal.lookup(key, again: true), .fresh)
        let waiting = try journal.begin(key: T.sendKey(text: "x"), action: .send, chat: T.mom,
                                        binding: T.sendBinding(T.mom, text: "x"))
        XCTAssertEqual(journal.lookup(T.sendKey(text: "x"), again: true), .fresh)
        try journal.advance(waiting.id, to: .approved, approvalID: "a1b2c3d4")
        XCTAssertEqual(journal.lookup(T.sendKey(text: "x"), again: true), .fresh)
    }

    func testAgainStillFindsAnEntryAtInvokingOrInvoked() throws {
        let inFlight = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.advance(inFlight.id, to: .invoking)
        XCTAssertEqual(journal.lookup(key, again: true), .mayHaveCompleted)
        try journal.advance(inFlight.id, to: .invoked)
        XCTAssertEqual(journal.lookup(key, again: true), .mayHaveCompleted)
        clock.advance(3600)
        XCTAssertEqual(journal.lookup(key, again: true), .mayHaveCompleted, "an open entry matches whatever its age")
        XCTAssertEqual(journal.lookup(T.sendKey(text: "other"), again: true), .fresh, "only the same key")
        try journal.finish(inFlight.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))
        XCTAssertEqual(journal.lookup(key, again: true), .fresh, "once final, --again runs again")
    }

    // MARK: Claiming a key

    func testClaimOnAFreshKeyStartsAReceivedEntry() throws {
        guard case .run(let entry) = try journal.claim(key: key, again: false, action: .send, chat: T.mom,
                                                       binding: T.sendBinding(T.mom)) else {
            return XCTFail("expected a new entry")
        }
        XCTAssertEqual(entry.state, .received)
        XCTAssertEqual(journal.entry(entry.id), entry)
        XCTAssertEqual(try journal.claim(key: key, again: false, action: .send, chat: T.mom,
                                         binding: T.sendBinding(T.mom)),
                       .found(.pending(approvalID: entry.id)))
        XCTAssertEqual(journal.allEntries().count, 1)
    }

    func testClaimOnAHeldKeyFindsTheReplayAndWritesNothing() throws {
        try finished(response: T.sendOutcome(ActionResult(.delivered), guid: "ROW-1"))
        let before = try Data(contentsOf: journal.fileURL)
        guard case .found(.replay(.send(let outcome))) = try journal.claim(key: key, again: false, action: .send,
                                                                           chat: T.mom,
                                                                           binding: T.sendBinding(T.mom)) else {
            return XCTFail("expected a replay")
        }
        XCTAssertEqual(outcome.parts.first?.guid, "ROW-1")
        XCTAssertEqual(try Data(contentsOf: journal.fileURL), before)
    }

    func testClaimWithAgainStartsAnEntryEvenWhenTheKeyIsHeld() throws {
        let first = try finished()
        guard case .run(let second) = try journal.claim(key: key, again: true, action: .send, chat: T.mom,
                                                        binding: T.sendBinding(T.mom)) else {
            return XCTFail("--again should run")
        }
        XCTAssertNotEqual(second.id, first.id)
    }

    func testClaimWithAgainStartsAnEntryWhileTheKeyIsReceivedOrApproved() throws {
        let first = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.attachApproval(first.id, approvalID: "a1b2c3d4")
        guard case .run(let second) = try journal.claim(key: key, again: true, action: .send, chat: T.mom,
                                                        binding: T.sendBinding(T.mom)) else {
            return XCTFail("--again runs while the first request waits for its dialog")
        }
        try journal.advance(first.id, to: .approved, approvalID: "a1b2c3d4")
        guard case .run(let third) = try journal.claim(key: key, again: true, action: .send, chat: T.mom,
                                                       binding: T.sendBinding(T.mom)) else {
            return XCTFail("--again runs while the first request is approved and not yet invoking")
        }
        XCTAssertEqual(Set([first.id, second.id, third.id]).count, 3)
    }

    func testClaimWithAgainWhileTheKeyIsInvokingOrInvokedRunsNothing() throws {
        for state in [JournalState.invoking, .invoked] {
            let key = T.sendKey(text: "state \(state)")
            let binding = T.sendBinding(T.mom, text: "state \(state)")
            let first = try journal.begin(key: key, action: .send, chat: T.mom, binding: binding)
            try journal.advance(first.id, to: .invoking, facts: InvocationFacts(snapshotRowID: 500))
            if state == .invoked { try journal.advance(first.id, to: .invoked) }
            let before = try Data(contentsOf: journal.fileURL)
            let count = journal.allEntries().count

            XCTAssertEqual(try journal.claim(key: key, again: true, action: .send, chat: T.mom, binding: binding),
                           .found(.mayHaveCompleted), "\(state)")
            XCTAssertEqual(try Data(contentsOf: journal.fileURL), before, "no new entry is written")
            XCTAssertEqual(journal.allEntries().count, count)
            XCTAssertEqual(journal.entry(first.id)?.state, state, "the first request carries on")
        }
    }

    func testAgainWithASameKeyRequestInFlightOnAnotherThreadRunsNothing() throws {
        let journal = try Journal(directory: dir.url.appendingPathComponent("in-flight"), clock: SystemClock())
        guard case .run(let first) = try journal.claim(key: key, again: false, action: .send, chat: T.mom,
                                                       binding: T.sendBinding(T.mom)) else {
            return XCTFail("the first request runs")
        }
        let invoking = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // The first request: journal invoking, then hold, as a send waiting on its Apple Event does.
            try? journal.recorder(for: first.id).willInvoke(InvocationFacts(snapshotRowID: 500))
            invoking.signal()
            finish.wait()
            try? journal.recorder(for: first.id).didInvoke()
            try? journal.finish(first.id, result: ActionResult(.delivered),
                                response: T.sendOutcome(ActionResult(.delivered)))
            done.signal()
        }
        XCTAssertEqual(invoking.wait(timeout: .now() + 10), .success)

        let lock = NSLock()
        var claims: [KeyClaim] = []
        var errors: [Error] = []
        concurrently(8) { _ in
            do {
                let claim = try journal.claim(key: self.key, again: true, action: .send, chat: T.mom,
                                              binding: T.sendBinding(T.mom))
                lock.lock(); claims.append(claim); lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(claims, Array(repeating: .found(.mayHaveCompleted), count: 8))
        XCTAssertEqual(journal.allEntries().map(\.id), [first.id], "--again started nothing")

        finish.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        guard case .run = try journal.claim(key: key, again: true, action: .send, chat: T.mom,
                                            binding: T.sendBinding(T.mom)) else {
            return XCTFail("once the first request is final, --again runs")
        }
    }

    func testConcurrentClaimsOfOneKeyRunItOnce() throws {
        let journal = try Journal(directory: dir.url.appendingPathComponent("concurrent"), clock: SystemClock())
        let lock = NSLock()
        var runs = 0
        var pendings = 0
        var errors: [Error] = []
        concurrently(32) { _ in
            do {
                let claim = try journal.claim(key: self.key, again: false, action: .send, chat: T.mom,
                                              binding: T.sendBinding(T.mom))
                lock.lock()
                if case .run = claim { runs += 1 } else if case .found(.pending) = claim { pendings += 1 }
                lock.unlock()
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(pendings, 31)
        XCTAssertEqual(journal.allEntries().count, 1)
    }

    // MARK: Requests in flight

    func testReceivedEntryGivesPendingWithItsID() throws {
        let entry = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        XCTAssertEqual(journal.lookup(key, again: false), .pending(approvalID: entry.id))
    }

    func testOpenDialogGivesPendingWithTheApprovalID() throws {
        let entry = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.attachApproval(entry.id, approvalID: "a1b2c3d4")
        XCTAssertEqual(journal.lookup(key, again: false), .pending(approvalID: "a1b2c3d4"))
        try journal.advance(entry.id, to: .approved, approvalID: "a1b2c3d4")
        XCTAssertEqual(journal.lookup(key, again: false), .pending(approvalID: "a1b2c3d4"))
    }

    func testInvokingAndInvokedGiveMayHaveCompleted() throws {
        let entry = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.advance(entry.id, to: .invoking)
        XCTAssertEqual(journal.lookup(key, again: false), .mayHaveCompleted)
        try journal.advance(entry.id, to: .invoked)
        XCTAssertEqual(journal.lookup(key, again: false), .mayHaveCompleted)
    }

    func testInFlightEntryMatchesPastTheWindow() throws {
        let waiting = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        let otherKey = T.sendKey(text: "other")
        let running = try journal.begin(key: otherKey, action: .send, chat: T.mom,
                                        binding: T.sendBinding(T.mom, text: "other"))
        try journal.advance(running.id, to: .invoking)
        clock.advance(3600)
        XCTAssertEqual(journal.lookup(key, again: false), .pending(approvalID: waiting.id))
        XCTAssertEqual(journal.lookup(otherKey, again: false), .mayHaveCompleted)
    }

    func testInFlightEntryWinsOverAnOlderFinalOne() throws {
        try finished(result: ActionResult(.denied(.user)))
        let again = try journal.begin(key: key, action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.advance(again.id, to: .invoking)
        XCTAssertEqual(journal.lookup(key, again: false), .mayHaveCompleted)
    }

    // MARK: UI actions

    func testRepeatedTapbackWithOkRereadsTheReaction() throws {
        let entry = try finished(heart(), action: .react, result: ActionResult(.ok))
        XCTAssertEqual(journal.lookup(heart(), again: false), .rereadReaction(entry))
    }

    func testRepeatedTapbackWithAnotherHeldResultReplays() throws {
        try finished(heart(), action: .react, result: ActionResult(.mayHaveCompleted))
        guard case .replay(.ui(let outcome)) = journal.lookup(heart(), again: false) else { return XCTFail() }
        XCTAssertEqual(outcome.result, ActionResult(.mayHaveCompleted))
        XCTAssertNil(outcome.targetQuote)
    }

    func testRepeatedUnsendWithOkReplays() throws {
        let unsend = IdempotencyKey.ui(action: .unsend, targetGUID: "TARGET", part: 0, remove: false, tapback: nil,
                                       newTextDigest: nil)
        try finished(unsend, action: .unsend, result: ActionResult(.ok))
        guard case .replay = journal.lookup(unsend, again: false) else { return XCTFail() }
    }

    func testLaterFinalKeyOnTheSameTargetSupersedes() throws {
        try finished(heart(), action: .react, result: ActionResult(.ok))
        clock.advance(10)
        let removal = try finished(heart(remove: true), action: .react, result: ActionResult(.ok))
        XCTAssertEqual(journal.lookup(heart(), again: false), .fresh)
        XCTAssertEqual(journal.lookup(heart(remove: true), again: false), .rereadReaction(removal))
    }

    func testLaterFinalKeyThatChangedNothingDoesntSupersede() throws {
        let first = try finished(heart(), action: .react, result: ActionResult(.ok))
        let noEffect = [ActionResult(.notLoaded), ActionResult(.unsupported), ActionResult(.failed(.bridgeRestarted)),
                        ActionResult(.denied(.approvalExpired)), ActionResult(.busy(.queue))]
        for result in noEffect {
            XCTAssertFalse(result.holdsIdempotencyKey, "\(result.rendered)")
            clock.advance(1)
            try finished(heart(remove: true), action: .react, result: result)
            XCTAssertEqual(journal.lookup(heart(), again: false), .rereadReaction(first), result.rendered)
        }

        clock.advance(1)
        try finished(heart(remove: true), action: .react, result: ActionResult(.mayHaveCompleted))
        XCTAssertEqual(journal.lookup(heart(), again: false), .fresh, "a removal that may have run supersedes")
    }

    func testLaterKeyThatIsntFinalDoesntSupersede() throws {
        let first = try finished(heart(), action: .react, result: ActionResult(.ok))
        clock.advance(10)
        let removal = try journal.begin(key: heart(remove: true), action: .react, chat: T.mom,
                                        binding: T.sendBinding(T.mom))
        try journal.advance(removal.id, to: .invoking)
        XCTAssertEqual(journal.lookup(heart(), again: false), .rereadReaction(first))
    }

    func testSupersedingIsPerPart() throws {
        let first = try finished(heart(), action: .react, result: ActionResult(.ok))
        clock.advance(10)
        try finished(heart(part: 1, kind: .like), action: .react, result: ActionResult(.ok))
        XCTAssertEqual(journal.lookup(heart(), again: false), .rereadReaction(first))
    }

    func testEarlierKeyOnTheSameTargetDoesntSupersede() throws {
        try finished(heart(kind: .like), action: .react, result: ActionResult(.ok))
        clock.advance(10)
        let later = try finished(heart(), action: .react, result: ActionResult(.ok))
        XCTAssertEqual(journal.lookup(heart(), again: false), .rereadReaction(later))
    }
}
