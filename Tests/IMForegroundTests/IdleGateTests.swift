import Foundation
import XCTest
import CoreGraphics
@testable import IMForeground
import IMCore
import IMTestSupport

/// Step 2 (the idle gate) and step 3's activation check with its release and retake.
final class IdleGateTests: XCTestCase {
    // MARK: - Step 2

    func testIdleGatePassesAtExactlyTwoSecondsWithoutInput() {
        let h = Harness()
        h.input.inputs = [h.clock.uptime - 1.5]
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.queue.acquiredAt, [1000.5])
        XCTAssertEqual(h.log.count(.progress(.waitingForIdle)), 1)
    }

    func testIdleGateKeepsWaitingJustUnderTwoSeconds() {
        let h = Harness()
        h.input.inputs = [h.clock.uptime - 1.5 + 1.0 / 64.0]
        h.runEdit()
        XCTAssertEqual(h.queue.acquiredAt, [1000.5 + 1.0 / 64.0])
    }

    func testIdleGateRunsOutAfterThirtySecondsWithBusyUserActive() {
        let h = Harness()
        h.input.inputs = Array(stride(from: 1000.0, through: 1040.0, by: 0.5))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.busy(.userActive)))
        XCTAssertEqual(h.clock.uptime, 1030)
        XCTAssertNil(outcome.ticket)
        XCTAssertEqual(outcome.lastPhase, .idleGate)
        XCTAssertTrue(h.log.acquireTimeouts.isEmpty, "took the queue")
        XCTAssertEqual(h.log.count(.ensureHidden), 0)
        assertNothingActivated(h)
    }

    func testIdleGateChecksOnceMoreAtTheThirtySecondMark() {
        let h = Harness()
        h.input.inputs = Array(stride(from: 1000.0, through: 1028.0, by: 0.5))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.queue.acquiredAt, [1030])
    }

    func testIdleGateTreatsNaNAndNegativeReadingsAsInput() {
        for reading in [TimeInterval.nan, -1] {
            let h = Harness()
            h.input.reading = reading
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result, ActionResult(.busy(.userActive)), "\(reading)")
            XCTAssertTrue(h.log.acquireTimeouts.isEmpty)
        }
    }

    func testQueueIsNotHeldWhileTheIdleGateWaits() {
        let h = Harness()
        h.input.inputs = [h.clock.uptime - 0.25]
        var readsWhileWaiting = 0
        h.input.onRead = { [unowned h] in
            guard h.machine.phase == .idleGate else { return }
            readsWhileWaiting += 1
            XCTAssertNil(h.queue.holder, "queue held at the idle gate")
        }
        h.runEdit()
        XCTAssertGreaterThan(readsWhileWaiting, 1)
        let waiting = h.log.index(of: .progress(.waitingForIdle))
        let acquire = h.log.events.firstIndex { if case .acquire = $0 { return true } else { return false } }
        XCTAssertNotNil(waiting)
        XCTAssertLessThan(waiting ?? .max, acquire ?? -1)
        XCTAssertEqual(h.queue.acquiredAt, [1001.75])
    }

    func testNoWaitingEventWhenAlreadyIdle() {
        let h = Harness()
        h.runEdit()
        XCTAssertEqual(h.log.count(.progress(.waitingForIdle)), 0)
    }

    func testLiveInputMonitorReadsKeysFlagsButtonsAndScrollButNotMoves() {
        let types = Set(HIDInputMonitor.eventTypes.map(\.rawValue))
        let expected: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                       .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        for type in expected { XCTAssertTrue(types.contains(type.rawValue), "\(type.rawValue)") }
        XCTAssertFalse(types.contains(CGEventType.mouseMoved.rawValue))
    }

    // MARK: - Step 3, the activation check

    func testInputDuringStep1ReleasesQueueAndRepeatsStep1() {
        let h = Harness()
        h.injectInput(on: .selectChat)
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(outcome.result.code, .ok)
        let gate: [Event] = h.actions.filter {
            switch $0 {
            case .acquire, .release, .ensureHidden, .selectChat, .findBubble, .activate, .progress, .input: return true
            default: return false
            }
        }
        XCTAssertEqual(Array(gate.prefix(12)), [
            .acquire(100), .ensureHidden, .selectChat, .input, .findBubble, .release,
            .progress(.waitingForIdle), .acquire(28), .ensureHidden, .selectChat, .findBubble, .activate,
        ])
        XCTAssertEqual(h.queue.acquiredAt, [1000, 1002])
        XCTAssertFalse(h.queue.doubleAcquire)
        XCTAssertNotNil(outcome.ticket)
        XCTAssertFalse(outcome.result.notes.contains(.userTookOver))
    }

    func testActivationCheckNeedsTwoFullSecondsSinceInput() {
        for (wait, retakes) in [(2.0, false), (2.0 - 1.0 / 64.0, true)] {
            let h = Harness()
            h.log.onEvent = { [unowned h] event in
                if event == .selectChat, h.log.count(.selectChat) == 1 { h.input.inject() }
                if event == .findBubble, h.log.count(.findBubble) == 1 { h.clock.advance(wait) }
            }
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .ok, "\(wait)")
            XCTAssertEqual(h.log.count(.release), retakes ? 1 : 0, "\(wait)")
            XCTAssertEqual(h.log.acquireTimeouts.count, retakes ? 2 : 1, "\(wait)")
        }
    }

    func testRepeatedInputAtActivationCheckRunsOutOfTheIdleBudget() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in if event == .selectChat { h.input.inject() } }
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(outcome.result, ActionResult(.busy(.userActive), notes: [.mayHaveMarkedRead]))
        XCTAssertNil(outcome.ticket)
        XCTAssertNil(h.queue.holder)
        XCTAssertEqual(h.log.acquireTimeouts.count, h.log.count(.release))
        XCTAssertEqual(h.queue.acquiredAt.last, 1030)
        XCTAssertLessThanOrEqual(h.clock.uptime, 1030)
        assertNothingActivated(h)
    }

    func testRetakeQueueWaitStaysInsideTheIdleBudget() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .selectChat, h.log.count(.selectChat) == 1 { h.input.inject() }
            if event == .release { h.queue.otherHolderUntil = 1090 }
        }
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(outcome.result.code, .busy(.userActive))
        XCTAssertEqual(h.log.acquireTimeouts, [100, 28])
        XCTAssertEqual(h.clock.uptime, 1030)
        XCTAssertNil(outcome.ticket)
        assertNothingActivated(h)
    }

    func testRetakePastTheIdleBudgetGivesTheQueueBack() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .selectChat, h.log.count(.selectChat) == 1 { h.input.inject() }
            // The second pass through step 1 runs past the 30 s.
            if event == .ensureHidden, h.log.count(.ensureHidden) == 2 { h.clock.advance(29) }
        }
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(outcome.result.code, .busy(.userActive))
        XCTAssertNil(outcome.ticket)
        XCTAssertNil(h.queue.holder)
        XCTAssertEqual(h.log.count(.release), 2)
        assertNothingActivated(h)
    }

    func testFirstQueueWaitUsesTheQueueDeadlineAndReportsQueued() {
        let h = Harness()
        h.queue.otherHolderUntil = 1031
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.busy(.queue)))
        XCTAssertEqual(h.log.acquireTimeouts, [30])
        XCTAssertEqual(h.log.count(.progress(.queued)), 1)
        XCTAssertNil(outcome.ticket)
        XCTAssertEqual(h.log.count(.ensureHidden), 0)
    }

    func testTimeAtTheIdleGateDoesNotCountAgainstTheQueueWait() {
        let h = Harness()
        // Input until 1018, so the idle gate passes at 1020 with the bridge's deadline 10 s away.
        h.input.inputs = Array(stride(from: 1000.0, through: 1018.0, by: 0.5))
        h.queue.otherHolderUntil = 1045
        let outcome = h.runEdit(queueDeadline: 1030)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.log.acquireTimeouts, [30], "the 30 s start at the first ask")
        XCTAssertEqual(h.queue.acquiredAt, [1045])
    }

    func testFirstQueueWaitIsNotCutByTheIdleBudget() {
        let h = Harness()
        h.queue.otherHolderUntil = 1040
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.queue.acquiredAt, [1040])
    }
}
