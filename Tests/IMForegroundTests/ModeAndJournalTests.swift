import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMPolicy
import IMTestSupport

/// Foreground mode checks, the one-way switch, and the journal's `foreground` flag staying with IMBridge.
final class ModeAndJournalTests: XCTestCase {
    private let modeOff = ActionResult(.error(.message("foreground mode is off")), fix: "imessage allow --foreground")

    func testModeOffAtTheStartReturnsBeforeTheIdleGateAndTheQueue() {
        let h = Harness()
        h.mode.isForegroundModeOn = false
        h.input.inputs = [h.clock.uptime]
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, modeOff)
        XCTAssertNil(outcome.ticket)
        XCTAssertTrue(h.log.acquireTimeouts.isEmpty)
        XCTAssertEqual(h.clock.uptime, 1000, "no idle wait")
        assertNothingActivated(h)
    }

    func testModeTurnedOffWhileQueuedIsCheckedOnLeavingTheQueue() {
        let h = Harness()
        h.queue.otherHolderUntil = 1010
        h.log.onEvent = { [unowned h] event in
            if case .acquire = event { h.mode.isForegroundModeOn = false }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, modeOff)
        XCTAssertNotNil(outcome.ticket)
        XCTAssertEqual(h.log.count(.ensureHidden), 0)
        assertNothingActivated(h)
    }

    func testMachineNeverTurnsTheModeBackOn() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.ax.escapesToClose = 99
        let first = h.runEdit()
        XCTAssertTrue(first.turnedModeOff)
        if let ticket = first.ticket { h.queue.release(ticket) }
        let eventsBefore = h.log.events.count

        let second = h.runEdit()
        XCTAssertEqual(second.result, modeOff)
        XCTAssertFalse(h.mode.isForegroundModeOn)
        XCTAssertEqual(h.mode.reasons, ["Messages left in edit mode"])
        XCTAssertFalse(h.log.events[eventsBefore...].contains(.activate))
    }

    func testOnlyTheOutcomeSaysTheMachineTurnedTheModeOff() {
        let h = Harness()
        let outcome = h.runEdit()
        XCTAssertFalse(outcome.turnedModeOff)
        XCTAssertTrue(h.mode.reasons.isEmpty)
    }

    func testTheMachineHasNoJournalToWriteTheForegroundFlag() {
        let h = Harness()
        let env = h.makeEnv()
        for child in Mirror(reflecting: env).children {
            XCTAssertFalse(child.value is Journal, child.label ?? "")
        }
        for child in Mirror(reflecting: h.machine).children {
            XCTAssertFalse(child.value is Journal, child.label ?? "")
        }
    }

    func testEachJournalHookRunsOncePerRun() {
        let h = Harness()
        h.runEdit()
        let journalEvents = h.log.events.filter { $0 == .willInvoke || $0 == .didInvoke }
        XCTAssertEqual(journalEvents, [.willInvoke, .didInvoke])
    }
}
