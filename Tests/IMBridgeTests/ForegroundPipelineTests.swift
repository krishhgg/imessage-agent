import XCTest
@testable import IMBridge
import IMCore
import IMForeground
import IMPolicy
import IMStore
import IMTestSupport
import IMUI

/// Threaded replies and edits run through `ForegroundMachine` over fakes. Nothing activates Messages: the fake app
/// refuses to come to the front, and these tests stop the machine before that step.
final class ForegroundPipelineTests: XCTestCase {
    private func foregroundHarness() throws -> Harness {
        let h = try Harness(Harness.Options(foreground: true))
        try h.policy.setForegroundMode(true)
        return h
    }

    func testTheEntryIsMarkedForegroundBeforeTheMachineRunsAndClearedAtFinal() throws {
        let h = try foregroundHarness()
        h.targeting.selection = .refused(ActionResult(.notLoaded))
        let lock = NSLock()
        var seen: [Bool] = []
        h.input.onRead = { [journal = h.journal] in
            let marked = journal.allEntries().last?.foreground ?? false
            lock.lock()
            seen.append(marked)
            lock.unlock()
        }
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true).sendOutcome)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.parts.first?.result.code, .notLoaded)
        lock.lock()
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0 }, "every machine step runs with the entry marked")
        lock.unlock()
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertFalse(entry.foreground)
        XCTAssertFalse(h.queue.isHeld, "the machine's ticket is released after final")
        XCTAssertEqual(h.queue.acquisitions, 1)
        XCTAssertEqual(h.app.calls.filter { $0 == "activateForeground" }, [])
    }

    func testAThreadedReplyInAGroupIsAnUnsupportedTargetBeforeTheDialog() throws {
        let h = try foregroundHarness()
        let outcome = try XCTUnwrap(h.send("Yes!", to: "12", thread: true).sendOutcome)
        XCTAssertEqual(outcome.early?.code, .unsupportedTarget)
        XCTAssertFalse(outcome.approved)
        XCTAssertTrue(outcome.parts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.ax.performed.isEmpty)
        XCTAssertEqual(h.queue.acquisitions, 0)
    }

    func testAThreadedReplyWithoutAccessibilityIsRefusedBeforeTheDialog() throws {
        let h = try foregroundHarness()
        h.permissions.accessibilityState = .denied
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true).sendOutcome)
        XCTAssertEqual(outcome.early, UIResults.accessibilityMissing)
        XCTAssertFalse(outcome.approved)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertEqual(h.queue.acquisitions, 0)
        XCTAssertEqual(h.permissions.calls, [.accessibility(prompt: false)], "the check never prompts")
    }

    func testIdleGateEventsReachTheRequestAndUserActivityIsBusy() throws {
        let h = try foregroundHarness()
        h.input.idle = 0
        let events = EventLog()
        let start = h.clock.uptime
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true, events: events).sendOutcome)
        XCTAssertEqual(outcome.parts.first?.result.code, .busy(.userActive))
        XCTAssertTrue(events.events.contains(.waitingForIdle))
        XCTAssertGreaterThanOrEqual(h.clock.uptime - start, Limits.idleGateTimeout)
        XCTAssertEqual(h.queue.acquisitions, 0)
        XCTAssertFalse(try h.onlyEntry().foreground)
    }

    func testTheMachineTakesTheQueueItselfAndAnswersBusy() throws {
        let h = try foregroundHarness()
        let held = try XCTUnwrap(h.queue.acquire(timeout: 0))
        defer { h.queue.release(held) }
        let events = EventLog()
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true, events: events).sendOutcome)
        XCTAssertEqual(outcome.parts.first?.result.code, .busy(.queue))
        XCTAssertEqual(events.events.filter { $0 == .queued }.count, 1, "only the machine announces the queue")
        XCTAssertTrue(h.queue.isHeld)
    }

    func testForegroundModeTurnedOffDuringTheDialogRunsNothing() throws {
        let h = try Harness(Harness.Options(foreground: true, plan: .hold))
        try h.policy.setForegroundMode(true)
        let first = try XCTUnwrap(h.send("Yes!", thread: true, approvalWait: 0).sendOutcome)
        guard case .pending(let id)? = first.early?.code else { return XCTFail("pending") }
        h.policy.turnForegroundOff(reason: "turned off by the user")
        h.clock.advance(Limits.approvalButtonDelay + 1)
        h.presenter.decide(id, .allowOnce)
        h.waitUntilIdle()
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertEqual(entry.result, .foregroundModeOff)
        XCTAssertFalse(entry.foreground)
        XCTAssertEqual(h.queue.acquisitions, 0)
    }

    // MARK: Rate limits (section 2)

    private func recordSend(_ h: Harness, secondsAgo: TimeInterval = 0) throws {
        let mom = try h.mom()
        h.container.engine.limiter.record(SendEvent(chat: mom.canonical, at: h.clock.now.addingTimeInterval(-secondsAgo),
                                                    guid: nil, textDigest: nil))
    }

    func testAThreadedReplyOverARateLimitNamesItInItsOnlyDialog() throws {
        let h = try foregroundHarness()
        h.targeting.selection = .refused(ActionResult(.notLoaded))
        try recordSend(h, secondsAgo: 5)
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true).sendOutcome)
        XCTAssertEqual(h.presenter.prompts.map(\.reason), [RateLimitBreach.perChatInterval.dialogReason])
        XCTAssertEqual(h.presenter.prompts.first?.offersAlwaysAllow, false)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.parts.first?.result.code, .notLoaded, "approved knowing the limit, so the machine runs")
        XCTAssertEqual(h.queue.acquisitions, 1)
    }

    func testASendWhileTheDialogIsUpMakesTheRecheckAskAgain() throws {
        let h = try foregroundHarness()
        h.targeting.selection = .refused(ActionResult(.notLoaded))
        let mom = try h.mom()
        let lock = NSLock()
        var recorded = false
        var heldDuringSecondDialog: Bool?
        h.clock.onSleep { [presenter = h.presenter, limiter = h.container.engine.limiter, queue = h.queue] clock in
            let shown = presenter.prompts.count
            lock.lock()
            defer { lock.unlock() }
            if shown == 1, !recorded {
                // A plain send to Mom finishes while the threaded reply's dialog is up.
                limiter.record(SendEvent(chat: mom.canonical, at: clock.now, guid: nil, textDigest: nil))
                recorded = true
            }
            if shown == 2, heldDuringSecondDialog == nil { heldDuringSecondDialog = queue.isHeld }
        }
        let outcome = try XCTUnwrap(h.send("Yes!", thread: true).sendOutcome)
        let prompts = h.presenter.prompts
        XCTAssertEqual(prompts.map(\.reason), ["threaded replies always ask", RateLimitBreach.perChatInterval.dialogReason])
        XCTAssertEqual(prompts.last?.offersAlwaysAllow, false)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.parts.first?.result.code, .notLoaded)
        lock.lock()
        XCTAssertEqual(heldDuringSecondDialog, false, "the queue is free while the second dialog waits")
        lock.unlock()
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertEqual(entry.approvalID, prompts.last?.id)
        XCTAssertFalse(entry.foreground)
        XCTAssertFalse(h.queue.isHeld)
        XCTAssertEqual(h.queue.acquisitions, 2, "the recheck held the queue, then the run took it again")
        XCTAssertEqual(h.app.calls.filter { $0 == "activateForeground" }, [])
    }

    func testDenyingTheSecondDialogRunsNothing() throws {
        let h = try Harness(Harness.Options(foreground: true, plan: .hold))
        try h.policy.setForegroundMode(true)
        let first = try XCTUnwrap(h.send("Yes!", thread: true, approvalWait: 0).sendOutcome)
        guard case .pending(let firstID)? = first.early?.code else { return XCTFail("pending") }
        try recordSend(h)
        h.clock.advance(Limits.approvalButtonDelay + 1)
        h.presenter.decide(firstID, .allowOnce)
        XCTAssertTrue(eventually { h.presenter.prompts.count == 2 })
        let second = try XCTUnwrap(h.presenter.prompts.last)
        XCTAssertEqual(second.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertTrue(eventually { h.journal.entry(pendingID: second.id) != nil })
        XCTAssertEqual(h.send("Yes!", thread: true, approvalWait: 0).sendOutcome?.early?.code, .pending(id: second.id),
                       "a repeated key waits on the second dialog")
        XCTAssertFalse(h.queue.isHeld)
        h.clock.advance(Limits.approvalButtonDelay + 1)
        h.presenter.decide(second.id, .deny)
        h.waitUntilIdle()
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.result, ActionResult(.denied(.user)))
        XCTAssertFalse(entry.foreground)
        XCTAssertEqual(h.queue.acquisitions, 1, "only the recheck took the queue")
        XCTAssertEqual(h.ax.performed, [])
    }

    func testAThreadedReplyThatRanCountsTowardTheLimits() throws {
        let h = try foregroundHarness()
        let mom = try h.mom()
        let digest = TextNorm.textDigest("Yes!")
        let binding = ApprovalBinding(chat: mom.canonical, action: .threadedReply, textDigest: digest, parentGUID: "PARENT")
        let request = MutationRequest(binding: binding, chat: mom, requiredScope: .text, text: "Yes!",
                                      parentText: "Are you coming?")
        let pong = ResponsePayload.pong(PongInfo(bridgeVersion: "", pid: 0))
        // Stands in for the machine: `invoking` right before Return, then the reply's row.
        let job = MutationJob(
            key: .send(chat: mom.canonical, threaded: true, parentGUID: "PARENT", textDigest: digest, attachmentDigest: nil),
            again: false, request: request, approvalWait: 120, startedAt: h.clock.uptime, queue: .foreground,
            windowOpen: nil, early: { _, _ in pong }, found: { _ in pong },
            act: { ctx in
                try? ctx.recorder.willInvoke(InvocationFacts(snapshotRowID: 500))
                return ActionOutcome(result: ActionResult(.delivered), payload: pong)
            })
        _ = MutationPipeline(container: h.container).run(job, events: { _ in })
        XCTAssertEqual(try h.onlyEntry().result, ActionResult(.delivered))
        XCTAssertEqual(h.container.engine.limiter.history.map(\.chat), [mom.canonical])
        XCTAssertEqual(try h.container.engine.limiter.check(chat: mom), .perChatInterval)
    }

    func testAnEditRunsThroughTheMachineWithItsTicketReleased() throws {
        let h = try foregroundHarness()
        h.targeting.selection = .refused(ActionResult(.notLoaded))
        let rowid = try h.insertOwnMessage(62_010, text: "see you at 5", age: 30)
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .edit(rowid: rowid, text: "see you at 6")))).uiOutcome)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.result.code, .notLoaded)
        XCTAssertFalse(h.queue.isHeld)
        XCTAssertFalse(try h.onlyEntry().foreground)
    }
}
